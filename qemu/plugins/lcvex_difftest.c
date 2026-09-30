/*
 * LCVEX AArch64 difftest 插件
 *
 * 在每条 guest A64 指令执行前回调（此时架构状态为这条指令执行后的
 * 状态），导出完整寄存器状态、NZCV 与指令的内存写副作用，供 Cocotb/RTL
 * 差分测试使用。输出格式见 docs/DIFFTEST.md。
 *
 * 设计要点：
 * - 使用官方 TCG 插件 API，不修改 QEMU 源码，release 升级只需重新编译。
 * - mode=sync：P2/P3 锁步；同步异常按 Q5 语义 DISCON 失败。
 * - mode=step：P4/Q6 锁步，需要 QEMU fork step hook
 *   （LCVEX_DIFFTEST_STEP=1）。同步异常由 fork 在异常入口记录 ESR.EC，
 *   本插件在 discon 回调取用，随后照常 COMMIT，异常不再视为失败；异步
 *   IRQ/FIQ 也转为携带 EXC_IRQ 的普通 COMMIT（WFI 唤醒仍走 ASYNC）。
 * - 单 vCPU 假设；TCG 默认单线程即可。
 *
 * SPDX-License-Identifier: GPL-2.0-or-later
 */
#include <glib.h>
#include <fcntl.h>
#include <inttypes.h>
#include <errno.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <sys/un.h>
#include <unistd.h>
#include <zlib.h>

#include <qemu-plugin.h>
#include "lcvex_protocol.h"

/* Keep the plugin source buildable against an unpatched QEMU header.  The
 * symbol is intentionally only resolved when P7 is enabled; default scalar
 * V1 therefore remains loadable until the integrator replays patch 0012. */
#ifndef QEMU_LCVEX_FP_STATE_DEFINED
struct qemu_lcvex_fp_state {
    uint32_t fpcr;
    uint32_t fpsr;
    uint32_t vector_bytes;
    uint32_t upper_nonzero;
    uint8_t v[32][16];
};
extern int qemu_lcvex_difftest_read_fp_state(
    struct qemu_lcvex_fp_state *state);
#endif

#define MAX_STORES_PER_INSN 8

typedef struct {
    uint64_t addr;
    uint64_t data;
    uint8_t size; /* 字节数 */
} store_rec_t;

typedef struct {
    uint64_t vaddr;
    uint32_t insn;
    char disas[128];
} insn_info_t;

static const char *trace_path = "lcvex_difftest.trace";
static gzFile out;      /* trace 输出：gzip 压缩（回放端 gzread 兼容） */
static long commit_limit = -1;
static long trace_tail = 0;     /* tail=N：trace 模式只保留末尾 N 条提交 */
static long commit_count;
static uint64_t trace_seq;

/* 锁步（mode=sync）状态 */
static bool sync_mode;
static bool step_mode;      /* mode=step：QEMU fork 精确 step hook */
static bool dbg_mem;        /* dbgmem=1：命中 0x424 区域的访存 VA/PA 打印 */
static int sock_fd = -1;
static bool init_sent;
static bool have_pending;
static bool sync_failed;
static bool sync_stopped;   /* STOP 已收到或 DISCON 已上报：停止参与协议 */
static uint64_t msg_seq;
static uint64_t pending_seq;
static uint64_t insns_committed;
static qemu_plugin_id_t plugin_id;
static bool pending_exc_valid;
/* qemu_lcvex_difftest_take_exception() 的 kind：1=同步（当前指令未退休），
 * 2=异步 IRQ/FIQ（当前指令已经退休）。不要从 exc_code=0x40 反推该语义，
 * 因为 monitor sidecar 必须区分同一 COMMIT 的异常来源。 */
static int pending_exc_kind;
static uint32_t pending_exc_code;
static uint32_t pending_exc_esr;
static uint64_t pending_exc_far;
/* PSCI/semihosting hostcall 没有独立的退休回调；下一条指令回调才可
 * 观察到 QEMU 更新后的返回寄存器和 PC。step 模式把它延迟为普通提交。 */
static bool pending_hostcall;
static const char *timer_restore_path;
static bool timer_restore_done;

static struct qemu_plugin_register *reg_x[31];
static struct qemu_plugin_register *reg_sp;
static struct qemu_plugin_register *reg_pc;
static struct qemu_plugin_register *reg_cpsr;
static bool reg_x_found[31];

static bool have_last;
static uint64_t last_pc;
static uint32_t last_insn;
static char last_disas[128];
static struct lcvex_state last_pre_state;

static store_rec_t stores[MAX_STORES_PER_INSN];
static int nstores;
static bool atomic_old_valid;
static uint64_t atomic_old_value;
static uint64_t atomic_old_value2;
static bool wait_committed;
static uint64_t wait_seq;
static bool suppress_wait_exception;

/* P7 FP/NEON protocol state.  No write-effect bits are kept here: the wire
 * carries only raw architectural state deltas. */
enum fp_descriptor_profile {
    FP_PROFILE_NONE = 0,
    FP_PROFILE_V = 1,
    FP_PROFILE_Z_ADAPTER = 2,
};
static bool fp_required;
static bool fp_enabled;
static bool fp_checkpoint_allowed;
static enum fp_descriptor_profile fp_profile;
static uint32_t fp_descriptor_vector_bytes;
static bool fp_preflight_done;
static bool fp_shadow_valid;
static struct lcvex_fp_state_v1 fp_shadow;

static bool send_msg(uint16_t type, uint64_t seq, const void *payload,
                     uint32_t plen);
static bool payload_length_valid(uint16_t type, const uint8_t *payload,
                                 size_t plen);

/* M3：exclusive 监视器追踪（QEMU env->exclusive_addr/val 的插件侧镜像）。
 * 插件 API 读不到 CPUARMState 内部字段，改由指令编码 + 寄存器状态推导：
 *   LDXR/LDAXR 执行后：地址=rn（31 用 SP）、值=rt（加载值）；
 *   STXR/STLXR/CLREX/ERET 执行后：清。A profile 异常入口不清。
 */
static bool mon_valid;
static uint64_t mon_addr;
static uint64_t mon_data;
static uint64_t mon_data2;
static GByteArray *regbuf;      /* read_reg64 复用缓冲（避免每指令分配） */

static uint64_t read_reg64(struct qemu_plugin_register *handle)
{
    uint64_t val = 0;

    if (regbuf == NULL) {
        regbuf = g_byte_array_new();
    } else {
        g_byte_array_set_size(regbuf, 0);
    }
    /* 句柄可能是 NULL（gdb 寄存器 0 = x0），不能当作未找到 */
    if (qemu_plugin_read_register(handle, regbuf) && regbuf->len >= 8) {
        /* AArch64 为小端，x86 host 同为小端；插件 API 按目标字节序返回 */
        memcpy(&val, regbuf->data, sizeof(val));
    }
    return val;
}

static int parse_named_vector(const char *name, char prefix)
{
    char *end = NULL;
    long number;

    if (name == NULL || name[0] != prefix || name[1] == '\0') {
        return -1;
    }
    errno = 0;
    number = strtol(name + 1, &end, 10);
    if (errno != 0 || end == name + 1 || *end != '\0' ||
        number < 0 || number >= 32) {
        return -1;
    }
    return (int)number;
}

static size_t register_bytes(struct qemu_plugin_register *handle)
{
    GByteArray *buf = g_byte_array_new();
    size_t bytes = 0;

    if (handle != NULL && qemu_plugin_read_register(handle, buf)) {
        bytes = buf->len;
    }
    g_byte_array_free(buf, TRUE);
    return bytes;
}

static uint64_t load_le64(const uint8_t *p)
{
    uint64_t value = 0;

    for (unsigned i = 0; i < 8; i++) {
        value |= (uint64_t)p[i] << (i * 8);
    }
    return value;
}

static void fp_state_from_snapshot(const struct qemu_lcvex_fp_state *snapshot,
                                   struct lcvex_fp_state_v1 *state)
{
    memset(state, 0, sizeof(*state));
    state->fpcr = snapshot->fpcr;
    state->fpsr = snapshot->fpsr;
    for (unsigned i = 0; i < 32; i++) {
        state->v[i].lo = load_le64(snapshot->v[i]);
        state->v[i].hi = load_le64(snapshot->v[i] + 8);
    }
}

static bool fp_read_snapshot(struct qemu_lcvex_fp_state *snapshot,
                             unsigned *reject_reason)
{
    if (snapshot == NULL || qemu_lcvex_difftest_read_fp_state(snapshot) < 0) {
        if (reject_reason != NULL) {
            *reject_reason = LCVEX_P7_REJECT_DESCRIPTOR;
        }
        return false;
    }
    if (snapshot->vector_bytes < LCVEX_FP_VECTOR_BYTES ||
        snapshot->vector_bytes % LCVEX_FP_VECTOR_BYTES != 0) {
        if (reject_reason != NULL) {
            *reject_reason = LCVEX_P7_REJECT_PROFILE;
        }
        return false;
    }
    if (fp_profile == FP_PROFILE_V && snapshot->vector_bytes !=
            LCVEX_FP_VECTOR_BYTES) {
        if (reject_reason != NULL) {
            *reject_reason = LCVEX_P7_REJECT_PROFILE;
        }
        return false;
    }
    if (fp_profile == FP_PROFILE_Z_ADAPTER &&
        snapshot->vector_bytes > fp_descriptor_vector_bytes) {
        if (reject_reason != NULL) {
            *reject_reason = LCVEX_P7_REJECT_DESCRIPTOR;
        }
        return false;
    }
    if (snapshot->upper_nonzero != 0) {
        if (reject_reason != NULL) {
            *reject_reason = LCVEX_P7_REJECT_UPPER_NONZERO;
        }
        return false;
    }
    return true;
}

static bool fp_preflight_descriptors(unsigned *reject_reason)
{
    GArray *regs;
    bool have_v[32] = { false };
    bool have_z[32] = { false };
    bool have_fpcr = false;
    bool have_fpsr = false;
    bool any_v = false;
    bool any_z = false;
    uint32_t z_bytes = 0;

    regs = qemu_plugin_get_registers();
    if (regs == NULL) {
        if (reject_reason != NULL) {
            *reject_reason = LCVEX_P7_REJECT_DESCRIPTOR;
        }
        return false;
    }
    for (guint i = 0; i < regs->len; i++) {
        qemu_plugin_reg_descriptor *desc =
            &g_array_index(regs, qemu_plugin_reg_descriptor, i);
        int number = parse_named_vector(desc->name, 'v');
        if (number >= 0) {
            any_v = true;
            if (have_v[number] || register_bytes(desc->handle) != 16) {
                if (reject_reason != NULL) {
                    *reject_reason = LCVEX_P7_REJECT_DESCRIPTOR;
                }
                g_array_free(regs, TRUE);
                return false;
            }
            have_v[number] = true;
            continue;
        }
        number = parse_named_vector(desc->name, 'z');
        if (number >= 0) {
            size_t bytes;
            any_z = true;
            bytes = register_bytes(desc->handle);
            if (have_z[number] || bytes < LCVEX_FP_VECTOR_BYTES ||
                bytes % LCVEX_FP_VECTOR_BYTES != 0 ||
                (z_bytes != 0 && z_bytes != bytes)) {
                if (reject_reason != NULL) {
                    *reject_reason = LCVEX_P7_REJECT_DESCRIPTOR;
                }
                g_array_free(regs, TRUE);
                return false;
            }
            z_bytes = (uint32_t)bytes;
            have_z[number] = true;
            continue;
        }
        if (desc->name != NULL && strcmp(desc->name, "fpcr") == 0) {
            if (have_fpcr || register_bytes(desc->handle) != 4) {
                if (reject_reason != NULL) {
                    *reject_reason = LCVEX_P7_REJECT_DESCRIPTOR;
                }
                g_array_free(regs, TRUE);
                return false;
            }
            have_fpcr = true;
        } else if (desc->name != NULL && strcmp(desc->name, "fpsr") == 0) {
            if (have_fpsr || register_bytes(desc->handle) != 4) {
                if (reject_reason != NULL) {
                    *reject_reason = LCVEX_P7_REJECT_DESCRIPTOR;
                }
                g_array_free(regs, TRUE);
                return false;
            }
            have_fpsr = true;
        }
    }
    g_array_free(regs, TRUE);

    if (!have_fpcr || !have_fpsr || (any_v && any_z)) {
        if (reject_reason != NULL) {
            *reject_reason = LCVEX_P7_REJECT_DESCRIPTOR;
        }
        return false;
    }
    if (any_v) {
        for (unsigned i = 0; i < 32; i++) {
            if (!have_v[i]) {
                if (reject_reason != NULL) {
                    *reject_reason = LCVEX_P7_REJECT_DESCRIPTOR;
                }
                return false;
            }
        }
        fp_profile = FP_PROFILE_V;
        fp_descriptor_vector_bytes = LCVEX_FP_VECTOR_BYTES;
    } else if (any_z) {
        for (unsigned i = 0; i < 32; i++) {
            if (!have_z[i]) {
                if (reject_reason != NULL) {
                    *reject_reason = LCVEX_P7_REJECT_DESCRIPTOR;
                }
                return false;
            }
        }
        fp_profile = FP_PROFILE_Z_ADAPTER;
        fp_descriptor_vector_bytes = z_bytes;
    } else {
        if (reject_reason != NULL) {
            *reject_reason = LCVEX_P7_REJECT_DESCRIPTOR;
        }
        return false;
    }
    return true;
}

static size_t fp_make_delta(const struct lcvex_fp_state_v1 *current,
                            uint8_t *out, size_t cap)
{
    uint32_t flags = 0;
    uint32_t v_mask = 0;
    size_t count;
    size_t offset;

    if (current->fpcr != fp_shadow.fpcr) {
        flags |= 1u;
    }
    if (current->fpsr != fp_shadow.fpsr) {
        flags |= 2u;
    }
    for (unsigned i = 0; i < 32; i++) {
        if (current->v[i].lo != fp_shadow.v[i].lo ||
            current->v[i].hi != fp_shadow.v[i].hi) {
            v_mask |= UINT32_C(1) << i;
        }
    }
    count = (size_t)__builtin_popcount(v_mask);
    if (count > LCVEX_FP_MAX_VECTORS ||
        LCVEX_FP_COMMIT_HEADER_BYTES + count * sizeof(struct lcvex_v128) > cap) {
        return 0;
    }
    struct lcvex_fp_commit_delta_v1 header = {
        .flags = flags,
        .v_mask = v_mask,
        .fpcr = current->fpcr,
        .fpsr = current->fpsr,
    };
    memcpy(out, &header, sizeof(header));
    offset = sizeof(header);
    for (unsigned i = 0; i < 32; i++) {
        if (v_mask & (UINT32_C(1) << i)) {
            memcpy(out + offset, &current->v[i], sizeof(current->v[i]));
            offset += sizeof(current->v[i]);
        }
    }
    return offset;
}

static bool fp_send_commit(uint64_t seq)
{
    struct qemu_lcvex_fp_state snapshot;
    struct lcvex_fp_state_v1 current;
    uint8_t payload[LCVEX_FP_COMMIT_MAX_BYTES];
    unsigned reason = LCVEX_P7_REJECT_DESCRIPTOR;
    size_t length;

    if (!fp_read_snapshot(&snapshot, &reason)) {
        fprintf(stderr, "lcvex_difftest: FP snapshot rejected reason=%u\n",
                reason);
        sync_failed = true;
        return false;
    }
    fp_state_from_snapshot(&snapshot, &current);
    length = fp_make_delta(&current, payload, sizeof(payload));
    if (length == 0 || !send_msg(LCVEX_MSG_FP_COMMIT, seq, payload,
                                  (uint32_t)length)) {
        sync_failed = true;
        return false;
    }
    fp_shadow = current;
    fp_shadow_valid = true;
    return true;
}

/* 返回指令的 exclusive 类型：0=无 1=LDXR/LDAXR 2=STXR/STLXR 3=CLREX
 * 4=ERET 5=LDXP/LDAXP 6=STXP/STLXP。与 RTL decode 的位模式一致
 * （bits[29:24]=001000，bits[23:21]=010=LDXR、000=STXR、011=LDXP、
 * 001=STXP；lasr=bit15 不影响监视器语义）。 */
static int excl_insn_kind(uint32_t insn)
{
    if (insn == 0xD69F03E0u) {
        return 4;
    }
    if (insn == 0xD5033F5Fu) {
        return 3;
    }
    /* CASP/CASPA/CASPL/CASPAL 与 STXP 共用 001000 编码高位，
     * 但不操作 exclusive monitor；先排除，避免误判为 STXP。 */
    if ((insn & 0xffa07c00u) == 0x48207c00u) {
        return 0;
    }
    if ((insn & 0x3F000000u) == 0x08000000u) {
        uint32_t b = (insn >> 21) & 7u;
        if (b == 2u) {
            return 1;
        }
        if (b == 0u) {
            return 2;
        }
        if (b == 3u) {
            return 5;
        }
        if (b == 1u) {
            return 6;
        }
    }
    return 0;
}

/* 计算 last_insn 提交后的监视器更新并写入 cm。
 * exception_kind=1 时：指令自身未完成（SVC/UDEF/DABT）-> 不变；
 * exception_kind=2 是 IRQ/FIQ discontinuity，指令已经退休 -> 照常更新；
 * 取指 fault 合并（EC=0x20/0x21）-> 指令已执行，照常更新；ERET 目标
 * 越界 IABT -> ERET 已清（kind==4 恒更新）。 */
static void apply_monitor_effect(uint32_t insn, int exception_kind,
                                 uint32_t ec, struct lcvex_commit *cm)
{
    int kind = excl_insn_kind(insn);
    bool apply;

    cm->mon_we = 0;
    cm->mon_valid = 0;
    cm->mon_addr = 0;
    cm->mon_data = 0;

    if (kind == 0) {
        return;
    }
    if (kind == 4) {
        apply = true;   /* ERET 无论成功还是目标 IABT 都已执行 */
    } else if (exception_kind == 0) {
        apply = true;
    } else if (exception_kind == 2) {
        apply = true;   /* 异步 IRQ/FIQ：当前指令已退休 */
    } else if (ec == 0x20u || ec == 0x21u) {
        apply = true;   /* 取指 fault 合并：指令已退休 */
    } else {
        apply = false;  /* 指令自身 DABT/SVC/UDEF：监视器不变 */
    }
    if (!apply) {
        return;
    }

    cm->mon_we = 1;
    if (kind == 1 || kind == 5) {
        int rn = (insn >> 5) & 31;
        int rt = insn & 31;
        int rt2 = (insn >> 10) & 31;
        cm->mon_valid = 1;
        cm->mon_addr = (rn == 31) ? read_reg64(reg_sp)
                                  : read_reg64(reg_x[rn]);
        /* rt=31（XZR）插件读不到加载值：测试约束 rt!=31 */
        cm->mon_data = (rt == 31) ? 0 : read_reg64(reg_x[rt]);
        cm->mon_data2 = (kind == 5 && rt2 != 31)
                            ? read_reg64(reg_x[rt2]) : 0;
    } else {
        cm->mon_valid = 0;
        cm->mon_data2 = 0;
    }
    mon_valid = cm->mon_valid;
    mon_addr = cm->mon_addr;
    mon_data = cm->mon_data;
    mon_data2 = cm->mon_data2;
}

/* STXR 失败（值不匹配但地址匹配）以及 LSE CAS 失败时，QEMU 的 cmpxchg
 * 仍会触发一次 MEM_W 插件回调，但内存实际未写。按状态寄存器或
 * CAS 的 PRE/POST 比较值丢弃这次“幻影 store”，保持与 RTL 的条件写
 * 语义一致。 */
static void drop_failed_atomic_stores(uint32_t insn,
                                      const struct lcvex_state *pre,
                                      const struct lcvex_state *post)
{
    int kind = excl_insn_kind(insn);
    if (kind == 2 || kind == 6) {
        int rs = (insn >> 16) & 31;
        if (rs != 31 && post->x[rs] != 0) {
            nstores = 0;
        }
    }

    /* LSE CAS/CASA/CASL/CASAL 失败时，QEMU TCG 也触发 MEM_W 回调，
     * 但内存没有改变。优先使用同一条指令的原子读回值判断，覆盖
     * Rs=XZR；旧链若没有读回值，则退回 Rs 的 PRE/POST 比较。 */
    if ((insn & 0x3fa07c00u) == 0x08a07c00u) {
        int rs = (insn >> 16) & 31;
        uint64_t mask;
        switch ((insn >> 30) & 3u) {
        case 0: mask = UINT64_C(0xff); break;
        case 1: mask = UINT64_C(0xffff); break;
        case 2: mask = UINT64_C(0xffffffff); break;
        default: mask = UINT64_MAX; break;
        }
        if (atomic_old_valid) {
            uint64_t expected = (rs == 31) ? 0 : pre->x[rs];
            if ((expected & mask) != (atomic_old_value & mask)) {
                nstores = 0;
            }
        } else if (rs != 31 &&
                   ((pre->x[rs] & mask) != (post->x[rs] & mask))) {
                nstores = 0;
        }
    }

    /* CASP 的 MEM_W 回调通常以 U128 上报；比较失败时同样只保留了
     * 读出的旧 128 位值，丢弃两段幻影 Store。 */
    if ((insn & 0xffa07c00u) == 0x48207c00u && atomic_old_valid) {
        int rs = (insn >> 16) & 31;
        uint64_t expected_lo = (rs == 31) ? 0 : pre->x[rs];
        uint64_t expected_hi = (rs >= 30) ? 0 : pre->x[rs + 1];
        if (expected_lo != atomic_old_value ||
            expected_hi != atomic_old_value2) {
            nstores = 0;
        }
    }
}

static uint32_t read_cpsr(void)
{
    GByteArray *buf = g_byte_array_new();
    uint32_t val = 0;

    if (reg_cpsr != NULL && qemu_plugin_read_register(reg_cpsr, buf) &&
        buf->len >= 4) {
        memcpy(&val, buf->data, sizeof(val));
    }
    g_byte_array_free(buf, TRUE);
    return val;
}

static void fill_state(struct lcvex_state *s, uint64_t pc, uint64_t next_pc,
                       uint32_t insn)
{
    memset(s, 0, sizeof(*s));
    s->pc = pc;
    s->next_pc = next_pc;
    s->insn = insn;
    for (int i = 0; i < 31; i++) {
        s->x[i] = read_reg64(reg_x[i]);
    }
    s->sp = read_reg64(reg_sp);
    s->nzcv = (read_cpsr() >> 28) & 0xf;
}

static bool send_msg(uint16_t type, uint64_t seq, const void *payload,
                     uint32_t plen)
{
    struct lcvex_msg_header hdr;
    uint8_t buf[4096];
    size_t total;

    if (!payload_length_valid(type, payload, plen)) {
        return false;
    }

    memset(&hdr, 0, sizeof(hdr));
    hdr.magic = LCVEX_MSG_MAGIC;
    hdr.version = LCVEX_MSG_VERSION;
    hdr.type = type;
    hdr.payload_len = plen;
    hdr.seq = seq;
    total = lcvex_msg_encode(&hdr, payload, buf, sizeof(buf));
    if (total == 0) {
        return false;
    }
    return send(sock_fd, buf, total, MSG_NOSIGNAL) == (ssize_t)total;
}

static bool fp_payload_length_valid(const uint8_t *payload, size_t plen)
{
    uint32_t flags;
    uint32_t v_mask;
    size_t expected;

    if (plen < LCVEX_FP_COMMIT_HEADER_BYTES) {
        return false;
    }
    memcpy(&flags, payload, sizeof(flags));
    memcpy(&v_mask, payload + sizeof(flags), sizeof(v_mask));
    if (flags & ~UINT32_C(3) || __builtin_popcount(v_mask) >
            LCVEX_FP_MAX_VECTORS) {
        return false;
    }
    expected = LCVEX_FP_COMMIT_HEADER_BYTES +
               (size_t)__builtin_popcount(v_mask) * sizeof(struct lcvex_v128);
    return plen == expected && expected <= LCVEX_FP_COMMIT_MAX_BYTES;
}

static bool payload_length_valid(uint16_t type, const uint8_t *payload,
                                 size_t plen)
{
    size_t expected = 0;

    switch (type) {
    case LCVEX_MSG_HELLO: expected = sizeof(struct lcvex_hello); break;
    case LCVEX_MSG_CONFIG: expected = sizeof(struct lcvex_config); break;
    case LCVEX_MSG_INIT: expected = sizeof(struct lcvex_state); break;
    case LCVEX_MSG_PRE: expected = sizeof(struct lcvex_pre); break;
    case LCVEX_MSG_GO: expected = 0; break;
    case LCVEX_MSG_COMMIT: expected = sizeof(struct lcvex_commit); break;
    case LCVEX_MSG_ACK: expected = sizeof(struct lcvex_ack); break;
    case LCVEX_MSG_DISCON: expected = sizeof(struct lcvex_discon); break;
    case LCVEX_MSG_STOP: expected = 0; break;
    case LCVEX_MSG_EXIT: expected = sizeof(struct lcvex_exit); break;
    case LCVEX_MSG_CKPT_REQ: expected = sizeof(struct lcvex_ckpt_req); break;
    case LCVEX_MSG_CKPT_READY: expected = sizeof(struct lcvex_ckpt_ready); break;
    case LCVEX_MSG_ASYNC: expected = sizeof(struct lcvex_commit); break;
    case LCVEX_MSG_WAIT: expected = 0; break;
    case LCVEX_MSG_WAIT_RESUME: expected = sizeof(struct lcvex_wait_resume); break;
    case LCVEX_MSG_FP_INIT: expected = sizeof(struct lcvex_fp_state_v1); break;
    case LCVEX_MSG_P7_REJECT: expected = sizeof(struct lcvex_p7_reject); break;
    case LCVEX_MSG_FP_COMMIT:
        return fp_payload_length_valid(payload, plen);
    default:
        return false;
    }
    return plen == expected;
}

static bool fp_sidecar_path(const char *sys_path, char *fp_path,
                            size_t fp_path_cap)
{
    size_t length;

    if (sys_path == NULL || fp_path == NULL || fp_path_cap == 0 ||
        !g_str_has_suffix(sys_path, ".dev.sys")) {
        return false;
    }
    length = strlen(sys_path);
    if (length + 1 > fp_path_cap || length < strlen(".sys")) {
        return false;
    }
    memcpy(fp_path, sys_path, length + 1);
    memcpy(fp_path + length - strlen(".sys"), ".fp", strlen(".fp") + 1);
    return true;
}

static bool write_all_fd(int fd, const void *data, size_t length)
{
    const uint8_t *bytes = data;

    while (length != 0) {
        ssize_t written = write(fd, bytes, length);
        if (written <= 0) {
            return false;
        }
        bytes += written;
        length -= (size_t)written;
    }
    return true;
}

static bool write_fp_sidecar(const char *sys_path, char *detail,
                             size_t detail_cap)
{
    struct qemu_lcvex_fp_state snapshot;
    struct lcvex_fp_state_file_v1 file;
    char fp_path[sizeof(((struct lcvex_ckpt_req *)0)->sys_path)];
    char tmp_path[sizeof(fp_path) + 5];
    unsigned reason = LCVEX_P7_REJECT_DESCRIPTOR;
    int fd;
    bool ok;

    if (!fp_sidecar_path(sys_path, fp_path, sizeof(fp_path))) {
        if (detail != NULL && detail_cap != 0) {
            snprintf(detail, detail_cap,
                     "FP sidecar sys_path 必须以 .dev.sys 结尾");
        }
        return false;
    }
    if (!fp_checkpoint_allowed || fp_profile != FP_PROFILE_V ||
        !fp_read_snapshot(&snapshot, &reason) ||
        snapshot.vector_bytes != LCVEX_FP_VECTOR_BYTES ||
        snapshot.upper_nonzero != 0) {
        if (detail != NULL && detail_cap != 0) {
            snprintf(detail, detail_cap,
                     "FP checkpoint 不允许 adapter/高 Z 状态（reason=%u）",
                     reason);
        }
        return false;
    }
    memset(&file, 0, sizeof(file));
    memcpy(file.magic, "LCVXFP01", sizeof(file.magic));
    file.version = 1;
    file.size = sizeof(file);
    file.feature_bits = LCVEX_FP_FEATURE_NEON;
    file.vector_bytes = LCVEX_FP_VECTOR_BYTES;
    file.seq = pending_seq;
    file.fpcr = snapshot.fpcr;
    file.fpsr = snapshot.fpsr;
    for (unsigned i = 0; i < 32; i++) {
        file.v[i][0] = load_le64(snapshot.v[i]);
        file.v[i][1] = load_le64(snapshot.v[i] + 8);
    }
    snprintf(tmp_path, sizeof(tmp_path), "%s.tmp", fp_path);
    fd = open(tmp_path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0600);
    if (fd < 0) {
        if (detail != NULL && detail_cap != 0) {
            snprintf(detail, detail_cap, "创建 FP sidecar 失败: %s",
                     strerror(errno));
        }
        return false;
    }
    ok = write_all_fd(fd, &file, sizeof(file)) && fsync(fd) == 0 &&
         close(fd) == 0;
    if (!ok) {
        close(fd);
        unlink(tmp_path);
        if (detail != NULL && detail_cap != 0) {
            snprintf(detail, detail_cap, "写入 FP sidecar 失败: %s",
                     strerror(errno));
        }
        return false;
    }
    if (rename(tmp_path, fp_path) != 0) {
        unlink(tmp_path);
        if (detail != NULL && detail_cap != 0) {
            snprintf(detail, detail_cap, "发布 FP sidecar 失败: %s",
                     strerror(errno));
        }
        return false;
    }
    return true;
}

static void send_p7_reject(unsigned reason, uint32_t vector_bytes)
{
    struct lcvex_p7_reject reject = {
        .reason = reason,
        .vector_bytes = vector_bytes,
    };

    if (sock_fd >= 0) {
        (void)send_msg(LCVEX_MSG_P7_REJECT, 0, &reject, sizeof(reject));
    }
    sync_failed = true;
    sync_stopped = true;
}

static bool recv_msg(struct lcvex_msg_header *hdr, void *payload,
                     size_t cap, size_t *plen)
{
    uint8_t buf[4096];
    ssize_t n = recv(sock_fd, buf, sizeof(buf), 0);

    if (n <= 0) {
        return false;
    }
    if ((size_t)n < sizeof(*hdr)) {
        return false;
    }
    memcpy(hdr, buf, sizeof(*hdr));
    if (hdr->magic != LCVEX_MSG_MAGIC || hdr->version != LCVEX_MSG_VERSION) {
        return false;
    }
    if (hdr->flags != 0 || hdr->payload_len !=
            (uint32_t)((size_t)n - sizeof(*hdr))) {
        return false; /* reject truncation and extra datagram bytes */
    }
    if (hdr->payload_len > cap) {
        return false;
    }
    if (!payload_length_valid(hdr->type, buf + sizeof(*hdr),
                              hdr->payload_len)) {
        return false;
    }
    if (hdr->payload_len > 0) {
        memcpy(payload, buf + sizeof(*hdr), hdr->payload_len);
    }
    *plen = hdr->payload_len;
    return true;
}

static void sync_insn_cb_internal(insn_info_t *info, bool emit_pre)
{
    struct lcvex_msg_header hdr;
    struct lcvex_state st;
    size_t plen = 0;

    if (sync_failed || sync_stopped) {
        return;
    }

    if (!init_sent) {
        fill_state(&st, info->vaddr, info->vaddr, 0);
        if (!send_msg(LCVEX_MSG_INIT, 0, &st, sizeof(st))) {
            sync_failed = true;
            return;
        }
        init_sent = true;
        if (fp_enabled) {
            struct qemu_lcvex_fp_state snapshot;
            struct lcvex_fp_state_v1 state;
            unsigned reason = LCVEX_P7_REJECT_DESCRIPTOR;
            memset(&snapshot, 0, sizeof(snapshot));
            if (!fp_read_snapshot(&snapshot, &reason)) {
                fprintf(stderr,
                        "lcvex_difftest: P7 FP_INIT snapshot rejected reason=%u\n",
                        reason);
                send_p7_reject(reason, snapshot.vector_bytes);
                return;
            }
            fp_state_from_snapshot(&snapshot, &state);
            if (!send_msg(LCVEX_MSG_FP_INIT, 0, &state, sizeof(state))) {
                sync_failed = true;
                return;
            }
            fp_shadow = state;
            fp_shadow_valid = true;
        }
    }

    if (have_pending) {
        struct lcvex_commit cm;
        struct lcvex_ack ack;
        /* 通常 IRQ/FIQ discontinuity callback 会先写 pending_exc_*。少数
         * TCG 路径在下一条普通指令回调才可见向量 PC；此处再取一次 fork note
         * 作为保险，避免 QEMU 已跳 IRQ 向量但 COMMIT 漏掉 exc_valid。 */
        if (step_mode && !pending_exc_valid) {
            uint32_t ec = 0;
            uint32_t esr = 0;
            uint64_t far = 0;
            int kind = qemu_lcvex_difftest_take_exception(0, &ec, &esr, &far);
            if (kind == 1 || kind == 2) {
                pending_exc_valid = true;
                pending_exc_kind = kind;
                pending_exc_code = (kind == 2) ? 0x40u : ec;
                pending_exc_esr = (kind == 2) ? 0 : esr;
                pending_exc_far = (kind == 2) ? 0 : far;
            }
        }
        bool exc_v = pending_exc_valid;
        uint32_t exc_c = pending_exc_code;
        memset(&cm, 0, sizeof(cm));
        fill_state(&cm.post, last_pc, info->vaddr, last_insn);
        drop_failed_atomic_stores(last_insn, &last_pre_state, &cm.post);
        cm.nzcv = (read_cpsr() >> 28) & 0xf;
        cm.exc_valid = exc_v ? 1 : 0;
        cm.exc_code = exc_c;
        cm.exc_esr = pending_exc_esr;
        cm.exc_far = pending_exc_far;
        apply_monitor_effect(last_insn,
                             exc_v ? pending_exc_kind : 0,
                             exc_c, &cm);
        pending_exc_valid = false;
        pending_exc_kind = 0;
        pending_exc_code = 0;
        pending_exc_esr = 0;
        pending_exc_far = 0;
        cm.store_count = (uint32_t)nstores;
        for (int i = 0; i < nstores && i < LCVEX_MAX_STORES; i++) {
            cm.stores[i].addr = stores[i].addr;
            cm.stores[i].data = stores[i].data;
            cm.stores[i].strb = (uint8_t)((1u << stores[i].size) - 1);
        }
        if (!send_msg(LCVEX_MSG_COMMIT, pending_seq, &cm, sizeof(cm))) {
            sync_failed = true;
            return;
        }
        if (fp_enabled && !fp_shadow_valid) {
            sync_failed = true;
            return;
        }
        if (fp_enabled && !fp_send_commit(pending_seq)) {
            return;
        }
        for (;;) {
            uint8_t payload[sizeof(struct lcvex_ckpt_req)];
            if (!recv_msg(&hdr, payload, sizeof(payload), &plen)) {
                sync_failed = true;
                return;
            }
            if (hdr.type == LCVEX_MSG_STOP) {
                sync_stopped = true;
                return;  /* 协调器已结束测试 */
            }
            if (hdr.type == LCVEX_MSG_CKPT_REQ) {
                struct lcvex_ckpt_req req;
                struct lcvex_ckpt_ready ready;
                memset(&req, 0, sizeof(req));
                memset(&ready, 0, sizeof(ready));
                if (hdr.seq != pending_seq || plen != sizeof(req)) {
                    sync_failed = true;
                    return;
                }
                memcpy(&req, payload, sizeof(req));
                ready.status = qemu_lcvex_difftest_save_devices_state(
                    req.dev_path, req.sys_path, req.timer_path,
                    req.gic_path);
                if (ready.status >= 0 && fp_enabled &&
                    !write_fp_sidecar(req.sys_path, ready.detail,
                                      sizeof(ready.detail))) {
                    ready.status = -1;
                }
                if (ready.status < 0) {
                    if (ready.detail[0] == '\0') {
                        snprintf(ready.detail, sizeof(ready.detail),
                                 "QEMU device/FP state 保存失败");
                    }
                }
                if (!send_msg(LCVEX_MSG_CKPT_READY, pending_seq, &ready,
                              sizeof(ready))) {
                    sync_failed = true;
                    return;
                }
                /* 协调器此时读取共享 RAM；继续等待 ACK，不执行 guest。 */
                continue;
            }
            if (hdr.type != LCVEX_MSG_ACK || hdr.seq != pending_seq ||
                plen != sizeof(ack)) {
                sync_failed = true;
                return;
            }
            memcpy(&ack, payload, sizeof(ack));
            if (ack.status != LCVEX_ACK_OK) {
                fprintf(stderr, "lcvex_difftest: ACK FAIL seq=%lu: %s\n",
                        (unsigned long)pending_seq, ack.detail);
                sync_failed = true;
                return;
            }
            break;
        }
        /* hostcall 已作为本条普通 COMMIT 完成；仅用于诊断和状态清理。 */
        pending_hostcall = false;
        insns_committed++;
    }

    if (sync_failed) {
        return;
    }

    if (!emit_pre) {
        /* WFI/WFE 已在 QEMU vCPU idle 回调中提交；不要伪造下一条 PRE。 */
        have_pending = false;
        wait_committed = true;
        wait_seq = pending_seq;
        return;
    }

    /* 真实 WFI/WFE/WFxT halt 恢复后，QEMU 的 virtual clock 可能已经跳过
     * 数千个 tick。必须在下一条 PRE 前交给协调器，避免 DUT 靠逐周期猜测
     * timeout 边界。cpu_has_work() 的立即返回没有 wait_committed，不发此包。 */
    if (wait_committed) {
        uint64_t cntvct = qemu_lcvex_difftest_get_cntvct(0);
        struct lcvex_wait_resume wr = {
            .cntvct = cntvct,
        };
        if (cntvct != UINT64_MAX &&
            !send_msg(LCVEX_MSG_WAIT_RESUME, wait_seq, &wr, sizeof(wr))) {
            sync_failed = true;
            return;
        }
    }

    /* PRE(seq)：当前指令执行前状态 */
    {
        struct lcvex_pre pr;
        struct lcvex_config cfg;
        fill_state(&pr.pre, info->vaddr, info->vaddr, info->insn);
        last_pre_state = pr.pre;
        if (!send_msg(LCVEX_MSG_PRE, msg_seq, &pr, sizeof(pr))) {
            sync_failed = true;
            return;
        }
        if (!recv_msg(&hdr, &cfg, sizeof(cfg), &plen) ||
            hdr.type != LCVEX_MSG_GO || hdr.seq != msg_seq) {
            /* 协调器可能已发 STOP（步数达到上限） */
            if (hdr.type == LCVEX_MSG_STOP) {
                sync_stopped = true;
                return;
            }
            sync_failed = true;
            return;
        }
    }

    pending_seq = msg_seq;
    have_pending = true;
    /* A normal PRE means a previous WFx wait resumed without an IRQ
     * discontinuity (timeout or event).  Do not let that old wait be reused
     * if a later, unrelated interrupt arrives. */
    wait_committed = false;
    nstores = 0;
    atomic_old_valid = false;
    atomic_old_value = 0;
    atomic_old_value2 = 0;
    last_pc = info->vaddr;
    last_insn = info->insn;
    msg_seq++;
}

static void sync_insn_cb(insn_info_t *info)
{
    sync_insn_cb_internal(info, true);
}

static bool is_wait_insn(uint32_t insn)
{
    return insn == 0xD503207Fu || insn == 0xD503205Fu ||
           (insn & 0xFFFFFFE0u) == 0xD5031000u || /* WFET <Xt> */
           (insn & 0xFFFFFFE0u) == 0xD5031020u;  /* WFIT <Xt> */
}

static void vcpu_idle_cb(unsigned int vcpu_index, void *userdata)
{
    insn_info_t info;

    (void)vcpu_index;
    (void)userdata;
    if (!step_mode || sync_failed || sync_stopped || !have_pending ||
        !is_wait_insn(last_insn)) {
        return;
    }
    memset(&info, 0, sizeof(info));
    info.vaddr = reg_pc != NULL ? read_reg64(reg_pc) : last_pc + 4;
    info.insn = 0;
    sync_insn_cb_internal(&info, false);
    /* sync_insn_cb_internal 在 emit_pre=false 时已完成等待指令的 COMMIT
     * 并等待协调器 ACK。此消息明确区分真实 halt 与 helper 因
     * cpu_has_work() 立即返回（后者没有 idle callback，直接发下一 PRE）。 */
    if (!sync_failed && !sync_stopped && wait_committed &&
        !send_msg(LCVEX_MSG_WAIT, wait_seq, NULL, 0)) {
        sync_failed = true;
    }
}

static void vcpu_resume_cb(unsigned int vcpu_index, void *userdata)
{
    (void)vcpu_index;
    (void)userdata;
    /* WFE 可能由 SEV/事件唤醒而没有 IRQ discontinuity；下一条指令
     * 回调将正常发送 PRE。IRQ 唤醒的合成异常在 discon 回调中处理。 */
}

static bool send_wait_irq_commit(uint64_t vector_pc)
{
    struct lcvex_commit cm;
    struct lcvex_msg_header hdr;
    struct lcvex_ack ack;
    uint8_t payload[sizeof(struct lcvex_ckpt_req)];
    size_t plen = 0;

    if (!wait_committed || sync_failed || sync_stopped) {
        return false;
    }
    memset(&cm, 0, sizeof(cm));
    fill_state(&cm.post, last_pc, vector_pc, last_insn);
    cm.exc_valid = 1;
    cm.exc_code = 0x40; /* LCVEX async IRQ */
    cm.exc_esr = 0;
    cm.exc_far = 0;
    if (!send_msg(LCVEX_MSG_ASYNC, wait_seq, &cm, sizeof(cm))) {
        sync_failed = true;
        return false;
    }
    for (;;) {
        if (!recv_msg(&hdr, payload, sizeof(payload), &plen)) {
            sync_failed = true;
            return false;
        }
        if (hdr.type == LCVEX_MSG_STOP) {
            sync_stopped = true;
            return false;
        }
        if (hdr.type != LCVEX_MSG_ACK || hdr.seq != wait_seq ||
            plen != sizeof(ack)) {
            sync_failed = true;
            return false;
        }
        memcpy(&ack, payload, sizeof(ack));
        if (ack.status != LCVEX_ACK_OK) {
            sync_failed = true;
            return false;
        }
        break;
    }
    wait_committed = false;
    suppress_wait_exception = true;
    return true;
}

/* PC discontinuity（异常/中断/host call）。
 * - mode=sync（P2/Q5）：任何 discontinuity 都视为测试失败。
 * - mode=step（P4/Q6）：同步异常由 fork step hook 提供 ESR.EC，本回调
 *   记录后继续协议，由向量入口的下一条指令前回调形成异常 COMMIT；IRQ/FIQ
 *   转为携带 EXC_IRQ 的普通 COMMIT。PSCI/semihosting hostcall 则由
 *   下一条指令回调完成普通 COMMIT（QEMU 已更新返回寄存器和 PC）。 */
static void vcpu_discon(unsigned int vcpu_index,
                        enum qemu_plugin_discon_type type,
                        uint64_t from_pc, uint64_t to_pc, void *userdata)
{
    struct lcvex_discon dc;

    (void)vcpu_index;
    (void)userdata;

    if (sync_failed || sync_stopped) {
        return;
    }
    if (!sync_mode && !step_mode) {
        /* P1 trace 模式：记录同步异常标志（无 fork step hook，无
         * EC/ESR/FAR），由向量入口的下一条回调组成异常 commit 行；
         * 回放端按 next_pc/exc_valid 比较。 */
        if (type == QEMU_PLUGIN_DISCON_EXCEPTION) {
            pending_exc_valid = true;
            pending_exc_kind = 1;
            pending_exc_code = 0;
            pending_exc_esr = 0;
            pending_exc_far = 0;
        }
        return;
    }

    if (step_mode && type == QEMU_PLUGIN_DISCON_HOSTCALL) {
        /*
         * PSCI SYSTEM_RESET/SYSTEM_OFF：QEMU 执行整机复位/关机，架构
         * 状态不再连续（寄存器清零、PC 回到复位向量）。这类 hostcall
         * 不能当作普通 COMMIT 比较；按协议上报 kind=4，由协调器把
         * 窗口定义为“访客请求复位/关机”终止。其余 PSCI/semihosting
         * 已在 QEMU hostcall 路径中完成架构状态更新，保持 pending
         * 指令，下一条指令回调会发送该指令的 COMMIT。
         */
        uint64_t fn = last_pre_state.x[0];
        if (fn == 0x84000008ull || fn == 0x84000009ull ||
            fn == 0xC4000008ull || fn == 0xC4000009ull) {
            struct lcvex_discon dc;
            memset(&dc, 0, sizeof(dc));
            dc.kind = LCVEX_DISCON_GUEST_RESET;
            dc.pc = from_pc;
            dc.data = fn;
            fprintf(stderr,
                    "lcvex_difftest: guest PSCI reset/shutdown fn=0x%llx "
                    "from_pc=0x%llx\n",
                    (unsigned long long)fn,
                    (unsigned long long)from_pc);
            if (!send_msg(LCVEX_MSG_DISCON, msg_seq, &dc, sizeof(dc))) {
                sync_failed = true;
                return;
            }
            sync_stopped = true;
            return;
        }
        if (!have_pending) {
            fprintf(stderr,
                    "lcvex_difftest: hostcall 无 pending 指令（from_pc=0x%llx）\n",
                    (unsigned long long)from_pc);
            sync_failed = true;
            return;
        }
        pending_hostcall = true;
        fprintf(stderr,
                "lcvex_difftest: hostcall 延迟为 COMMIT pc=0x%llx "
                "insn=0x%08x next=0x%llx\n",
                (unsigned long long)last_pc, last_insn,
                (unsigned long long)from_pc);
        return;
    }

    if (step_mode && (type == QEMU_PLUGIN_DISCON_EXCEPTION ||
                      type == QEMU_PLUGIN_DISCON_INTERRUPT)) {
        uint32_t ec = 0;
        uint32_t esr = 0;
        uint64_t far = 0;
        int kind = qemu_lcvex_difftest_take_exception(vcpu_index, &ec,
                                                      &esr, &far);

        if (kind == 1) {
            if (suppress_wait_exception) {
                /* IRQ discontinuity and arm_cpu_do_interrupt()'s exception
                 * callback can both describe the same wake event. */
                suppress_wait_exception = false;
                return;
            }
            /* 同步异常：记录 EC，继续协议，等待向量入口回调提交 */
            if (!have_pending) {
                fprintf(stderr,
                        "lcvex_difftest: step 模式收到异常但没有 pending "
                        "指令（from_pc=0x%llx to_pc=0x%llx）\n",
                        (unsigned long long)from_pc,
                        (unsigned long long)to_pc);
                sync_failed = true;
                return;
            }
            /*
             * ARM discon 的 from_pc 是首选返回地址（如 SVC 为指令+4，
             * 即 ELR 值），不一定是异常指令地址；异常指令地址以
             * pending 的 last_pc 为准。
             */
            fprintf(stderr,
                    "lcvex_difftest: 同步异常 ELR=0x%llx -> 向量 0x%llx "
                    "（异常指令 pc=0x%llx）\n",
                    (unsigned long long)from_pc,
                    (unsigned long long)to_pc,
                    (unsigned long long)last_pc);
            pending_exc_valid = true;
            pending_exc_kind = 1;
            pending_exc_code = ec;
            pending_exc_esr = esr;
            pending_exc_far = far;
            fprintf(stderr,
                    "lcvex_difftest: sync exception EC=0x%x from=0x%llx "
                    "to=0x%llx（转为异常 COMMIT）\n",
                    ec, (unsigned long long)from_pc,
                    (unsigned long long)to_pc);
            return;
        }
        if (kind == 2) {
            /*
             * P6：异步异常（IRQ/FIQ）转为异常 COMMIT。
             * 协议专用 exc_code=0x40（非 ESR.EC，ESR/FAR 无定义），
             * 与 RTL 的 EXC_IRQ 一致；IRQ 在指令边界取走，ELR 由
             * 协调器/向量入口状态比较。
             */
            if (suppress_wait_exception) {
                suppress_wait_exception = false;
                return;
            }
            if (!have_pending && wait_committed) {
                /* WFI/WFE 已先正常退休；IRQ 唤醒产生独立的合成
                 * 异步提交，协调器会让 DUT 从 idle 产生对应 packet。 */
                (void)send_wait_irq_commit(to_pc);
                return;
            }
            fprintf(stderr,
                    "lcvex_difftest: 异步异常 IRQ/FIQ -> 向量 0x%llx\n",
                    (unsigned long long)to_pc);
            pending_exc_valid = true;
            pending_exc_kind = 2;
            pending_exc_code = 0x40;
            pending_exc_esr = 0;
            pending_exc_far = 0;
            return;
        }
        /* kind==0：fork 未记录，回退到 DISCON 失败路径 */
    }

    memset(&dc, 0, sizeof(dc));
    switch (type) {
    case QEMU_PLUGIN_DISCON_EXCEPTION:
        dc.kind = 1;
        break;
    case QEMU_PLUGIN_DISCON_INTERRUPT:
        dc.kind = 2;
        break;
    case QEMU_PLUGIN_DISCON_HOSTCALL:
        dc.kind = 3;
        break;
    default:
        dc.kind = 0;
        break;
    }
    dc.pc = from_pc;
    dc.data = to_pc;
    if (send_msg(LCVEX_MSG_DISCON, msg_seq, &dc, sizeof(dc))) {
        fprintf(stderr, "lcvex_difftest: DISCON kind=%u from=0x%llx to=0x%llx\n",
                dc.kind,
                (unsigned long long)from_pc, (unsigned long long)to_pc);
    }
    sync_stopped = true;
}

/* QEMU 退出：上报 EXIT（不阻塞，协调器可能已结束）。 */
static void plugin_exit(void *userdata)
{
    struct lcvex_exit ex;

    (void)userdata;

    if (!sync_mode && !step_mode) {
        if (out != NULL) {
            gzclose(out);
        }
        return;
    }
    memset(&ex, 0, sizeof(ex));
    ex.reason = sync_failed ? 1 : (sync_stopped ? 2 : 0);
    ex.insns_committed = insns_committed;
    (void)send_msg(LCVEX_MSG_EXIT, msg_seq, &ex, sizeof(ex));
}

static void emit_state(const char *tag, uint64_t pc, uint32_t insn,
                       const char *disas, uint64_t next_pc)
{
    gzprintf(out, "%s pc=0x%016" PRIx64, tag, pc);
    if (fp_enabled) {
        gzprintf(out, " seq=%" PRIu64, trace_seq);
    }
    if (insn != 0 || (disas != NULL && disas[0] != '\0')) {
        gzprintf(out, " insn=0x%08" PRIx32, insn);
        if (disas != NULL && disas[0] != '\0') {
            gzprintf(out, " disas=\"%s\"", disas);
        }
    }
    for (int i = 0; i < 31; i++) {
        uint64_t val = reg_x_found[i] ? read_reg64(reg_x[i]) : 0;
        gzprintf(out, " x%d=0x%016" PRIx64, i, val);
    }
    gzprintf(out, " sp=0x%016" PRIx64, read_reg64(reg_sp));
    /*
     * next_pc 是下一条要执行的指令地址，直接取自当前回调的指令地址，
     * 不能读 env->pc：TCG 在 TB 内不保证逐指令更新 env->pc。
     */
    gzprintf(out, " next_pc=0x%016" PRIx64, next_pc);
    gzprintf(out, " nzcv=0x%01x", (read_cpsr() >> 28) & 0xf);
    /* P1 批量 trace difftest：异常与 exclusive 状态随行输出，
     * 协调器离线回放时与 DUT commit 精确比较。 */
    gzprintf(out, " exc_valid=%d", pending_exc_valid ? 1 : 0);
    if (pending_exc_valid) {
        gzprintf(out, " exc_code=0x%x exc_esr=0x%x exc_far=0x%llx",
                 (unsigned)pending_exc_code,
                 (unsigned)pending_exc_esr,
                 (unsigned long long)pending_exc_far);
    }
    gzprintf(out,
             " mon_we=%d mon_valid=%d mon_addr=0x%llx mon_data=0x%llx"
             " mon_data2=0x%llx",
             mon_valid ? 1 : 0, mon_valid ? 1 : 0,
             (unsigned long long)mon_addr,
             (unsigned long long)mon_data,
             (unsigned long long)mon_data2);
    gzprintf(out, " stores=%d", nstores);
    for (int i = 0; i < nstores; i++) {
        gzprintf(out, " s%d_addr=0x%016" PRIx64 " s%d_data=0x%016" PRIx64
                      " s%d_size=%u",
                 i, stores[i].addr, i, stores[i].data, i, stores[i].size);
    }
    gzprintf(out, "\n");
    gzflush(out, Z_SYNC_FLUSH);
}

static void emit_fp_state(const char *tag, uint64_t seq,
                          const struct lcvex_fp_state_v1 *state)
{
    gzprintf(out, "%s seq=%" PRIu64 " fpcr=0x%08" PRIx32
             " fpsr=0x%08" PRIx32, tag, seq, state->fpcr, state->fpsr);
    for (unsigned i = 0; i < 32; i++) {
        gzprintf(out, " v%u_lo=0x%016" PRIx64 " v%u_hi=0x%016" PRIx64,
                 i, state->v[i].lo, i, state->v[i].hi);
    }
    gzprintf(out, "\n");
    gzflush(out, Z_SYNC_FLUSH);
}

static bool trace_fp_init(void)
{
    struct qemu_lcvex_fp_state snapshot;
    unsigned reason = LCVEX_P7_REJECT_DESCRIPTOR;

    memset(&snapshot, 0, sizeof(snapshot));
    if (!fp_read_snapshot(&snapshot, &reason)) {
        fprintf(stderr, "lcvex_difftest: trace FP_INIT rejected reason=%u\n",
                reason);
        return false;
    }
    fp_state_from_snapshot(&snapshot, &fp_shadow);
    fp_shadow_valid = true;
    emit_fp_state("fp_init", 0, &fp_shadow);
    return true;
}

static bool trace_fp_commit(uint64_t seq, bool selected)
{
    struct qemu_lcvex_fp_state snapshot;
    struct lcvex_fp_state_v1 current;
    uint8_t payload[LCVEX_FP_COMMIT_MAX_BYTES];
    unsigned reason = LCVEX_P7_REJECT_DESCRIPTOR;
    size_t length;

    memset(&snapshot, 0, sizeof(snapshot));
    if (!fp_read_snapshot(&snapshot, &reason)) {
        fprintf(stderr, "lcvex_difftest: trace FP snapshot rejected reason=%u\n",
                reason);
        return false;
    }
    fp_state_from_snapshot(&snapshot, &current);
    if (!fp_shadow_valid) {
        return false;
    }
    length = fp_make_delta(&current, payload, sizeof(payload));
    if (length == 0) {
        fprintf(stderr, "lcvex_difftest: trace FP delta exceeds four V writes\n");
        return false;
    }
    if (selected) {
        if (trace_tail > 0 && commit_limit >= 0 &&
            commit_count == commit_limit - trace_tail) {
            emit_fp_state("fp_sync", seq, &fp_shadow);
        }
        uint32_t flags;
        uint32_t v_mask;
        uint32_t fpcr;
        uint32_t fpsr;
        memcpy(&flags, payload, sizeof(flags));
        memcpy(&v_mask, payload + 4, sizeof(v_mask));
        memcpy(&fpcr, payload + 8, sizeof(fpcr));
        memcpy(&fpsr, payload + 12, sizeof(fpsr));
        gzprintf(out, "fp_commit seq=%" PRIu64 " flags=0x%08" PRIx32
                 " v_mask=0x%08" PRIx32 " fpcr=0x%08" PRIx32
                 " fpsr=0x%08" PRIx32, seq, flags, v_mask, fpcr, fpsr);
        size_t offset = LCVEX_FP_COMMIT_HEADER_BYTES;
        for (unsigned i = 0; i < 32; i++) {
            if (v_mask & (UINT32_C(1) << i)) {
                struct lcvex_v128 value;
                memcpy(&value, payload + offset, sizeof(value));
                gzprintf(out, " v%u_lo=0x%016" PRIx64
                         " v%u_hi=0x%016" PRIx64,
                         i, value.lo, i, value.hi);
                offset += sizeof(value);
            }
        }
        gzprintf(out, "\n");
        gzflush(out, Z_SYNC_FLUSH);
    }
    fp_shadow = current;
    return true;
}

static void vcpu_mem(unsigned int vcpu_index, qemu_plugin_meminfo_t info,
                     uint64_t vaddr, void *userdata)
{
    qemu_plugin_mem_value v;
    store_rec_t *rec;
    insn_info_t *insn = (insn_info_t *)userdata;

    (void)vcpu_index;

    /* P6 内核锁步调试（dbgmem=1）：命中 0x42400000..0x42401000（VA）的
     * 访存打印虚拟/物理地址，用于核对 DUT 与 QEMU 的翻译是否一致。 */
    if (dbg_mem && (vaddr & 0xFFFFFFFFull) >= 0x42400000ull &&
        (vaddr & 0xFFFFFFFFull) < 0x42401000ull) {
        struct qemu_plugin_hwaddr *hw =
            qemu_plugin_get_hwaddr(info, vaddr);
        uint64_t hwaddr =
            hw ? qemu_plugin_hwaddr_phys_addr(hw) : ~0ull;
        const char *op = qemu_plugin_mem_is_store(info) ? "store" : "load";
        fprintf(stderr, "DBG mem %s va=0x%llx hw=0x%llx\n",
                op, (unsigned long long)vaddr,
                (unsigned long long)hwaddr);
    }

    v = qemu_plugin_mem_get_value(info);
    if (!qemu_plugin_mem_is_store(info)) {
        if (insn != NULL &&
            (((insn->insn & 0x3fa07c00u) == 0x08a07c00u) ||
             ((insn->insn & 0xffa07c00u) == 0x48207c00u))) {
            if (v.type == QEMU_PLUGIN_MEM_VALUE_U8) {
                atomic_old_value = v.data.u8;
                atomic_old_valid = true;
            } else if (v.type == QEMU_PLUGIN_MEM_VALUE_U16) {
                atomic_old_value = v.data.u16;
                atomic_old_valid = true;
            } else if (v.type == QEMU_PLUGIN_MEM_VALUE_U32) {
                atomic_old_value = v.data.u32;
                atomic_old_valid = true;
            } else if (v.type == QEMU_PLUGIN_MEM_VALUE_U64) {
                atomic_old_value = v.data.u64;
                atomic_old_valid = true;
            } else if (v.type == QEMU_PLUGIN_MEM_VALUE_U128) {
                atomic_old_value = v.data.u128.low;
                atomic_old_value2 = v.data.u128.high;
                atomic_old_valid = true;
            }
        }
        return;
    }
    if (nstores >= MAX_STORES_PER_INSN) {
        return;
    }
    if (v.type == QEMU_PLUGIN_MEM_VALUE_U128) {
        /* STP X 对：QEMU 以单笔 16 字节存储上报。拆成两个 8 字节记录
         * （低 64 位 + 高 64 位），与 RTL 提交包 mem/mem2 一一对应，
         * 确保成对存储的两个寄存器数据都被差分校验（旧实现只保留
         * u128.low，锁步路径因 strb 截断成 8 位而掩盖了第二段缺失）。
         */
        if (nstores + 1 >= MAX_STORES_PER_INSN) {
            return;
        }
        stores[nstores].addr = vaddr;
        stores[nstores].data = v.data.u128.low;
        stores[nstores].size = 8;
        stores[nstores + 1].addr = vaddr + 8;
        stores[nstores + 1].data = v.data.u128.high;
        stores[nstores + 1].size = 8;
        nstores += 2;
        return;
    }
    rec = &stores[nstores++];
    rec->addr = vaddr;
    switch (v.type) {
    case QEMU_PLUGIN_MEM_VALUE_U8:
        rec->data = v.data.u8;
        rec->size = 1;
        break;
    case QEMU_PLUGIN_MEM_VALUE_U16:
        rec->data = v.data.u16;
        rec->size = 2;
        break;
    case QEMU_PLUGIN_MEM_VALUE_U32:
        rec->data = v.data.u32;
        rec->size = 4;
        break;
    case QEMU_PLUGIN_MEM_VALUE_U64:
        rec->data = v.data.u64;
        rec->size = 8;
        break;
    }
}

static void vcpu_insn_exec(unsigned int vcpu_index, void *udata)
{
    insn_info_t *info = (insn_info_t *)udata;

    (void)vcpu_index;

    if (sync_mode || step_mode) {
        if (timer_restore_path != NULL && !timer_restore_done) {
            if (qemu_lcvex_difftest_restore_timer_state(timer_restore_path) < 0) {
                fprintf(stderr,
                        "lcvex_difftest: timer sidecar 恢复失败: %s\n",
                        timer_restore_path);
                sync_failed = true;
                return;
            }
            timer_restore_done = true;
        }
        sync_insn_cb(info);
        return;
    }

    if (!have_last) {
        /* 第一条指令：导出初始状态 */
        if (fp_enabled && !trace_fp_init()) {
            sync_failed = true;
            return;
        }
        emit_state("init", info->vaddr, 0, NULL, info->vaddr);
        have_last = true;
    } else {
        /* 导出上一条指令的提交状态（当前状态即其后状态） */
        if (excl_insn_kind(last_insn) == 2) {
            int rs = (last_insn >> 16) & 31;
            if (rs != 31 && read_reg64(reg_x[rs]) != 0) {
                nstores = 0;
            }
        }
        /* trace 模式：exclusive 监视器与异常标志随行输出（P1 回放） */
        if (trace_tail >= 0) {
            struct lcvex_commit tmpcm;
            memset(&tmpcm, 0, sizeof(tmpcm));
            apply_monitor_effect(last_insn,
                                 pending_exc_valid ? pending_exc_kind : 0,
                                 pending_exc_code, &tmpcm);
        }
        if (commit_limit < 0 || commit_count < commit_limit) {
            bool selected = trace_tail <= 0 || commit_limit < 0 ||
                            commit_count >= commit_limit - trace_tail;
            if (fp_enabled && !trace_fp_commit((uint64_t)commit_count,
                                                selected)) {
                sync_failed = true;
                return;
            }
            /* tail=N：只写最后 N 条（定位深启动分叉点，避免巨大 trace） */
            if (selected) {
                emit_state("commit", last_pc, last_insn, last_disas,
                           info->vaddr);
            }
            commit_count++;
            trace_seq++;
        } else {
            return;
        }
        pending_exc_valid = false;
        pending_exc_kind = 0;
        pending_exc_code = 0;
        pending_exc_esr = 0;
        pending_exc_far = 0;
    }

    last_pc = info->vaddr;
    last_insn = info->insn;
    snprintf(last_disas, sizeof(last_disas), "%s", info->disas);
    nstores = 0;
    atomic_old_valid = false;
    atomic_old_value = 0;
    atomic_old_value2 = 0;
}

static void vcpu_tb_trans(struct qemu_plugin_tb *tb, void *userdata)
{
    size_t n_insns = qemu_plugin_tb_n_insns(tb);

    (void)userdata;

    for (size_t i = 0; i < n_insns; i++) {
        struct qemu_plugin_insn *insn = qemu_plugin_tb_get_insn(tb, i);
        insn_info_t *info = g_new0(insn_info_t, 1);
        uint8_t bytes[4];
        char *disas;

        /* insn 句柄会被复用，翻译时就把需要的数据拷贝出来 */
        info->vaddr = qemu_plugin_insn_vaddr(insn);
        memset(bytes, 0, sizeof(bytes));
        qemu_plugin_insn_data(insn, bytes, sizeof(bytes));
        memcpy(&info->insn, bytes, sizeof(bytes)); /* 小端 */
        disas = qemu_plugin_insn_disas(insn);
        snprintf(info->disas, sizeof(info->disas), "%s",
                 disas != NULL ? disas : "?");
        g_free(disas);

        qemu_plugin_register_vcpu_insn_exec_cb(insn, vcpu_insn_exec,
                                               QEMU_PLUGIN_CB_R_REGS, info);
        qemu_plugin_register_vcpu_mem_cb(insn, vcpu_mem,
                                         QEMU_PLUGIN_CB_NO_REGS,
                                         QEMU_PLUGIN_MEM_RW, info);
    }
}

static void vcpu_init(unsigned int vcpu_index, void *userdata)
{
    GArray *regs = qemu_plugin_get_registers();

    (void)vcpu_index;
    (void)userdata;

    for (guint i = 0; i < regs->len; i++) {
        qemu_plugin_reg_descriptor *d =
            &g_array_index(regs, qemu_plugin_reg_descriptor, i);
        int n;
        if (sscanf(d->name, "x%d", &n) == 1 && n >= 0 && n <= 30) {
            reg_x[n] = d->handle;
            reg_x_found[n] = true;
        } else if (strcmp(d->name, "sp") == 0) {
            reg_sp = d->handle;
        } else if (strcmp(d->name, "pc") == 0) {
            reg_pc = d->handle;
        } else if (strcmp(d->name, "cpsr") == 0) {
            reg_cpsr = d->handle;
        }
    }
    g_array_free(regs, TRUE);

    if (reg_sp == NULL || reg_cpsr == NULL) {
        fprintf(stderr, "lcvex_difftest: 未找到 aarch64 核心寄存器句柄\n");
        exit(1);
    }
    if (fp_required && !fp_preflight_done) {
        unsigned reason = LCVEX_P7_REJECT_DESCRIPTOR;
        if (!fp_preflight_descriptors(&reason)) {
            fprintf(stderr,
                    "lcvex_difftest: P7 FP descriptor preflight 失败，reason=%u\n",
                    reason);
            send_p7_reject(reason, fp_descriptor_vector_bytes);
            return;
        }
        fp_preflight_done = true;
        fp_enabled = true;
        /* 只有 canonical 16B V profile 才允许产生 P7 checkpoint。 */
        fp_checkpoint_allowed = fp_profile == FP_PROFILE_V;
    }
}

QEMU_PLUGIN_EXPORT int qemu_plugin_version = QEMU_PLUGIN_VERSION;

QEMU_PLUGIN_EXPORT int qemu_plugin_install(qemu_plugin_id_t id,
                                           const qemu_info_t *info,
                                           int argc, char **argv)
{
    plugin_id = id;
    timer_restore_path = g_getenv("LCVEX_TIMER_RESTORE_PATH");

    (void)info;

    for (int i = 0; i < argc; i++) {
        if (g_str_has_prefix(argv[i], "trace=")) {
            trace_path = argv[i] + strlen("trace=");
        } else if (g_str_has_prefix(argv[i], "limit=")) {
            commit_limit = g_ascii_strtoll(argv[i] + strlen("limit="),
                                           NULL, 10);
        } else if (g_str_has_prefix(argv[i], "tail=")) {
            trace_tail = g_ascii_strtoll(argv[i] + strlen("tail="),
                                         NULL, 10);
        } else if (g_str_has_prefix(argv[i], "dbgmem=")) {
            dbg_mem = (g_ascii_strtoll(argv[i] + strlen("dbgmem="),
                                       NULL, 10) != 0);
        } else if (g_str_has_prefix(argv[i], "fp=")) {
            const char *mode = argv[i] + strlen("fp=");
            if (strcmp(mode, "required") == 0) {
                fp_required = true;
            } else if (strcmp(mode, "off") == 0) {
                fp_required = false;
            } else {
                fprintf(stderr, "lcvex_difftest: fp= 只接受 off|required\n");
                return -1;
            }
        } else if (strcmp(argv[i], "mode=sync") == 0) {
            sync_mode = true;
        } else if (strcmp(argv[i], "mode=step") == 0) {
            step_mode = true;
        } else if (g_str_has_prefix(argv[i], "socket=")) {
            const char *path = argv[i] + strlen("socket=");
            struct sockaddr_un addr;
            struct timeval tv = { .tv_sec = 300, .tv_usec = 0 };
            sock_fd = socket(AF_UNIX, SOCK_SEQPACKET, 0);
            if (sock_fd < 0) {
                fprintf(stderr, "lcvex_difftest: socket() 失败: %s\n",
                        strerror(errno));
                return -1;
            }
            memset(&addr, 0, sizeof(addr));
            addr.sun_family = AF_UNIX;
            snprintf(addr.sun_path, sizeof(addr.sun_path), "%s", path);
            if (connect(sock_fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
                fprintf(stderr, "lcvex_difftest: connect %s 失败: %s\n",
                        path, strerror(errno));
                return -1;
            }
            setsockopt(sock_fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
            setsockopt(sock_fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
        }
    }

    if (sync_mode || step_mode) {
        struct lcvex_msg_header hdr;
        struct lcvex_hello hello;
        struct lcvex_config cfg;
        size_t plen = 0;
        if (sock_fd < 0) {
            fprintf(stderr,
                    "lcvex_difftest: 锁步模式需要 socket= 参数\n");
            return -1;
        }
        if (step_mode && !qemu_lcvex_difftest_active()) {
            fprintf(stderr,
                    "lcvex_difftest: mode=step 需要 QEMU fork step hook，"
                    "请设置 LCVEX_DIFFTEST_STEP=1\n");
            return -1;
        }
        memset(&hello, 0, sizeof(hello));
        hello.qemu_major = 11;
        hello.qemu_minor = 1;
        hello.qemu_micro = 0;
        hello.api_version = fp_required ? 2u : 1u;
        hello.arch = 1; /* aarch64 */
        hello.vcpu_count = 1;
        if (!send_msg(LCVEX_MSG_HELLO, 0, &hello, sizeof(hello)) ||
            !recv_msg(&hdr, &cfg, sizeof(cfg), &plen) ||
            hdr.type != LCVEX_MSG_CONFIG || hdr.seq != 0 ||
            plen != sizeof(cfg)) {
            fprintf(stderr, "lcvex_difftest: 锁步握手失败\n");
            return -1;
        }
        if (fp_required && !(cfg.state_mask & LCVEX_CFG_CAP_FP_NEON)) {
            fprintf(stderr,
                    "lcvex_difftest: coordinator 未提供 P7 capability\n");
            send_p7_reject(LCVEX_P7_REJECT_NO_CAP, 0);
            return -1;
        }
        fp_enabled = fp_required;
    } else {
        out = gzopen(trace_path, "w");
        if (out == NULL) {
            fprintf(stderr, "lcvex_difftest: 无法打开输出文件 %s\n",
                    trace_path);
            return -1;
        }
        gzprintf(out, "# lcvex-qemu-trace %s gzip\n",
                 fp_required ? "v2" : "v1");
        gzflush(out, Z_SYNC_FLUSH);
    }

    qemu_plugin_register_vcpu_init_cb(id, vcpu_init, NULL);
    qemu_plugin_register_vcpu_tb_trans_cb(id, vcpu_tb_trans, NULL);
    if (sync_mode || step_mode) {
        qemu_plugin_register_vcpu_idle_cb(id, vcpu_idle_cb, NULL);
        qemu_plugin_register_vcpu_resume_cb(id, vcpu_resume_cb, NULL);
        /* Q5/Q6：异常/中断/host call 造成 PC discontinuity 时上报 */
        qemu_plugin_register_vcpu_discon_cb(
            id, QEMU_PLUGIN_DISCON_ALL, vcpu_discon, NULL);
    }
    qemu_plugin_register_atexit_cb(id, plugin_exit, NULL);
    return 0;
}
