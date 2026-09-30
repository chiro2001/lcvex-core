/* LCVEX 锁步差分二进制协议（QEMU 插件与 Verilator 协调器共用）。
 *
 * 传输：Unix domain SOCK_SEQPACKET，每条消息原子收发。
 * 字节序：little-endian（x86 host）。所有结构体 1 字节对齐。
 * 设计见 docs/DIFFTEST_QEMU_PLAN.md。
 */
#ifndef LCVEX_PROTOCOL_H
#define LCVEX_PROTOCOL_H

#include <stddef.h>
#include <stdint.h>
#include <string.h>

#ifdef __cplusplus
extern "C" {
#endif

#define LCVEX_MSG_MAGIC   0x5446444cu  /* 'LDFT' */
#define LCVEX_MSG_VERSION 1u

/* P7 capability and frame limits.  The scalar wire version remains 1. */
#define LCVEX_CFG_CAP_FP_NEON       UINT32_C(0x80000000)
#define LCVEX_FP_FEATURE_NEON       UINT32_C(0x00000001)
#define LCVEX_FP_VECTOR_BYTES       16u
#define LCVEX_FP_INIT_BYTES         520u
#define LCVEX_FP_COMMIT_HEADER_BYTES 16u
#define LCVEX_FP_COMMIT_MAX_BYTES   528u
#define LCVEX_FP_MAX_VECTORS        4u
#define LCVEX_FP_FILE_BYTES         552u

/* 消息类型 */
enum {
    LCVEX_MSG_HELLO  = 1,  /* QEMU -> Host */
    LCVEX_MSG_CONFIG = 2,  /* Host -> QEMU */
    LCVEX_MSG_INIT   = 3,  /* QEMU -> Host */
    LCVEX_MSG_PRE    = 4,  /* QEMU -> Host */
    LCVEX_MSG_GO     = 5,  /* Host -> QEMU */
    LCVEX_MSG_COMMIT = 6,  /* QEMU -> Host */
    LCVEX_MSG_ACK    = 7,  /* Host -> QEMU */
    LCVEX_MSG_DISCON = 8,  /* QEMU -> Host */
    LCVEX_MSG_STOP   = 9,  /* Host -> QEMU */
    LCVEX_MSG_EXIT   = 10, /* QEMU -> Host */
    LCVEX_MSG_CKPT_REQ   = 11, /* Host -> QEMU：保存设备状态 */
    LCVEX_MSG_CKPT_READY = 12, /* QEMU -> Host：设备状态已保存 */
    LCVEX_MSG_ASYNC  = 13,    /* QEMU -> Host：等待后异步 IRQ 提交 */
    LCVEX_MSG_WAIT   = 14,    /* QEMU -> Host：等待指令实际进入 idle */
    LCVEX_MSG_WAIT_RESUME = 15, /* QEMU -> Host：等待恢复时的 CNTVCT */
    LCVEX_MSG_FP_INIT = 16,   /* QEMU -> Host：P7 full FP state */
    LCVEX_MSG_FP_COMMIT = 17,/* QEMU -> Host：P7 FP state delta */
    LCVEX_MSG_P7_REJECT = 18  /* QEMU -> Host：P7 required/preflight reject */
};

enum {
    LCVEX_P7_REJECT_NO_CAP = 1,
    LCVEX_P7_REJECT_DESCRIPTOR = 2,
    LCVEX_P7_REJECT_PROFILE = 3,
    LCVEX_P7_REJECT_UPPER_NONZERO = 4,
    LCVEX_P7_REJECT_PROTOCOL_LENGTH = 5
};

/* ACK 状态 */
enum {
    LCVEX_ACK_OK   = 0,
    LCVEX_ACK_FAIL = 1
};

#pragma pack(push, 1)

struct lcvex_msg_header {
    uint32_t magic;
    uint16_t version;
    uint16_t type;
    uint32_t flags;
    uint32_t payload_len;
    uint64_t seq;
};

/* HELLO：QEMU 插件启动时发送 */
struct lcvex_hello {
    uint32_t qemu_major;
    uint32_t qemu_minor;
    uint32_t qemu_micro;
    uint32_t api_version;
    uint32_t arch;       /* 1 = aarch64 */
    uint32_t vcpu_count;
};

/* CONFIG：协调器回复 HELLO */
struct lcvex_config {
    uint32_t vcpu_count;  /* 必须为 1 */
    uint64_t max_insns;   /* 0 = 不限 */
    uint32_t timeout_ms;
    uint32_t state_mask;
};

/* 架构状态快照（INIT/PRE/COMMIT 复用） */
struct lcvex_state {
    uint64_t pc;
    uint64_t next_pc;
    uint32_t insn;
    uint64_t x[31];
    uint64_t sp;
    uint32_t nzcv;       /* bit3=N bit2=Z bit1=C bit0=V */
};

/* PRE：指令执行前状态 */
struct lcvex_pre {
    struct lcvex_state pre;
};

#define LCVEX_MAX_STORES 8

struct lcvex_store {
    uint64_t addr;
    uint64_t data;
    uint8_t  strb;
    uint8_t  pad[7];
};

/* COMMIT：指令执行后状态 + RTL 提交包写回事件 + 内存写 */
struct lcvex_commit {
    struct lcvex_state post;
    uint8_t  gpr_we;
    uint8_t  gpr_rd;
    uint8_t  sp_we;
    uint8_t  nzcv_we;
    uint64_t gpr_wdata;
    uint64_t sp_wdata;
    uint32_t nzcv;
    uint8_t  exc_valid;
    uint8_t  pad[7];
    uint32_t exc_code;
    uint64_t exc_far;   /* FAR_EL1（abort 类；其余 0） */
    uint32_t exc_esr;   /* 完整 ESR（EC<<26|ISS，含 IL；其余 0） */
    uint32_t pad2;
    /* exclusive 监视器（M3）：mon_we=1 表示本提交更新监视器；
     * mon_valid=1 表示 LDXR 记录了地址/值（STXR/CLREX/ERET 清）。 */
    uint8_t  mon_we;
    uint8_t  mon_valid;
    uint8_t  pad3[6];
    uint64_t mon_addr;
    uint64_t mon_data;
    uint64_t mon_data2;   /* LDXP/LDAXP 128 位监视器高半（M6） */
    uint32_t store_count;
    struct lcvex_store stores[LCVEX_MAX_STORES];
};

/* ACK：协调器对 COMMIT 的比较结果 */
struct lcvex_ack {
    uint32_t status;      /* LCVEX_ACK_* */
    uint32_t error_code;
    char     detail[256];
};

/* DISCON：PC discontinuity（异常/中断/host call）。
 * kind=4 为访客请求整机复位/关机（PSCI SYSTEM_RESET/SYSTEM_OFF）：
 * QEMU 已执行 machine reset/shutdown，架构状态不再连续，协调器应把
 * 当前窗口定义为“访客请求复位/关机”终止（非 FAIL，需人工确认原因）。 */
struct lcvex_discon {
    uint32_t kind;        /* 1=exception 2=interrupt 3=hostcall 4=guest reset/shutdown */
    uint32_t reserved;
    uint64_t pc;
    uint64_t data;
};

#define LCVEX_DISCON_GUEST_RESET 4u

/* EXIT：插件退出 */
struct lcvex_exit {
    uint32_t reason;
    uint32_t reserved;
    uint64_t insns_committed;
};

/* WAIT_RESUME：QEMU 真实 halt 后因 timeout/event 恢复、下一 PRE 之前的
 * 虚拟计数。协调器用它精确同步 DUT 的 idle 期间计时，不把 host wall clock
 * 引入 Verilator。 */
struct lcvex_wait_resume {
    uint64_t cntvct;
};

/* 差分 checkpoint 控制面。路径由本地协调器生成，QEMU 不解析 guest 输入。 */
struct lcvex_ckpt_req {
    char dev_path[512];
    char sys_path[512];
    char timer_path[512];
    char gic_path[512];
};

struct lcvex_ckpt_ready {
    int32_t status;       /* 0=成功，负数=QEMU 保存失败 */
    char detail[256];
};

struct lcvex_v128 {
    uint64_t lo;
    uint64_t hi;
};

/* P7 FP_INIT: exactly 8 + 32 * 16 = 520 bytes. */
struct lcvex_fp_state_v1 {
    uint32_t fpcr;
    uint32_t fpsr;
    struct lcvex_v128 v[32];
};

/* P7 FP_COMMIT fixed prefix.  The vector array is serialized immediately
 * after this prefix in ascending V-register number order. */
struct lcvex_fp_commit_delta_v1 {
    uint32_t flags;
    uint32_t v_mask;
    uint32_t fpcr;
    uint32_t fpsr;
    struct lcvex_v128 v[];
};

struct lcvex_p7_reject {
    uint32_t reason;
    uint32_t vector_bytes;
};

/* LCVXFP01 raw sidecar.  It is intentionally separate from QEMU VMState. */
struct lcvex_fp_state_file_v1 {
    char magic[8];
    uint32_t version;
    uint32_t size;
    uint32_t feature_bits;
    uint32_t vector_bytes;
    uint64_t seq;
    uint32_t fpcr;
    uint32_t fpsr;
    uint64_t v[32][2];
};

#pragma pack(pop)

#if defined(__cplusplus)
static_assert(sizeof(struct lcvex_msg_header) == 24,
              "LCVEX message header ABI changed");
static_assert(sizeof(struct lcvex_fp_state_v1) == LCVEX_FP_INIT_BYTES,
              "LCVEX FP_INIT ABI changed");
static_assert(sizeof(struct lcvex_fp_commit_delta_v1) ==
                  LCVEX_FP_COMMIT_HEADER_BYTES,
              "LCVEX FP_COMMIT prefix ABI changed");
static_assert(sizeof(struct lcvex_p7_reject) == 8,
              "LCVEX P7_REJECT ABI changed");
static_assert(sizeof(struct lcvex_fp_state_file_v1) == LCVEX_FP_FILE_BYTES,
              "LCVXFP01 ABI changed");
#else
_Static_assert(sizeof(struct lcvex_msg_header) == 24,
               "LCVEX message header ABI changed");
_Static_assert(sizeof(struct lcvex_fp_state_v1) == LCVEX_FP_INIT_BYTES,
               "LCVEX FP_INIT ABI changed");
_Static_assert(sizeof(struct lcvex_fp_state_file_v1) == LCVEX_FP_FILE_BYTES,
               "LCVXFP01 ABI changed");
#endif

/* 编码一条消息到 out（out_cap 至少 sizeof(header)+payload_len）。
 * 返回总字节数；缓冲区不足返回 0。 */
static inline size_t lcvex_msg_encode(const struct lcvex_msg_header *hdr,
                                      const void *payload,
                                      uint8_t *out, size_t out_cap)
{
    size_t total = sizeof(*hdr) + hdr->payload_len;
    if (out_cap < total) {
        return 0;
    }
    memcpy(out, hdr, sizeof(*hdr));
    if (hdr->payload_len > 0) {
        memcpy(out + sizeof(*hdr), payload, hdr->payload_len);
    }
    return total;
}

#ifdef __cplusplus
}
#endif

#endif /* LCVEX_PROTOCOL_H */
