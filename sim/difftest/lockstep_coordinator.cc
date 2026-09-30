// lockstep_coordinator.cc
// Verilator DUT 与 QEMU 插件的锁步协调器（见 docs/DIFFTEST_QEMU_PLAN.md）。
//
// 时序：
//   HELLO(QEMU) -> CONFIG(协调器) -> INIT(QEMU) -> PRE(QEMU)
//   -> 协调器推进 DUT 到 commit -> GO -> QEMU 执行
//   -> COMMIT(QEMU) -> 比较 -> ACK
//
// 退出码：0 = 全部一致；1 = 协议/比较失败；2 = 参数错误；
//         3 = 访客请求复位/关机（PSCI SYSTEM_RESET/SYSTEM_OFF）终止窗口。

#include <cerrno>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <iomanip>
#include <algorithm>
#include <array>
#include <cerrno>
#include <fcntl.h>
#include <limits>
#include <ostream>
#include <stdexcept>
#include <string>
#include <vector>

#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/un.h>
#include <unistd.h>
#include <zlib.h>

#include "Vlcvex_soc_tb.h"
#include "Vlcvex_soc_tb___024root.h"
#include "verilated.h"

#include "../../qemu/plugins/lcvex_protocol.h"
#include "../mmio/lcvex_mmio_fabric.h"

namespace {

static bool protocol_fp_commit_length_valid(const uint8_t *payload,
                                            size_t plen);

struct CommitPacket {
    uint64_t pc = 0, next_pc = 0;
    uint32_t insn = 0;
    bool gpr_we = false;
    uint8_t gpr_rd = 0;
    uint64_t gpr_wdata = 0;
    bool gpr2_we = false;
    uint8_t gpr2_rd = 0;
    uint64_t gpr2_wdata = 0;
    bool gpr3_we = false;
    uint8_t gpr3_rd = 0;
    uint64_t gpr3_wdata = 0;
    bool sp_we = false;
    uint64_t sp_wdata = 0;
    bool nzcv_we = false;
    uint8_t nzcv = 0;
    bool mem_we = false;
    uint64_t mem_addr = 0, mem_wdata = 0;
    uint8_t mem_strb = 0;
    bool mem2_we = false;
    uint64_t mem2_addr = 0, mem2_wdata = 0;
    uint8_t mem2_strb = 0;
    bool exc_valid = false;
    uint32_t exc_code = 0;
    uint32_t exc_esr = 0;
    uint64_t exc_far = 0;
    bool mon_we = false;
    bool mon_valid = false;
    uint64_t mon_addr = 0, mon_data = 0;
    uint64_t mon_data2 = 0;   // LDXP/LDAXP 128 位监视器高半
    /* P7 effect boundary.  These fields are populated only after the
     * integrator exposes the matching flat SoC ports; the wire never carries
     * these write-enable bits. */
    bool fp_effect_available = false;
    uint8_t vec_write_count = 0;
    std::array<uint8_t, LCVEX_FP_MAX_VECTORS> vec_rd = {};
    std::array<lcvex_v128, LCVEX_FP_MAX_VECTORS> vec_wdata = {};
    bool fpcr_we = false;
    uint32_t fpcr_wdata = 0;
    bool fpsr_we = false;
    uint32_t fpsr_wdata = 0;
};

struct FpState {
    uint32_t fpcr = 0;
    uint32_t fpsr = 0;
    std::array<lcvex_v128, 32> v = {};
};

/* 保留最近一次 P7 raw state，供任意失败路径写入完整诊断包。普通
 * scalar/ASYNC/WAIT 路径不会修改或比较该 sidecar。 */
static bool g_failure_fp_valid = false;
static FpState g_failure_dut_fp = {};
static FpState g_failure_qemu_fp = {};
static std::string g_failure_fp_first_mismatch;

static bool fp_state_equal(const FpState &a, const FpState &b) {
    return a.fpcr == b.fpcr && a.fpsr == b.fpsr &&
           memcmp(a.v.data(), b.v.data(), sizeof(a.v)) == 0;
}

static bool parse_fp_init(const uint8_t *payload, size_t plen,
                          FpState *state) {
    if (payload == nullptr || state == nullptr ||
        plen != sizeof(lcvex_fp_state_v1)) {
        return false;
    }
    lcvex_fp_state_v1 wire = {};
    memcpy(&wire, payload, sizeof(wire));
    state->fpcr = wire.fpcr;
    state->fpsr = wire.fpsr;
    memcpy(state->v.data(), wire.v, sizeof(wire.v));
    return true;
}

static bool apply_fp_delta(const uint8_t *payload, size_t plen,
                           FpState *state, std::string *error) {
    if (payload == nullptr || state == nullptr ||
        !protocol_fp_commit_length_valid(payload, plen)) {
        if (error != nullptr) *error = "FP_COMMIT 长度/保留位/popcount 非法";
        return false;
    }
    uint32_t flags = 0;
    uint32_t v_mask = 0;
    uint32_t fpcr = 0;
    uint32_t fpsr = 0;
    memcpy(&flags, payload, sizeof(flags));
    memcpy(&v_mask, payload + 4, sizeof(v_mask));
    memcpy(&fpcr, payload + 8, sizeof(fpcr));
    memcpy(&fpsr, payload + 12, sizeof(fpsr));
    if (!(flags & 1u) && fpcr != state->fpcr) {
        if (error != nullptr) *error = "FP_COMMIT flags 未声明 FPCR 改变";
        return false;
    }
    if (!(flags & 2u) && fpsr != state->fpsr) {
        if (error != nullptr) *error = "FP_COMMIT flags 未声明 FPSR 改变";
        return false;
    }
    state->fpcr = fpcr;
    state->fpsr = fpsr;
    size_t offset = LCVEX_FP_COMMIT_HEADER_BYTES;
    for (unsigned i = 0; i < 32; i++) {
        if (v_mask & (UINT32_C(1) << i)) {
            memcpy(&state->v[i], payload + offset, sizeof(state->v[i]));
            offset += sizeof(state->v[i]);
        }
    }
    return true;
}

static bool apply_dut_fp_effect(const CommitPacket &packet,
                                FpState *state, std::string *error) {
    if (packet.vec_write_count > LCVEX_FP_MAX_VECTORS) {
        if (error != nullptr) *error = "DUT vec_write_count 超过 4";
        return false;
    }
    if (!packet.fp_effect_available) {
        /* Current owner branch has no top-level FP ports yet.  A zero delta is
         * still a valid P7-0 scalar boundary; any observable QEMU FP change
         * must wait for the integrator's explicit port wiring. */
        return packet.vec_write_count == 0 && !packet.fpcr_we &&
               !packet.fpsr_we;
    }
    bool seen[32] = {};
    for (unsigned i = 0; i < packet.vec_write_count; i++) {
        if (packet.vec_rd[i] >= 32 || seen[packet.vec_rd[i]]) {
            if (error != nullptr) *error = "DUT FP destination 重复/越界";
            return false;
        }
        seen[packet.vec_rd[i]] = true;
        state->v[packet.vec_rd[i]] = packet.vec_wdata[i];
    }
    if (packet.fpcr_we) state->fpcr = packet.fpcr_wdata;
    if (packet.fpsr_we) state->fpsr = packet.fpsr_wdata;
    return true;
}

// 与 QEMU plugin 的 is_wait_insn 保持一致。WFI/WFE 在 QEMU helper 内可能因
// cpu_has_work() 立即返回；这种路径没有 vCPU idle callback，而会直接给出
// 下一条 PRE。WFIT/WFET 的下一条 PRE 则还可能表示 timer timeout，必须保留
// RTL idle 期间的逐周期计数，不可把它误当 event 唤醒。
static bool is_wait_instruction(uint32_t insn) {
    return insn == 0xd503207fU || insn == 0xd503205fU ||
           (insn & 0xffffffe0U) == 0xd5031000U ||
           (insn & 0xffffffe0U) == 0xd5031020U;
}

static bool is_wfi_wfe_instruction(uint32_t insn) {
    return insn == 0xd503207fU || insn == 0xd503205fU;
}

#pragma pack(push, 1)
struct DutSysState {
    char magic[8];
    uint32_t version;
    uint32_t size;
    uint64_t x[31];
    uint64_t pc, next_pc;
    uint64_t sp_el0, sp_el1, pstate, daif;
    uint64_t elr_el1, spsr_el1, vbar_el1, sctlr_el1;
    uint64_t tcr_el1, ttbr0_el1, ttbr1_el1, mair_el1;
    uint64_t esr_el1, far_el1, par_el1, cpacr_el1;
    uint64_t mdscr_el1, cntkctl_el1;
    uint64_t tpidr_el0, tpidrro_el0, tpidr_el1;
    uint64_t pir_el1, pire0_el1;
    uint32_t nzcv;
    uint8_t el, sp_sel;
    uint8_t reserved[6];
    /* v2（LCVXSYS2）：SVE/SME 探测控制寄存器与缓存选择器。旧 v1
     * sidecar（LCVXSYS1，476 字节）读取时这三个字段保持 0。 */
    uint64_t zcr_el1;
    uint64_t smcr_el1;
    uint64_t csselr_el1;
    /* v3（LCVXSYS3）：此前已实现但未序列化的 PMU/PIE 控制与
     * exclusive monitor。exclusive_addr=~0 表示 monitor 无效。 */
    uint64_t pmuserenr_el0;
    uint64_t tcr2_el1;
    uint64_t exclusive_addr;
    uint64_t exclusive_val;
    uint64_t exclusive_high;
    /* v4（LCVXSYS4）：CONTEXTIDR_EL1。 */
    uint64_t contextidr_el1;
};
#pragma pack(pop)
static_assert(sizeof(DutSysState) == 548, "DutSysState layout changed");

#pragma pack(push, 1)
struct DutTimerState {
    char magic[8];
    uint32_t version;
    uint32_t size;
    uint64_t cntpct;
    uint64_t cntfrq;
    uint64_t cntvoff_el2;
    uint64_t cntpoff_el2;
    uint64_t cntp_cval;
    uint64_t cntp_ctl;
    uint64_t cntv_cval;
    uint64_t cntv_ctl;
};
#pragma pack(pop)
static_assert(sizeof(DutTimerState) == 80, "DutTimerState layout changed");

#pragma pack(push, 1)
struct DutGicIrqState {
    uint8_t enabled;
    uint8_t pending;
    uint8_t active;
    uint8_t level;
    uint8_t edge;
    uint8_t group;
};

struct DutGicState {
    char magic[8];
    uint32_t version;
    uint32_t size;
    uint32_t num_irq;
    uint32_t reserved;
    uint32_t ctlr;
    uint32_t cpu_ctlr;
    uint16_t priority_mask;
    uint16_t running_priority;
    uint16_t current_pending;
    uint8_t bpr;
    uint8_t abpr;
    uint8_t reserved2[2];
    DutGicIrqState irq[96];
    uint8_t priority[96];
    uint8_t sgi_pending[16];
    uint16_t reserved3;
};
#pragma pack(pop)
static_assert(sizeof(DutGicState) == 732, "DutGicState layout changed");

struct ShadowState {
    uint64_t x[31] = {};
    uint64_t sp = 0;
    uint8_t nzcv = 0;
    uint64_t pc = 0;
};

/* 最近提交窗口（失败时保存，最多 32 条） */
struct WindowRec {
    uint64_t seq = 0;
    uint64_t pre_pc = 0, pre_insn = 0;
    uint64_t dut_pc = 0, dut_insn = 0, dut_next_pc = 0;
    uint64_t qemu_pc = 0, qemu_insn = 0, qemu_next_pc = 0;
    bool ok = false;
};

std::vector<WindowRec> g_window;

/* 失败包中的运行上下文。FP failure 发生在协议边界，不能只保存一行
 * 文本；把握手能力、profile、checkpoint 输入和 restore provenance 一并
 * 锁存，保证脱离当前进程后仍可判断该包来自哪条可重放路径。 */
struct FpFailureContext {
    std::string cpu_profile = "cortex-a76,has_el3=false,has_el2=false";
    bool fp_required = false;
    bool restore_mode = false;
    bool restore_fp_mode = false;
    bool fp_ready = false;
    uint32_t hello_api_version = 0;
    uint32_t config_state_mask = 0;
    uint64_t max_insns = 0;
    uint64_t ckpt_every = 0;
    uint64_t next_ckpt_seq = 0;
    bool diff_ckpt = false;
    std::string image;
    uint64_t base = 0;
    std::string ckpt_dir;
    std::string monitor_path;
    std::string ram_path;
    std::string restore_arch_path;
    std::string restore_sys_path;
    std::string restore_fp_path;
};

static FpFailureContext g_fp_failure_context;

void window_push(const WindowRec &r) {
    g_window.push_back(r);
    if (g_window.size() > 32) {
        g_window.erase(g_window.begin());
    }
}


// P6 checkpoint：通过 QEMU HMP monitor 触发 migrate（exec:gzip 落盘）。
// thread=single 下迁移期间主线程被占用，须轮询 monitor 等待
// "completed" 后再继续发 GO（固定 sleep 会踩超时）。只保留最近
// CKPT_KEEP 个 checkpoint，避免大文件堆积（每个 ~10-110MB）。
static void qemu_ckpt_save(const std::string &mon, const std::string &dir,
                           uint64_t seq) {
    const unsigned CKPT_KEEP = 3;
    static std::vector<uint64_t> saved;   // 已保存的 seq 列表（FIFO）
    std::string path = dir + "/ckpt-" + std::to_string(seq) + ".gz";

    auto mon_cmd = [&](const std::string &line, std::string *reply) {
        int fd = socket(AF_UNIX, SOCK_STREAM, 0);
        if (fd < 0) return false;
        struct sockaddr_un addr;
        memset(&addr, 0, sizeof(addr));
        addr.sun_family = AF_UNIX;
        if (mon.size() >= sizeof(addr.sun_path)) {
            close(fd);
            return false;
        }
        strncpy(addr.sun_path, mon.c_str(), sizeof(addr.sun_path) - 1);
        if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
            close(fd);
            return false;
        }
        std::string cmd = line + "\n";
        send(fd, cmd.data(), cmd.size(), 0);
        /* HMP 回显：阻塞读取（按命令一次性回显），最多 2s 防挂死 */
        std::string out;
        char buf[1024];
        for (;;) {
            fd_set rfds;
            FD_ZERO(&rfds);
            FD_SET(fd, &rfds);
            struct timeval tv = {2, 0};
            int rsel = select(fd + 1, &rfds, nullptr, nullptr, &tv);
            if (rsel <= 0) break;
            ssize_t n = recv(fd, buf, sizeof(buf), 0);
            if (n <= 0) break;
            out.append(buf, n);
            if (out.find("\n") != std::string::npos) break;
        }
        if (reply) *reply = out;
        close(fd);
        return true;
    };

    if (!mon_cmd("migrate \"exec:gzip -c > " + path + "\"", nullptr)) {
        fprintf(stderr, "ckpt: 触发 migrate 失败（seq=%llu）\n",
                (unsigned long long)seq);
        return;
    }
    /* 判完成：轮询目标文件，size 连续两次稳定即迁移落盘完成。
     *（HMP info migrate 回显在多连接/后台场景不可靠，弃用轮询。）*/
    bool done = false;
    off_t last_size = -1;
    int stable = 0;
    for (int i = 0; i < 90; i++) {
        sleep(2);
        struct stat st;
        if (stat(path.c_str(), &st) != 0) continue;
        done = (st.st_size > 0);
        if (done && st.st_size == last_size) {
            stable++;
            if (stable >= 2) break;   /* 连续两次同大小：文件已写完 */
        } else if (done) {
            stable = 1;
        }
        last_size = st.st_size;
    }
    if (!done) {
        fprintf(stderr, "ckpt: seq=%llu migrate 90s 未完成，继续（异常）\n",
                (unsigned long long)seq);
        return;
    }
    /* migrate（非 incoming）完成后源端 vm 停在 paused：主动 cont 恢复，
     * 否则 vCPU 不继续执行、插件不回 COMMIT（实测卡死）。 */
    mon_cmd("cont", nullptr);
    struct stat st;
    double mb = (stat(path.c_str(), &st) == 0)
                   ? (double)st.st_size / (1024.0 * 1024.0) : 0.0;
    fprintf(stderr, "ckpt: seq=%llu -> %s (%.1f MiB)\n",
            (unsigned long long)seq, path.c_str(), mb);
    saved.push_back(seq);
    if (saved.size() > CKPT_KEEP) {
        std::string old = dir + "/ckpt-" +
                          std::to_string(saved.front()) + ".gz";
        saved.erase(saved.begin());
        unlink(old.c_str());
        fprintf(stderr, "ckpt: 清理旧 checkpoint %s\n", old.c_str());
    }
}

/*
 * 差分 checkpoint（L2）：QEMU 通过 memory-backend-file 将 guest RAM 映射到
 * 一个显式文件；协调器在 QEMU 停止、且插件正等待 ACK 的窗口读取该文件，
 * 只把相对上一个快照变化的 4 KiB 页写入 gzip 链。CPU/设备状态由 QEMU
 * fork hook 保存，避免在协调器复制 QEMU 私有状态。
 *
 * 这一层不宣称已经恢复 DUT；它先保证 base/diff 文件链可验证、可限额，
 * 后续 L3 再加入 QEMU load + Verilator 注入口。
 */
static constexpr uint32_t DIFF_CKPT_PAGE = 4096;
static constexpr uint32_t DIFF_CKPT_VERSION = 1;
static constexpr size_t DIFF_CKPT_MAGIC_LEN = 8;
static const char DIFF_CKPT_MAGIC[DIFF_CKPT_MAGIC_LEN] = {
    'L', 'C', 'V', 'X', 'C', 'K', 'P', '1'};
static const char ARCH_CKPT_MAGIC[DIFF_CKPT_MAGIC_LEN] = {
    'L', 'C', 'V', 'X', 'A', 'R', 'C', '1'};
static const char TIMER_CKPT_MAGIC[DIFF_CKPT_MAGIC_LEN] = {
    'L', 'C', 'V', 'X', 'T', 'M', 'R', '1'};
static const char GIC_CKPT_MAGIC[DIFF_CKPT_MAGIC_LEN] = {
    'L', 'C', 'V', 'X', 'G', 'I', 'C', '1'};
static constexpr uint64_t DIFF_CKPT_MAX_BYTES = 512ull * 1024ull * 1024ull;

struct DiffCkptRecord {
    uint64_t seq = 0;
    uint64_t parent = std::numeric_limits<uint64_t>::max();
    bool base = false;
    uint64_t pages = 0;
    uint64_t ram_bytes = 0;
    std::string ram_path;
    std::string dev_path;
    std::string arch_path;
    std::string sys_path;
    std::string timer_path;
    std::string gic_path;
    std::string mmio_path;
    std::string fp_path;
};

/* 协议函数定义在 P1 trace 工具之后；差分 checkpoint 需要在 COMMIT/ACK
 * 窗口内先向 QEMU 插件发 CKPT_REQ，因此在此提前声明。 */
bool send_msg(int fd, uint16_t type, uint64_t seq, const void *payload,
              uint32_t plen);
int recv_msg(int fd, lcvex_msg_header *hdr, void *payload, size_t cap);

static void put_le32(unsigned char *p, uint32_t v) {
    p[0] = (unsigned char)(v & 0xff);
    p[1] = (unsigned char)((v >> 8) & 0xff);
    p[2] = (unsigned char)((v >> 16) & 0xff);
    p[3] = (unsigned char)((v >> 24) & 0xff);
}

static void put_le64(unsigned char *p, uint64_t v) {
    for (unsigned i = 0; i < 8; i++) {
        p[i] = (unsigned char)((v >> (8 * i)) & 0xff);
    }
}

static bool read_file_bytes(const std::string &path, std::vector<uint8_t> *out) {
    std::ifstream f(path, std::ios::binary | std::ios::ate);
    if (!f) {
        fprintf(stderr, "diff-ckpt: 无法打开 RAM 文件 %s: %s\n",
                path.c_str(), strerror(errno));
        return false;
    }
    std::streamoff n = f.tellg();
    if (n <= 0 || (uint64_t)n > (1ull << 32)) {
        fprintf(stderr, "diff-ckpt: RAM 文件大小无效: %s (%lld)\n",
                path.c_str(), (long long)n);
        return false;
    }
    f.seekg(0, std::ios::beg);
    out->resize((size_t)n);
    if (!f.read(reinterpret_cast<char *>(out->data()), n)) {
        fprintf(stderr, "diff-ckpt: 读取 RAM 文件失败: %s\n", path.c_str());
        return false;
    }
    return true;
}

static bool write_diff_ram(const std::string &path,
                           const std::vector<uint8_t> &cur,
                           const std::vector<uint8_t> *prev,
                           uint64_t seq, uint64_t parent, bool base,
                           uint64_t *pages_out) {
    gzFile gz = gzopen(path.c_str(), "wb9");
    if (!gz) {
        fprintf(stderr, "diff-ckpt: 无法创建 %s\n", path.c_str());
        return false;
    }
    unsigned char hdr[56] = {};
    memcpy(hdr, DIFF_CKPT_MAGIC, DIFF_CKPT_MAGIC_LEN);
    put_le32(hdr + 8, DIFF_CKPT_VERSION);
    put_le32(hdr + 12, DIFF_CKPT_PAGE);
    put_le64(hdr + 16, seq);
    put_le64(hdr + 24, parent);
    put_le64(hdr + 32, (uint64_t)cur.size());
    /* pages count is filled after a first pass; base/diff readers reject zero
     * only when ram_bytes is non-zero, so this remains stream-friendly. */
    uint64_t pages = 0;
    if (gzwrite(gz, hdr, sizeof(hdr)) != (int)sizeof(hdr)) {
        gzclose(gz);
        return false;
    }

    const size_t total_pages = (cur.size() + DIFF_CKPT_PAGE - 1) /
                               DIFF_CKPT_PAGE;
    std::array<uint8_t, DIFF_CKPT_PAGE> zero_page{};
    for (size_t page = 0; page < total_pages; page++) {
        size_t off = page * DIFF_CKPT_PAGE;
        size_t len = std::min<size_t>(DIFF_CKPT_PAGE, cur.size() - off);
        bool changed = base || prev == nullptr ||
                       memcmp(cur.data() + off, prev->data() + off, len) != 0;
        if (!changed) {
            continue;
        }
        unsigned char page_no[8];
        put_le64(page_no, page);
        if (gzwrite(gz, page_no, sizeof(page_no)) != (int)sizeof(page_no) ||
            gzwrite(gz, cur.data() + off, (unsigned)len) != (int)len) {
            gzclose(gz);
            return false;
        }
        if (len < DIFF_CKPT_PAGE &&
            gzwrite(gz, zero_page.data(), DIFF_CKPT_PAGE - len) !=
                (int)(DIFF_CKPT_PAGE - len)) {
            gzclose(gz);
            return false;
        }
        pages++;
    }
    /* Header is deliberately fixed-size and currently records pages=0. The
     * manifest is authoritative for the count; keeping the stream append-only
     * makes it safe to publish through rename after gzclose. */
    if (gzclose(gz) != Z_OK) {
        return false;
    }
    if (pages_out) {
        *pages_out = pages;
    }
    return true;
}

static bool write_arch_state(const std::string &path, uint64_t seq,
                             const lcvex_state &state) {
    gzFile gz = gzopen(path.c_str(), "wb9");
    if (!gz) {
        return false;
    }
    unsigned char hdr[24] = {};
    memcpy(hdr, ARCH_CKPT_MAGIC, DIFF_CKPT_MAGIC_LEN);
    put_le32(hdr + 8, DIFF_CKPT_VERSION);
    put_le64(hdr + 16, seq);
    int hrc = gzwrite(gz, hdr, sizeof(hdr));
    int src = gzwrite(gz, &state, sizeof(state));
    int crc = gzclose(gz);
    return hrc == (int)sizeof(hdr) && src == (int)sizeof(state) &&
           crc == Z_OK;
}

static uint32_t get_le32(const unsigned char *p) {
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) |
           ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

static uint64_t get_le64(const unsigned char *p) {
    uint64_t v = 0;
    for (unsigned i = 0; i < 8; i++) {
        v |= (uint64_t)p[i] << (8 * i);
    }
    return v;
}

static bool read_arch_state_file(const std::string &path, uint64_t *seq,
                                 lcvex_state *state) {
    gzFile gz = gzopen(path.c_str(), "rb");
    if (!gz) {
        return false;
    }
    unsigned char hdr[24] = {};
    bool ok = gzread(gz, hdr, sizeof(hdr)) == (int)sizeof(hdr) &&
              memcmp(hdr, ARCH_CKPT_MAGIC, DIFF_CKPT_MAGIC_LEN) == 0 &&
              get_le32(hdr + 8) == DIFF_CKPT_VERSION;
    if (ok) {
        *seq = get_le64(hdr + 16);
        ok = gzread(gz, state, sizeof(*state)) == (int)sizeof(*state);
    }
    int tail = gzclose(gz);
    return ok && tail == Z_OK;
}

static bool read_sys_state_file(const std::string &path, DutSysState *state) {
    gzFile gz = gzopen(path.c_str(), "rb");
    if (!gz) {
        return false;
    }
    DutSysState tmp = {};
    // v1/v2 没有 exclusive 字段，不能把零填充误解释为地址 0 上的有效
    // monitor；旧链一律恢复为无 monitor。v3 会用实际 sidecar 覆盖它。
    tmp.exclusive_addr = std::numeric_limits<uint64_t>::max();
    uint8_t raw[sizeof(DutSysState) + 8] = {};
    size_t got = (size_t)gzread(gz, raw, sizeof(raw));
    int tail = gzclose(gz);
    bool ok = tail == Z_OK;
    if (ok && got >= 476 && memcmp(raw, "LCVXSYS1", 8) == 0 &&
        get_le32(raw + 8) == 1 && get_le32(raw + 12) == 476) {
        /* v1：旧布局与新布局前缀一致，尾部三个 v2 字段保持 0。 */
        memcpy(&tmp, raw, 476);
    } else if (ok && got >= 500 && memcmp(raw, "LCVXSYS2", 8) == 0 &&
               get_le32(raw + 8) == 2 &&
               get_le32(raw + 12) == 500) {
        memcpy(&tmp, raw, 500);
    } else if (ok && got >= 540 && memcmp(raw, "LCVXSYS3", 8) == 0 &&
               get_le32(raw + 8) == 3 && get_le32(raw + 12) == 540) {
        memcpy(&tmp, raw, 540);
    } else if (ok && got >= sizeof(DutSysState) &&
               memcmp(raw, "LCVXSYS4", 8) == 0 &&
               get_le32(raw + 8) == 4 &&
               get_le32(raw + 12) == sizeof(DutSysState)) {
        memcpy(&tmp, raw, sizeof(DutSysState));
    } else {
        ok = false;
    }
    if (ok) {
        *state = tmp;
    }
    return ok;
}

static bool read_timer_state_file(const std::string &path,
                                  DutTimerState *state) {
    gzFile gz = gzopen(path.c_str(), "rb");
    if (!gz) {
        return false;
    }
    bool ok = gzread(gz, state, sizeof(*state)) == (int)sizeof(*state) &&
              memcmp(state->magic, TIMER_CKPT_MAGIC,
                     sizeof(state->magic)) == 0 &&
              state->version == 1 && state->size == sizeof(*state) &&
              state->cntfrq == 1000000000ull &&
              state->cntvoff_el2 == 0 && state->cntpoff_el2 == 0;
    int tail = gzclose(gz);
    return ok && tail == Z_OK;
}

static bool read_gic_state_file(const std::string &path, DutGicState *state) {
    gzFile gz = gzopen(path.c_str(), "rb");
    if (!gz) {
        return false;
    }
    bool ok = gzread(gz, state, sizeof(*state)) == (int)sizeof(*state) &&
              memcmp(state->magic, GIC_CKPT_MAGIC,
                     sizeof(state->magic)) == 0 &&
              state->version == 1 && state->size == sizeof(*state) &&
              state->num_irq >= 96;
    int tail = gzclose(gz);
    return ok && tail == Z_OK;
}

static bool read_mmio_state_file(const std::string &path,
                                 LcvexMmioFabricState *state) {
    gzFile gz = gzopen(path.c_str(), "rb");
    if (!gz) {
        return false;
    }
    LcvexMmioFabricState tmp = {};
    bool ok = gzread(gz, &tmp, sizeof(tmp)) == (int)sizeof(tmp) &&
              memcmp(tmp.magic, "LCVXMMIO", sizeof(tmp.magic)) == 0 &&
              tmp.version == 1 && tmp.size == sizeof(tmp);
    int tail = gzclose(gz);
    if (ok && tail == Z_OK) {
        *state = tmp;
        return true;
    }
    return false;
}

static bool read_fp_state_file(const std::string &path, uint64_t expected_seq,
                               FpState *state) {
    std::array<uint8_t, LCVEX_FP_FILE_BYTES> raw{};
    gzFile gz = gzopen(path.c_str(), "rb");
    if (!gz) {
        return false;
    }
    bool ok = gzread(gz, raw.data(), static_cast<unsigned>(raw.size())) ==
                  static_cast<int>(raw.size()) &&
              gzgetc(gz) == -1;
    int tail = gzclose(gz);
    if (!ok || tail != Z_OK || memcmp(raw.data(), "LCVXFP01", 8) != 0 ||
        get_le32(raw.data() + 8) != 1 ||
        get_le32(raw.data() + 12) != LCVEX_FP_FILE_BYTES ||
        get_le32(raw.data() + 16) != LCVEX_FP_FEATURE_NEON ||
        get_le32(raw.data() + 20) != LCVEX_FP_VECTOR_BYTES ||
        (expected_seq != std::numeric_limits<uint64_t>::max() &&
         get_le64(raw.data() + 24) != expected_seq)) {
        return false;
    }
    state->fpcr = get_le32(raw.data() + 32);
    state->fpsr = get_le32(raw.data() + 36);
    for (unsigned i = 0; i < 32; i++) {
        const size_t offset = 40 + i * 16;
        state->v[i].lo = get_le64(raw.data() + offset);
        state->v[i].hi = get_le64(raw.data() + offset + 8);
    }
    return true;
}

static bool recv_line_fd(int fd, std::string *line) {
    line->clear();
    char c;
    while (line->size() < 1024 * 1024) {
        ssize_t n = recv(fd, &c, 1, 0);
        if (n <= 0) {
            return false;
        }
        line->push_back(c);
        if (c == '\n') {
            return true;
        }
    }
    return false;
}

static std::string replace_suffix(const std::string &value,
                                  const std::string &suffix,
                                  const std::string &replacement) {
    if (value.size() < suffix.size() ||
        value.compare(value.size() - suffix.size(), suffix.size(), suffix) != 0) {
        return {};
    }
    return value.substr(0, value.size() - suffix.size()) + replacement;
}

static bool gzip_file(const std::string &source, const std::string &target) {
    std::ifstream input(source, std::ios::binary);
    gzFile output = gzopen(target.c_str(), "wb9");
    std::array<char, 1 << 16> buffer{};
    bool ok = input.good() && output != nullptr;

    while (ok && input) {
        input.read(buffer.data(), buffer.size());
        std::streamsize got = input.gcount();
        if (got > 0 && gzwrite(output, buffer.data(), static_cast<unsigned>(got)) !=
                              static_cast<int>(got)) {
            ok = false;
        }
    }
    if (output != nullptr && gzclose(output) != Z_OK) {
        ok = false;
    }
    if (!ok) {
        unlink(target.c_str());
    }
    return ok;
}

static bool atomic_append_manifest(const std::string &path,
                                   const std::string &line) {
    std::string templated = path + ".tmp.XXXXXX";
    std::vector<char> name(templated.begin(), templated.end());
    name.push_back('\0');
    int fd = mkstemp(name.data());
    if (fd < 0) {
        return false;
    }
    FILE *stream = fdopen(fd, "w");
    if (stream == nullptr) {
        close(fd);
    }
    bool ok = stream != nullptr;
    if (ok) {
        std::ifstream old(path, std::ios::binary);
        if (old) {
            std::array<char, 1 << 16> buffer{};
            while (old) {
                old.read(buffer.data(), buffer.size());
                std::streamsize got = old.gcount();
                if (got > 0 && fwrite(buffer.data(), 1, static_cast<size_t>(got),
                                      stream) != static_cast<size_t>(got)) {
                    ok = false;
                    break;
                }
            }
        }
    }
    if (ok) {
        ok = fwrite(line.data(), 1, line.size(), stream) == line.size() &&
             fflush(stream) == 0 && fsync(fd) == 0;
    }
    if (stream != nullptr && fclose(stream) != 0) {
        ok = false;
    }
    if (ok && rename(name.data(), path.c_str()) == 0) {
        return true;
    }
    unlink(name.data());
    return false;
}

static bool qemu_diff_ckpt_save(int protocol_fd,
                                const std::string &ram_file,
                                const std::string &dir,
                                uint64_t seq, const lcvex_state &state) {
    static std::vector<uint8_t> previous_ram;
    static uint64_t previous_seq = std::numeric_limits<uint64_t>::max();
    static std::vector<DiffCkptRecord> saved;
    std::vector<uint8_t> current_ram;
    std::string base = dir + "/base-" + std::to_string(seq);
    bool first = previous_ram.empty();
    std::string ram_final = (first ? base :
                             dir + "/diff-" + std::to_string(seq)) + ".ram.gz";
    std::string dev_raw = (first ? base :
                           dir + "/diff-" + std::to_string(seq)) + ".dev";
    std::string dev_final = dev_raw + ".gz";
    std::string sys_raw = dev_raw + ".sys";
    std::string sys_final = sys_raw + ".gz";
    std::string timer_raw = dev_raw + ".timer";
    std::string timer_final = timer_raw + ".gz";
    std::string gic_raw = dev_raw + ".gic";
    std::string gic_final = gic_raw + ".gz";
    std::string mmio_final = dev_raw + ".mmio.gz";
    std::string arch_final = (first ? base :
                              dir + "/diff-" + std::to_string(seq)) + ".arch.gz";
    std::string ram_tmp = ram_final + ".tmp";
    std::string dev_tmp = dev_raw + ".tmp";

    struct lcvex_ckpt_req req = {};
    snprintf(req.dev_path, sizeof(req.dev_path), "%s", dev_tmp.c_str());
    snprintf(req.sys_path, sizeof(req.sys_path), "%s", sys_raw.c_str());
    snprintf(req.timer_path, sizeof(req.timer_path), "%s", timer_raw.c_str());
    snprintf(req.gic_path, sizeof(req.gic_path), "%s", gic_raw.c_str());
    if (!send_msg(protocol_fd, LCVEX_MSG_CKPT_REQ, seq, &req, sizeof(req))) {
        fprintf(stderr, "diff-ckpt: 无法发送 CKPT_REQ\n");
        return false;
    }
    struct lcvex_msg_header ready_hdr = {};
    struct lcvex_ckpt_ready ready = {};
    int rr = recv_msg(protocol_fd, &ready_hdr, &ready, sizeof(ready));
    if (rr != 1 || ready_hdr.type != LCVEX_MSG_CKPT_READY ||
        ready_hdr.seq != seq || ready.status < 0) {
        fprintf(stderr, "diff-ckpt: QEMU CKPT_READY 失败（seq=%llu）：%s\n",
                (unsigned long long)seq, ready.detail);
        return false;
    }
    if (!read_file_bytes(ram_file, &current_ram)) {
        return false;
    }
    if (!first && current_ram.size() != previous_ram.size()) {
        fprintf(stderr, "diff-ckpt: RAM 大小改变（%zu -> %zu）\n",
                previous_ram.size(), current_ram.size());
        return false;
    }
    uint64_t pages = 0;
    if (!write_diff_ram(ram_tmp, current_ram,
                        first ? nullptr : &previous_ram, seq,
                        first ? std::numeric_limits<uint64_t>::max()
                              : previous_seq,
                        first, &pages)) {
        unlink(dev_tmp.c_str());
        unlink(ram_tmp.c_str());
        return false;
    }
    if (rename(ram_tmp.c_str(), ram_final.c_str()) != 0 ||
        rename(dev_tmp.c_str(), dev_raw.c_str()) != 0) {
        fprintf(stderr, "diff-ckpt: 发布临时文件失败: %s\n", strerror(errno));
        unlink(ram_tmp.c_str());
        unlink(dev_tmp.c_str());
        return false;
    }
    /* Device state is small; gzip it separately and remove the raw file. */
    std::vector<uint8_t> dev;
    if (!read_file_bytes(dev_raw, &dev)) {
        return false;
    }
    gzFile dgz = gzopen((dev_final + ".tmp").c_str(), "wb9");
    bool dev_ok = dgz &&
                  gzwrite(dgz, dev.data(), (unsigned)dev.size()) ==
                      (int)dev.size() &&
                  gzclose(dgz) == Z_OK;
    unlink(dev_raw.c_str());
    if (!dev_ok || rename((dev_final + ".tmp").c_str(), dev_final.c_str()) != 0) {
        fprintf(stderr, "diff-ckpt: 压缩设备状态失败\n");
        return false;
    }
    if (!write_arch_state(arch_final + ".tmp", seq, state) ||
        rename((arch_final + ".tmp").c_str(), arch_final.c_str()) != 0) {
        fprintf(stderr, "diff-ckpt: 压缩架构摘要失败\n");
        unlink(ram_final.c_str());
        unlink(dev_final.c_str());
        unlink((arch_final + ".tmp").c_str());
        return false;
    }
    std::vector<uint8_t> sys;
    if (!read_file_bytes(sys_raw, &sys)) {
        unlink(ram_final.c_str());
        unlink(dev_final.c_str());
        unlink(arch_final.c_str());
        return false;
    }
    gzFile sgz = gzopen((sys_final + ".tmp").c_str(), "wb9");
    bool sys_ok = sgz &&
                  gzwrite(sgz, sys.data(), (unsigned)sys.size()) ==
                      (int)sys.size() &&
                  gzclose(sgz) == Z_OK;
    unlink(sys_raw.c_str());
    if (!sys_ok || rename((sys_final + ".tmp").c_str(), sys_final.c_str()) != 0) {
        fprintf(stderr, "diff-ckpt: 压缩系统状态失败\n");
        unlink(ram_final.c_str());
        unlink(dev_final.c_str());
        unlink(arch_final.c_str());
        unlink((sys_final + ".tmp").c_str());
        return false;
    }
    std::vector<uint8_t> timer;
    if (!read_file_bytes(timer_raw, &timer)) {
        unlink(ram_final.c_str());
        unlink(dev_final.c_str());
        unlink(arch_final.c_str());
        unlink(sys_final.c_str());
        return false;
    }
    gzFile tgz = gzopen((timer_final + ".tmp").c_str(), "wb9");
    bool timer_ok = tgz &&
                    gzwrite(tgz, timer.data(), (unsigned)timer.size()) ==
                        (int)timer.size() &&
                    gzclose(tgz) == Z_OK;
    unlink(timer_raw.c_str());
    if (!timer_ok || rename((timer_final + ".tmp").c_str(),
                            timer_final.c_str()) != 0) {
        fprintf(stderr, "diff-ckpt: 压缩定时器状态失败\n");
        unlink(ram_final.c_str());
        unlink(dev_final.c_str());
        unlink(arch_final.c_str());
        unlink(sys_final.c_str());
        unlink((timer_final + ".tmp").c_str());
        return false;
    }
    std::vector<uint8_t> gic;
    if (!read_file_bytes(gic_raw, &gic)) {
        unlink(ram_final.c_str());
        unlink(dev_final.c_str());
        unlink(arch_final.c_str());
        unlink(sys_final.c_str());
        unlink(timer_final.c_str());
        return false;
    }
    gzFile ggz = gzopen((gic_final + ".tmp").c_str(), "wb9");
    bool gic_ok = ggz &&
                  gzwrite(ggz, gic.data(), (unsigned)gic.size()) ==
                      (int)gic.size() &&
                  gzclose(ggz) == Z_OK;
    unlink(gic_raw.c_str());
    if (!gic_ok || rename((gic_final + ".tmp").c_str(), gic_final.c_str()) != 0) {
        fprintf(stderr, "diff-ckpt: 压缩 GIC 状态失败\n");
        unlink(ram_final.c_str());
        unlink(dev_final.c_str());
        unlink(arch_final.c_str());
        unlink(sys_final.c_str());
        unlink(timer_final.c_str());
        unlink((gic_final + ".tmp").c_str());
        return false;
    }
    // C++ fabric 属于 DUT 状态，不在 QEMU VMState 中；独立压缩为很小的
    // sidecar，使从 checkpoint 恢复后的 PL031/future C devices 不会回到 reset。
    LcvexMmioFabricState mmio = {};
    gzFile mgz = gzopen((mmio_final + ".tmp").c_str(), "wb9");
    bool mmio_ok = lcvex_mmio_fabric_save(&mmio) && mgz;
    if (mmio_ok) {
        mmio_ok = gzwrite(mgz, &mmio, sizeof(mmio)) == (int)sizeof(mmio);
    }
    if (mgz) {
        mmio_ok = (gzclose(mgz) == Z_OK) && mmio_ok;
    }
    if (!mmio_ok || rename((mmio_final + ".tmp").c_str(), mmio_final.c_str()) != 0) {
        fprintf(stderr, "diff-ckpt: 压缩 C++ MMIO 状态失败\n");
        unlink(ram_final.c_str());
        unlink(dev_final.c_str());
        unlink(arch_final.c_str());
        unlink(sys_final.c_str());
        unlink(timer_final.c_str());
        unlink(gic_final.c_str());
        unlink((mmio_final + ".tmp").c_str());
        return false;
    }
    uint64_t total_bytes = 0;
    for (const auto &old : saved) {
        struct stat st;
        if (!old.ram_path.empty() && stat(old.ram_path.c_str(), &st) == 0) {
            total_bytes += (uint64_t)st.st_size;
        }
        if (!old.dev_path.empty() && stat(old.dev_path.c_str(), &st) == 0) {
            total_bytes += (uint64_t)st.st_size;
        }
        if (!old.arch_path.empty() && stat(old.arch_path.c_str(), &st) == 0) {
            total_bytes += (uint64_t)st.st_size;
        }
        if (!old.sys_path.empty() && stat(old.sys_path.c_str(), &st) == 0) {
            total_bytes += (uint64_t)st.st_size;
        }
        if (!old.timer_path.empty() && stat(old.timer_path.c_str(), &st) == 0) {
            total_bytes += (uint64_t)st.st_size;
        }
        if (!old.gic_path.empty() && stat(old.gic_path.c_str(), &st) == 0) {
            total_bytes += (uint64_t)st.st_size;
        }
        if (!old.mmio_path.empty() && stat(old.mmio_path.c_str(), &st) == 0) {
            total_bytes += (uint64_t)st.st_size;
        }
    }
    {
        struct stat st;
        if (stat(ram_final.c_str(), &st) == 0) {
            total_bytes += (uint64_t)st.st_size;
        }
        if (stat(dev_final.c_str(), &st) == 0) {
            total_bytes += (uint64_t)st.st_size;
        }
        if (stat(arch_final.c_str(), &st) == 0) {
            total_bytes += (uint64_t)st.st_size;
        }
        if (stat(sys_final.c_str(), &st) == 0) {
            total_bytes += (uint64_t)st.st_size;
        }
        if (stat(timer_final.c_str(), &st) == 0) {
            total_bytes += (uint64_t)st.st_size;
        }
        if (stat(gic_final.c_str(), &st) == 0) {
            total_bytes += (uint64_t)st.st_size;
        }
        if (stat(mmio_final.c_str(), &st) == 0) {
            total_bytes += (uint64_t)st.st_size;
        }
    }
    if (total_bytes > DIFF_CKPT_MAX_BYTES) {
        fprintf(stderr, "diff-ckpt: 链大小超过上限（%llu > %llu bytes）\n",
                (unsigned long long)total_bytes,
                (unsigned long long)DIFF_CKPT_MAX_BYTES);
        unlink(ram_final.c_str());
        unlink(dev_final.c_str());
        unlink(arch_final.c_str());
        unlink(sys_final.c_str());
        unlink(timer_final.c_str());
        unlink(gic_final.c_str());
        unlink(mmio_final.c_str());
        return false;
    }
    std::ofstream mf(dir + "/manifest.tsv", std::ios::app);
    mf << (first ? "base" : "diff") << '\t' << seq << '\t'
       << (first ? std::numeric_limits<uint64_t>::max() : previous_seq)
       << '\t' << current_ram.size() << '\t' << pages << '\t'
       << ram_final << '\t' << dev_final << '\t' << arch_final << '\t'
       << sys_final << '\t' << timer_final << '\t' << gic_final << '\t'
       << mmio_final << '\n';
    mf.close();
    saved.push_back({seq, first ? std::numeric_limits<uint64_t>::max()
                                : previous_seq,
                     first, pages, current_ram.size(), ram_final, dev_final,
                     arch_final, sys_final, timer_final, gic_final, mmio_final});
    previous_ram.swap(current_ram);
    previous_seq = seq;
    /* 不能只删除最旧 diff：后续记录仍引用它的 parent。链压缩/新 base
     * 尚未实现前宁可由总大小上限拒绝，也不发布断链 manifest。 */
    fprintf(stderr, "diff-ckpt: %s seq=%llu pages=%llu ram=%zu bytes\n",
            first ? "base" : "diff", (unsigned long long)seq,
            (unsigned long long)pages, previous_ram.size());
    return true;
}

static bool validate_fp_raw_file(const std::string &path, uint64_t seq) {
    std::vector<uint8_t> raw;
    if (!read_file_bytes(path, &raw) || raw.size() != LCVEX_FP_FILE_BYTES) {
        return false;
    }
    return memcmp(raw.data(), "LCVXFP01", 8) == 0 &&
           get_le32(raw.data() + 8) == 1 &&
           get_le32(raw.data() + 12) == LCVEX_FP_FILE_BYTES &&
           get_le32(raw.data() + 16) == LCVEX_FP_FEATURE_NEON &&
           get_le32(raw.data() + 20) == LCVEX_FP_VECTOR_BYTES &&
           get_le64(raw.data() + 24) == seq;
}

/* P7 checkpoint transaction.  The legacy function above deliberately stays
 * byte-compatible for P6 7..12-column chains; P7 uses this path so every
 * raw/tmp/final artifact and the 13-column TSV row publish as one transaction. */
static bool qemu_diff_ckpt_save_p7(int protocol_fd,
                                   const std::string &ram_file,
                                   const std::string &dir,
                                   uint64_t seq, const lcvex_state &state) {
    static std::vector<uint8_t> previous_ram;
    static uint64_t previous_seq = std::numeric_limits<uint64_t>::max();
    static std::vector<DiffCkptRecord> saved;
    const bool first = previous_ram.empty();
    const std::string prefix = first ? dir + "/base-" + std::to_string(seq)
                                     : dir + "/diff-" + std::to_string(seq);
    const std::string ram_final = prefix + ".ram.gz";
    const std::string ram_tmp = ram_final + ".tmp";
    const std::string dev_raw = prefix + ".dev.tmp";
    const std::string dev_final = prefix + ".dev.gz";
    const std::string dev_tmp = dev_final + ".tmp";
    const std::string sys_raw = prefix + ".dev.sys";
    const std::string sys_final = sys_raw + ".gz";
    const std::string sys_tmp = sys_final + ".tmp";
    const std::string timer_raw = prefix + ".dev.timer";
    const std::string timer_final = timer_raw + ".gz";
    const std::string timer_tmp = timer_final + ".tmp";
    const std::string gic_raw = prefix + ".dev.gic";
    const std::string gic_final = gic_raw + ".gz";
    const std::string gic_tmp = gic_final + ".tmp";
    const std::string fp_raw = replace_suffix(sys_raw, ".sys", ".fp");
    const std::string fp_final = fp_raw + ".gz";
    const std::string fp_tmp = fp_final + ".tmp";
    const std::string mmio_final = prefix + ".dev.mmio.gz";
    const std::string mmio_tmp = mmio_final + ".tmp";
    const std::string arch_final = prefix + ".arch.gz";
    const std::string arch_tmp = arch_final + ".tmp";
    const std::vector<std::string> paths = {
        ram_final, ram_tmp, dev_raw, dev_final, dev_tmp, sys_raw, sys_final,
        sys_tmp, timer_raw, timer_final, timer_tmp, gic_raw, gic_final,
        gic_tmp, fp_raw, fp_final, fp_tmp, mmio_final, mmio_tmp, arch_final,
        arch_tmp,
    };
    auto cleanup = [&]() {
        for (const auto &path : paths) unlink(path.c_str());
    };
    auto target_is_free = [&]() {
        for (const auto &path : paths) {
            if (access(path.c_str(), F_OK) == 0) return false;
        }
        return true;
    };
    auto publish = [&](const std::string &from, const std::string &to) {
        return rename(from.c_str(), to.c_str()) == 0;
    };

    if (fp_raw.empty() || !target_is_free()) {
        fprintf(stderr, "diff-ckpt: P7 checkpoint 目标已存在或路径非法\n");
        return false;
    }
    lcvex_ckpt_req req = {};
    if (snprintf(req.dev_path, sizeof(req.dev_path), "%s", dev_raw.c_str()) >=
            static_cast<int>(sizeof(req.dev_path)) ||
        snprintf(req.sys_path, sizeof(req.sys_path), "%s", sys_raw.c_str()) >=
            static_cast<int>(sizeof(req.sys_path)) ||
        snprintf(req.timer_path, sizeof(req.timer_path), "%s", timer_raw.c_str()) >=
            static_cast<int>(sizeof(req.timer_path)) ||
        snprintf(req.gic_path, sizeof(req.gic_path), "%s", gic_raw.c_str()) >=
            static_cast<int>(sizeof(req.gic_path))) {
        return false;
    }
    if (!send_msg(protocol_fd, LCVEX_MSG_CKPT_REQ, seq, &req, sizeof(req))) {
        cleanup();
        return false;
    }
    lcvex_msg_header ready_hdr = {};
    lcvex_ckpt_ready ready = {};
    int rr = recv_msg(protocol_fd, &ready_hdr, &ready, sizeof(ready));
    if (rr != 1 || ready_hdr.type != LCVEX_MSG_CKPT_READY ||
        ready_hdr.seq != seq || ready.status < 0) {
        fprintf(stderr, "diff-ckpt: P7 CKPT_READY 失败（seq=%llu）：%s\n",
                static_cast<unsigned long long>(seq), ready.detail);
        cleanup();
        return false;
    }
    std::vector<uint8_t> current_ram;
    uint64_t pages = 0;
    if (!read_file_bytes(ram_file, &current_ram) ||
        (!first && current_ram.size() != previous_ram.size()) ||
        !validate_fp_raw_file(fp_raw, seq) ||
        !write_diff_ram(ram_tmp, current_ram, first ? nullptr : &previous_ram,
                        seq, first ? std::numeric_limits<uint64_t>::max()
                                   : previous_seq,
                        first, &pages) ||
        !write_arch_state(arch_tmp, seq, state) ||
        !gzip_file(dev_raw, dev_tmp) || !gzip_file(sys_raw, sys_tmp) ||
        !gzip_file(timer_raw, timer_tmp) || !gzip_file(gic_raw, gic_tmp) ||
        !gzip_file(fp_raw, fp_tmp)) {
        cleanup();
        return false;
    }

    LcvexMmioFabricState mmio = {};
    gzFile mgz = gzopen(mmio_tmp.c_str(), "wb9");
    bool mmio_ok = lcvex_mmio_fabric_save(&mmio) && mgz != nullptr;
    if (mmio_ok) {
        mmio_ok = gzwrite(mgz, &mmio, sizeof(mmio)) == static_cast<int>(sizeof(mmio));
    }
    if (mgz != nullptr) mmio_ok = gzclose(mgz) == Z_OK && mmio_ok;
    if (!mmio_ok ||
        !publish(ram_tmp, ram_final) || !publish(dev_tmp, dev_final) ||
        !publish(sys_tmp, sys_final) || !publish(timer_tmp, timer_final) ||
        !publish(gic_tmp, gic_final) || !publish(fp_tmp, fp_final) ||
        !publish(mmio_tmp, mmio_final) || !publish(arch_tmp, arch_final)) {
        cleanup();
        return false;
    }
    unlink(dev_raw.c_str());
    unlink(sys_raw.c_str());
    unlink(timer_raw.c_str());
    unlink(gic_raw.c_str());
    unlink(fp_raw.c_str());

    uint64_t total_bytes = 0;
    auto add_size = [&](const std::string &path) {
        struct stat st = {};
        if (stat(path.c_str(), &st) == 0) total_bytes += st.st_size;
    };
    for (const auto &old : saved) {
        add_size(old.ram_path); add_size(old.dev_path); add_size(old.arch_path);
        add_size(old.sys_path); add_size(old.timer_path); add_size(old.gic_path);
        add_size(old.mmio_path); add_size(old.fp_path);
    }
    add_size(ram_final); add_size(dev_final); add_size(arch_final);
    add_size(sys_final); add_size(timer_final); add_size(gic_final);
    add_size(mmio_final); add_size(fp_final);
    if (total_bytes > DIFF_CKPT_MAX_BYTES) {
        cleanup();
        return false;
    }

    std::string line = (first ? "base" : "diff") + std::string("\t") +
        std::to_string(seq) + "\t" +
        std::to_string(first ? std::numeric_limits<uint64_t>::max() : previous_seq) +
        "\t" + std::to_string(current_ram.size()) + "\t" +
        std::to_string(pages) + "\t" + ram_final +
        "\t" + dev_final + "\t" + arch_final + "\t" + sys_final +
        "\t" + timer_final + "\t" + gic_final + "\t" + mmio_final +
        "\t" + fp_final + "\n";
    if (!atomic_append_manifest(dir + "/manifest.tsv", line)) {
        cleanup();
        return false;
    }
    saved.push_back({seq, first ? std::numeric_limits<uint64_t>::max()
                                : previous_seq,
                     first, pages, current_ram.size(), ram_final, dev_final,
                     arch_final, sys_final, timer_final, gic_final, mmio_final,
                     fp_final});
    previous_ram.swap(current_ram);
    previous_seq = seq;
    fprintf(stderr, "diff-ckpt: P7 %s seq=%llu ram=%zu bytes fp=%s\n",
            first ? "base" : "diff", static_cast<unsigned long long>(seq),
            previous_ram.size(), fp_final.c_str());
    return true;
}

class VerilatorDut {
  public:
    VerilatorDut() : top_(new Vlcvex_soc_tb) {}
    ~VerilatorDut() {
        top_->final();
        delete top_;
    }

    // P6 内核锁步调试：DUT 核心内部状态（decode/mmu）
    bool dbg_mmu_en() const { return top_->dbg_mmu_en; }
    bool dbg_el() const {
        return top_->rootp->lcvex_soc_tb__DOT__core__DOT__el;
    }
    uint64_t dbg_vbar_el1() const { return top_->dbg_vbar_el1; }
    bool dbg_dec_valid() const { return top_->dbg_dec_valid; }
    bool dbg_dec_exc() const { return top_->dbg_dec_exc; }
    uint32_t dbg_dec_insn() const { return top_->dbg_dec_insn; }
    uint64_t dbg_dec_pc() const { return top_->dbg_dec_pc; }
    uint32_t dbg_dec_exc_code() const { return top_->dbg_dec_exc_code; }

    FpState read_fp_state() const {
        FpState state = {};
        state.fpcr = top_->fpcr_state;
        state.fpsr = top_->fpsr_state;
        for (unsigned i = 0; i < state.v.size(); i++) {
            state.v[i].lo = top_->fp_v_lo[i];
            state.v[i].hi = top_->fp_v_hi[i];
        }
        return state;
    }

    void stage_wait_resume(bool cntvct_valid, uint64_t cntvct) {
        // 专用 SoC→core sideband，替代直接写 RTL 内部层级。tick() 在首个
        // 完整时钟后自动撤销该脉冲；core 负责把它锁存到 WFx 真正可见的
        // wake 边界并更新非架构计时基准。
        top_->difftest_wait_release = 1;
        top_->difftest_wait_cntvct_valid = cntvct_valid ? 1 : 0;
        top_->difftest_wait_cntvct = cntvct;
    }

    /* 将“PRE 已收到但 DUT 未提交”的流水线现场写入失败诊断。这里直接
     * 读取 public-flat-rw 暴露的组合/寄存器信号，不调用任何 tick，避免
     * 诊断本身改变锁步时序。 */
    void dump_pipeline_debug(FILE *f) const {
        const auto *r = top_->rootp;
        fprintf(f,
                "DUT pipeline ifid(v=%d pc=0x%llx insn=0x%08x) "
                "idex(v=%d insn=0x%08x) exmem(v=%d insn=0x%08x) "
                "memwb(v=%d insn=0x%08x) commit=%d\n",
                (int)r->lcvex_soc_tb__DOT__core__DOT__ifid_valid,
                (unsigned long long)r->lcvex_soc_tb__DOT__core__DOT__ifid_pc,
                (unsigned)r->lcvex_soc_tb__DOT__core__DOT__ifid_insn,
                (int)r->lcvex_soc_tb__DOT__core__DOT__idex_valid,
                (unsigned)r->lcvex_soc_tb__DOT__core__DOT__idex_insn,
                (int)r->lcvex_soc_tb__DOT__core__DOT__exmem_valid,
                (unsigned)r->lcvex_soc_tb__DOT__core__DOT__exmem_insn,
                (int)r->lcvex_soc_tb__DOT__core__DOT__memwb_valid,
                (unsigned)r->lcvex_soc_tb__DOT__core__DOT__memwb_insn,
                (int)r->lcvex_soc_tb__DOT__core__DOT__commit_valid_r);
        fprintf(f,
                "DUT control stall(id=%d if=%d wb=%d) sys(at=%d hold=%d "
                "commit=%d ready=%d) wfi(idle=%d wake=%d irq_take=%d) "
                "irq(raw=%d taken=%d) fire=%d daif=%x\n",
                (int)r->lcvex_soc_tb__DOT__core__DOT__stall_id,
                (int)r->lcvex_soc_tb__DOT__core__DOT__stall_if,
                (int)r->lcvex_soc_tb__DOT__core__DOT__stall_wb,
                (int)r->lcvex_soc_tb__DOT__core__DOT__sys_at_id,
                (int)r->lcvex_soc_tb__DOT__core__DOT__sys_hold,
                (int)r->lcvex_soc_tb__DOT__core__DOT__sys_commit,
                (int)r->lcvex_soc_tb__DOT__core__DOT__sys_commit_ready,
                (int)r->lcvex_soc_tb__DOT__core__DOT__wfi_idle,
                (int)r->lcvex_soc_tb__DOT__core__DOT__wfi_wake,
                (int)r->lcvex_soc_tb__DOT__core__DOT__wfi_irq_take,
                (int)r->lcvex_soc_tb__DOT__core__DOT__irq_pending_raw,
                (int)r->lcvex_soc_tb__DOT__core__DOT__irq_taken,
                (int)r->lcvex_soc_tb__DOT__core__DOT__commit_fire,
                (unsigned)r->lcvex_soc_tb__DOT__core__DOT__daif);
        fprintf(f,
                "DUT fetch if_pc=0x%llx fetch_pc=0x%llx "
                "pending=%d got=%d trans=%d busy=%d fault=%d settled=%d; "
                "data(active=%d pending=%d issued=%d done=%d) "
                "mmu(done=%d walk=%d) cntpct=%llu\n",
                (unsigned long long)r->lcvex_soc_tb__DOT__core__DOT__if_pc,
                (unsigned long long)r->lcvex_soc_tb__DOT__core__DOT__fetch_pc_r,
                (int)r->lcvex_soc_tb__DOT__core__DOT__fetch_pending,
                (int)r->lcvex_soc_tb__DOT__core__DOT__fetch_got_data,
                (int)r->lcvex_soc_tb__DOT__core__DOT__fetch_translated,
                (int)r->lcvex_soc_tb__DOT__core__DOT__fetch_trans_busy,
                (int)r->lcvex_soc_tb__DOT__core__DOT__fetch_faulted,
                (int)r->lcvex_soc_tb__DOT__core__DOT__fetch_next_settled,
                (int)r->lcvex_soc_tb__DOT__core__DOT__data_trans_active,
                (int)r->lcvex_soc_tb__DOT__core__DOT__dmem_pending,
                (int)r->lcvex_soc_tb__DOT__core__DOT__dmem_req_issued,
                (int)r->lcvex_soc_tb__DOT__core__DOT__dmem_done,
                (int)r->lcvex_soc_tb__DOT__core__DOT__mmu_done,
                (int)r->lcvex_soc_tb__DOT__core__DOT__mmu_walking,
                (unsigned long long)r->lcvex_soc_tb__DOT__core__DOT__cntpct_r);
        fprintf(f,
                "DUT decode valid=%d exc=%d insn=0x%08x pc=0x%llx "
                "exc_code=0x%x mmu_en=%d el=%d irq=%d timer(p=%d v=%d)\n",
                dbg_dec_valid() ? 1 : 0, dbg_dec_exc() ? 1 : 0,
                (unsigned)dbg_dec_insn(),
                (unsigned long long)dbg_dec_pc(),
                (unsigned)dbg_dec_exc_code(), dbg_mmu_en() ? 1 : 0,
                dbg_el() ? 1 : 0,
                (int)r->lcvex_soc_tb__DOT__core__DOT__irq,
                (int)r->lcvex_soc_tb__DOT__core__DOT__timer_phys_irq,
                (int)r->lcvex_soc_tb__DOT__core__DOT__timer_virt_irq);
        fprintf(f,
                "DUT sys sctlr=0x%llx tcr=0x%llx ttbr0=0x%llx "
                "ttbr1=0x%llx mair=0x%llx eff_mmu=%d\n",
                (unsigned long long)r->lcvex_soc_tb__DOT__core__DOT__sctlr_el1,
                (unsigned long long)r->lcvex_soc_tb__DOT__core__DOT__tcr_el1,
                (unsigned long long)r->lcvex_soc_tb__DOT__core__DOT__ttbr0_el1,
                (unsigned long long)r->lcvex_soc_tb__DOT__core__DOT__ttbr1_el1,
                (unsigned long long)r->lcvex_soc_tb__DOT__core__DOT__mair_el1,
                (int)r->lcvex_soc_tb__DOT__core__DOT__mmu_en_eff);
        fprintf(f,
                "DUT mmu req(v=%d accept=%d done=%d walk=%d fault=%d "
                "fsc=0x%x va=0x%llx pa=0x%llx) "
                "state=%u level=%u addr=0x%llx table=0x%llx desc=0x%llx\n",
                (int)r->lcvex_soc_tb__DOT__core__DOT__mmu_req_valid,
                (int)r->lcvex_soc_tb__DOT__core__DOT__mmu_req_accept,
                (int)r->lcvex_soc_tb__DOT__core__DOT__mmu_done,
                (int)r->lcvex_soc_tb__DOT__core__DOT__mmu_walking,
                (int)r->lcvex_soc_tb__DOT__core__DOT__mmu_fault,
                (unsigned)r->lcvex_soc_tb__DOT__core__DOT__mmu_fault_fsc,
                (unsigned long long)r->lcvex_soc_tb__DOT__core__DOT__mmu_req_va,
                (unsigned long long)r->lcvex_soc_tb__DOT__core__DOT__mmu_paddr,
                (unsigned)r->lcvex_soc_tb__DOT__core__DOT__mmu__DOT__state,
                (unsigned)r->lcvex_soc_tb__DOT__core__DOT__mmu__DOT__walk_level_r,
                (unsigned long long)r->lcvex_soc_tb__DOT__core__DOT__mmu__DOT__level_addr,
                (unsigned long long)r->lcvex_soc_tb__DOT__core__DOT__mmu__DOT__table_base,
                (unsigned long long)r->lcvex_soc_tb__DOT__core__DOT__mmu__DOT__desc);
        fprintf(f,
                "DUT data trans_pa=0x%llx fsc=0x%x "
                "exmem(va=0x%llx pa=0x%llx rdata=0x%llx) "
                "memwb(va=0x%llx rdata=0x%llx)\n",
                (unsigned long long)r->lcvex_soc_tb__DOT__core__DOT__trans_paddr_r,
                (unsigned)r->lcvex_soc_tb__DOT__core__DOT__trans_fsc_r,
                (unsigned long long)r->lcvex_soc_tb__DOT__core__DOT__exmem_mem_addr,
                (unsigned long long)r->lcvex_soc_tb__DOT__core__DOT__exmem_mem_paddr,
                (unsigned long long)r->lcvex_soc_tb__DOT__core__DOT__exmem_rdata_r,
                (unsigned long long)r->lcvex_soc_tb__DOT__core__DOT__memwb_mem_addr,
                (unsigned long long)r->lcvex_soc_tb__DOT__core__DOT__memwb_rdata_r);
    }
    void load_image(const std::string &image, uint64_t base) {
        std::vector<uint32_t> words;
        read_words(image, &words);

        for (size_t i = 0; i < words.size(); i++) {
            top_->prog_we = 1;
            top_->prog_addr = base + 4 * i;
            top_->prog_strb = 0x0f;
            top_->prog_wdata = words[i];
            tick();
        }
        top_->prog_we = 0;
    }

    // P6：QEMU bootloader_aarch64（loader_start 处，设置 x0=DTB 地址并
    // 跳转内核入口；见 hw/arm/boot.c）
    void write_bootloader(uint64_t base, uint64_t dtb_addr,
                          uint64_t entry) {
        static const uint32_t boot_code[6] = {
            0x580000c0,  // ldr x0, [pc, #0x18] -> arg
            0xaa1f03e1,  // mov x1, xzr
            0xaa1f03e2,  // mov x2, xzr
            0xaa1f03e3,  // mov x3, xzr
            0x58000084,  // ldr x4, [pc, #0x10] -> entry
            0xd61f0080,  // br x4
        };
        uint32_t lit[4] = {
            (uint32_t)dtb_addr, (uint32_t)(dtb_addr >> 32),
            (uint32_t)entry, (uint32_t)(entry >> 32),
        };
        top_->prog_we = 1;
        for (int i = 0; i < 6; i++) {
            top_->prog_addr = base + 4 * i;
            top_->prog_strb = 0x0f;
            top_->prog_wdata = boot_code[i];
            tick();
        }
        for (int i = 0; i < 4; i++) {
            top_->prog_addr = base + 4 * (6 + i);
            top_->prog_strb = 0x0f;
            top_->prog_wdata = lit[i];
            tick();
        }
        top_->prog_we = 0;
    }

    void reset_and_load(const std::string &image, uint64_t base,
                        const std::string &image2, uint64_t base2,
                        const std::string &image3, uint64_t base3,
                        uint64_t boot_dtb, uint64_t boot_entry) {
        top_->clk = 0;
        top_->rst_n = 0;
        top_->commit_ready = 1;   // M1：协调器恒就绪消费提交
        top_->difftest_wait_release = 0;
        top_->difftest_wait_cntvct_valid = 0;
        top_->difftest_wait_cntvct = 0;
        clear_restore_sys_inputs();
        top_->prog_we = 0;
        top_->prog_addr = 0;
        top_->prog_strb = 0;
        top_->prog_wdata = 0;
        top_->eval();

        if (boot_entry != 0) {
            write_bootloader(base, boot_dtb, boot_entry);
        }
        if (!image.empty()) {
            load_image(image, base);
        }
        if (!image2.empty()) {
            load_image(image2, base2);
        }
        if (!image3.empty()) {
            load_image(image3, base3);
        }
        top_->prog_we = 0;
        top_->rst_n = 1;
        tick();
    }

    void clear_restore_sys_inputs() {
        top_->difftest_restore_sys_valid = 0;
        top_->difftest_restore_pc = 0;
        top_->difftest_restore_sp_el0 = 0;
        top_->difftest_restore_sp_el1 = 0;
        top_->difftest_restore_nzcv = 0;
        top_->difftest_restore_el = 0;
        top_->difftest_restore_sp_sel = 0;
        top_->difftest_restore_daif = 0;
        top_->difftest_restore_pan = 0;
        top_->difftest_restore_dit = 0;
        top_->difftest_restore_ssbs = 0;
        top_->difftest_restore_uao = 0;
        top_->difftest_restore_tco = 0;
        top_->difftest_restore_allint = 0;
        top_->difftest_restore_elr_el1 = 0;
        top_->difftest_restore_spsr_el1 = 0;
        top_->difftest_restore_vbar_el1 = 0;
        top_->difftest_restore_sctlr_el1 = 0;
        top_->difftest_restore_tcr_el1 = 0;
        top_->difftest_restore_ttbr0_el1 = 0;
        top_->difftest_restore_ttbr1_el1 = 0;
        top_->difftest_restore_mair_el1 = 0;
        top_->difftest_restore_esr_el1 = 0;
        top_->difftest_restore_far_el1 = 0;
        top_->difftest_restore_par_el1 = 0;
        top_->difftest_restore_cpacr_el1 = 0;
        top_->difftest_restore_mdscr_el1 = 0;
        top_->difftest_restore_pmuserenr_el0 = 0;
        top_->difftest_restore_cntkctl_el1 = 0;
        top_->difftest_restore_tpidr_el0 = 0;
        top_->difftest_restore_tpidrro_el0 = 0;
        top_->difftest_restore_tpidr_el1 = 0;
        top_->difftest_restore_pir_el1 = 0;
        top_->difftest_restore_pire0_el1 = 0;
        top_->difftest_restore_zcr_el1 = 0;
        top_->difftest_restore_smcr_el1 = 0;
        top_->difftest_restore_csselr_el1 = 0;
        top_->difftest_restore_tcr2_el1 = 0;
        top_->difftest_restore_contextidr_el1 = 0;
        top_->difftest_restore_excl_valid = 0;
        top_->difftest_restore_excl_addr = 0;
        top_->difftest_restore_excl_data = 0;
        top_->difftest_restore_excl_data_hi = 0;
        // RTL 的内部 cntpct_r 表示“已提交数”；0 是 reset 后下一条
        // 指令看到的 CNT* 值，故作为 sideband 输入需编码成 1。
        top_->difftest_restore_cntpct = 1;
        top_->difftest_restore_cntp_cval = 0;
        top_->difftest_restore_cntp_ctl = 0;
        top_->difftest_restore_cntv_cval = 0;
        top_->difftest_restore_cntv_ctl = 0;
        clear_restore_fp_inputs();
    }

    void clear_restore_fp_inputs() {
        top_->difftest_restore_fp_valid = 0;
        top_->difftest_restore_fpcr = 0;
        top_->difftest_restore_fpsr = 0;
        for (unsigned i = 0; i < 32; i++) {
            top_->difftest_restore_fp_v_lo[i] = 0;
            top_->difftest_restore_fp_v_hi[i] = 0;
        }
    }

    void stage_restore_fp(const FpState *state) {
        clear_restore_fp_inputs();
        if (state == nullptr) return;
        top_->difftest_restore_fpcr = state->fpcr;
        top_->difftest_restore_fpsr = state->fpsr;
        for (unsigned i = 0; i < 32; i++) {
            top_->difftest_restore_fp_v_lo[i] = state->v[i].lo;
            top_->difftest_restore_fp_v_hi[i] = state->v[i].hi;
        }
        top_->difftest_restore_fp_valid = 1;
    }

    void stage_restore_timer(const DutTimerState *timer) {
        if (timer == nullptr) return;
        top_->difftest_restore_cntpct = timer->cntpct;
        top_->difftest_restore_cntp_cval = timer->cntp_cval;
        top_->difftest_restore_cntp_ctl = timer->cntp_ctl & 3;
        top_->difftest_restore_cntv_cval = timer->cntv_cval;
        top_->difftest_restore_cntv_ctl = timer->cntv_ctl & 3;
    }

    /* Verilator L3：显式恢复架构状态并冲刷流水线。GPR 仍在复位保持
     * 期间写入（宽数组端口将在下一轮统一收敛）；所有 PSTATE/系统寄存器
     * 和计时器状态均通过 QEMU→Verilator sideband 在时钟边界注入。 */
    void restore_arch_state(const lcvex_state &st,
                            const DutTimerState *timer = nullptr,
                            const FpState *fp = nullptr) {
        top_->rst_n = 0;
        top_->prog_we = 0;
        tick();
        tick();
        auto *r = top_->rootp;
        auto &core = r->lcvex_soc_tb__DOT__core__DOT__gpr;
        for (int i = 0; i < 31; i++) {
            core[i] = st.x[i];
        }
        clear_restore_sys_inputs();
        top_->difftest_restore_pc = st.next_pc;
        top_->difftest_restore_sp_el1 = st.sp;
        top_->difftest_restore_nzcv = st.nzcv & 0xf;
        top_->difftest_restore_el = 1;
        top_->difftest_restore_sp_sel = 1;
        top_->difftest_restore_daif = 0xf;
        top_->difftest_restore_sctlr_el1 = 0x0000000000c50838ull;
        stage_restore_timer(timer);
        stage_restore_fp(fp);
        top_->rst_n = 1;
        top_->difftest_restore_sys_valid = 1;
        tick();
        top_->difftest_restore_sys_valid = 0;
        top_->difftest_restore_fp_valid = 0;
    }

    void restore_sys_state(const DutSysState &st,
                           const DutTimerState *timer = nullptr,
                           const FpState *fp = nullptr) {
        top_->rst_n = 0;
        top_->prog_we = 0;
        tick();
        tick();
        auto *r = top_->rootp;
        auto &core = r->lcvex_soc_tb__DOT__core__DOT__gpr;
        for (int i = 0; i < 31; i++) {
            core[i] = st.x[i];
        }
        clear_restore_sys_inputs();
        top_->difftest_restore_pc = st.next_pc;
        top_->difftest_restore_sp_el0 = st.sp_el0;
        top_->difftest_restore_sp_el1 = st.sp_el1;
        top_->difftest_restore_nzcv = st.nzcv & 0xf;
        top_->difftest_restore_el = st.el & 1;
        top_->difftest_restore_sp_sel = st.sp_sel & 1;
        top_->difftest_restore_daif = (st.daif >> 6) & 0xf;
        top_->difftest_restore_pan = (st.pstate >> 22) & 1;
        top_->difftest_restore_dit = (st.pstate >> 24) & 1;
        top_->difftest_restore_ssbs = (st.pstate >> 12) & 1;
        top_->difftest_restore_uao = (st.pstate >> 23) & 1;
        top_->difftest_restore_tco = (st.pstate >> 25) & 1;
        top_->difftest_restore_allint = (st.pstate >> 13) & 1;
        top_->difftest_restore_elr_el1 = st.elr_el1;
        top_->difftest_restore_spsr_el1 = st.spsr_el1;
        top_->difftest_restore_vbar_el1 = st.vbar_el1;
        top_->difftest_restore_sctlr_el1 = st.sctlr_el1;
        top_->difftest_restore_tcr_el1 = st.tcr_el1;
        top_->difftest_restore_ttbr0_el1 = st.ttbr0_el1;
        top_->difftest_restore_ttbr1_el1 = st.ttbr1_el1;
        top_->difftest_restore_mair_el1 = st.mair_el1;
        top_->difftest_restore_esr_el1 = (uint32_t)st.esr_el1;
        top_->difftest_restore_far_el1 = st.far_el1;
        top_->difftest_restore_par_el1 = st.par_el1;
        top_->difftest_restore_cpacr_el1 = st.cpacr_el1;
        top_->difftest_restore_mdscr_el1 = st.mdscr_el1;
        top_->difftest_restore_pmuserenr_el0 = st.pmuserenr_el0;
        top_->difftest_restore_cntkctl_el1 = st.cntkctl_el1;
        top_->difftest_restore_tpidr_el0 = st.tpidr_el0;
        top_->difftest_restore_tpidrro_el0 = st.tpidrro_el0;
        top_->difftest_restore_tpidr_el1 = st.tpidr_el1;
        top_->difftest_restore_pir_el1 = st.pir_el1;
        top_->difftest_restore_pire0_el1 = st.pire0_el1;
        top_->difftest_restore_zcr_el1 = st.zcr_el1;
        top_->difftest_restore_smcr_el1 = st.smcr_el1;
        top_->difftest_restore_csselr_el1 = st.csselr_el1;
        top_->difftest_restore_tcr2_el1 = st.tcr2_el1;
        top_->difftest_restore_contextidr_el1 = st.contextidr_el1;
        top_->difftest_restore_excl_valid =
            st.exclusive_addr != std::numeric_limits<uint64_t>::max();
        top_->difftest_restore_excl_addr = st.exclusive_addr;
        top_->difftest_restore_excl_data = st.exclusive_val;
        top_->difftest_restore_excl_data_hi = st.exclusive_high;
        stage_restore_timer(timer);
        stage_restore_fp(fp);
        top_->rst_n = 1;
        top_->difftest_restore_sys_valid = 1;
        tick();
        top_->difftest_restore_sys_valid = 0;
        top_->difftest_restore_fp_valid = 0;
    }

    void restore_gic_state(const DutGicState &st) {
        auto *r = top_->rootp;
        r->lcvex_soc_tb__DOT__gic__DOT__ctlr_r = st.ctlr & 3;
        r->lcvex_soc_tb__DOT__gic__DOT__cpu_ctlr_r = st.cpu_ctlr & 0x21f;
        r->lcvex_soc_tb__DOT__gic__DOT__pmr_r = st.priority_mask & 0xff;
        r->lcvex_soc_tb__DOT__gic__DOT__bpr_r = st.bpr & 7;
        r->lcvex_soc_tb__DOT__gic__DOT__abpr_r = st.abpr & 7;
        uint32_t pending[3] = {};
        uint32_t enabled[3] = {};
        uint32_t active[3] = {};
        uint32_t edge[3] = {};
        uint32_t level[3] = {};
        uint32_t group[3] = {};
        for (int i = 0; i < 96; i++) {
            const int word = i >> 5;
            const uint32_t bit = UINT32_C(1) << (i & 31);
            if (st.irq[i].enabled) enabled[word] |= bit;
            if (st.irq[i].pending) pending[word] |= bit;
            if (st.irq[i].active) active[word] |= bit;
            if (st.irq[i].edge) edge[word] |= bit;
            if (st.irq[i].level) level[word] |= bit;
            if (st.irq[i].group) group[word] |= bit;
            r->lcvex_soc_tb__DOT__gic__DOT__prio_r[i] = st.priority[i];
        }
        for (int i = 0; i < 3; i++) {
            r->lcvex_soc_tb__DOT__gic__DOT__pending_r[i] = pending[i];
            r->lcvex_soc_tb__DOT__gic__DOT__enabled_r[i] = enabled[i];
            r->lcvex_soc_tb__DOT__gic__DOT__active_r[i] = active[i];
            r->lcvex_soc_tb__DOT__gic__DOT__edge_r[i] = edge[i];
            r->lcvex_soc_tb__DOT__gic__DOT__level_r[i] = level[i];
            r->lcvex_soc_tb__DOT__gic__DOT__group_r[i] = group[i];
        }
    }

    void restore_mmio_fabric_state(const LcvexMmioFabricState &st) {
        if (!lcvex_mmio_fabric_restore(&st)) {
            throw std::runtime_error("C++ MMIO checkpoint 格式无效");
        }
        // DPI C++ 状态和 bridge 内的退休虚拟时间必须同时恢复；否则下一次
        // retire 会把 PL031 的时间倒回 reset 后的 1 ns。
        top_->rootp->lcvex_soc_tb__DOT__fabric__DOT__virt_ns_r = st.now_ns;
    }

    // P6 临时快进：旧 sys sidecar 尚未包含 ZCR/SMCR/CSSELR；
    // 新格式加入前允许恢复脚本显式注入已由 QEMU probe 确认的 SMCR LEN。
    void restore_smcr_control(uint64_t value) {
        top_->rootp->lcvex_soc_tb__DOT__core__DOT__smcr_el1 =
            value & 0x8000000f;
    }

    void load_ram_file(const std::string &path) {
        std::ifstream f(path, std::ios::binary | std::ios::ate);
        if (!f) {
            fprintf(stderr, "无法打开 DUT checkpoint RAM：%s\n", path.c_str());
            throw std::runtime_error("DUT RAM checkpoint open failed");
        }
        std::streamoff n = f.tellg();
        constexpr size_t DUT_RAM_BYTES = 1ull << 27;
        if (n <= 0 || (uint64_t)n > DUT_RAM_BYTES) {
            fprintf(stderr, "DUT checkpoint RAM 大小无效：%lld\n",
                    (long long)n);
            throw std::runtime_error("DUT RAM checkpoint size failed");
        }
        f.seekg(0, std::ios::beg);
        auto &ram = top_->rootp->lcvex_soc_tb__DOT__mem__DOT__sram;
        for (size_t i = 0; i < (size_t)n; i++) {
            unsigned char byte;
            if (!f.read(reinterpret_cast<char *>(&byte), 1)) {
                throw std::runtime_error("DUT RAM checkpoint read failed");
            }
            ram[i] = byte;
        }
    }

    bool step_until_commit(uint64_t max_cycles, CommitPacket *out) {
        for (uint64_t i = 0; i < max_cycles; i++) {
            tick();
            if (top_->commit_valid) {
                *out = read_commit();
                return true;
            }
        }
        return false;
    }

    // P6 调试：无时钟读 RAM 8 字节（锁步失败诊断）。
    // 诊断发生在 QEMU 等待当前 COMMIT 的窗口内，绝不能通过同步
    // dbg_rdata 端口调用 tick()；否则会偷偷推进 DUT，破坏 PRE/COMMIT
    // 一一对应（此前正是 MSR DAIF 假性“丢失”的原因）。直接读取
    // Verilator 暴露的 RAM 数组，地址保持与 dbg_addr 的低 27 位回绕
    // 语义一致。
    uint64_t read_mem(uint64_t addr) const {
        constexpr uint32_t RAM_MASK = (1u << 27) - 1u;
        const uint32_t off = static_cast<uint32_t>(addr) & RAM_MASK;
        const auto &ram = top_->rootp->lcvex_soc_tb__DOT__mem__DOT__sram;
        uint64_t value = 0;
        for (unsigned i = 0; i < 8; i++) {
            value |= static_cast<uint64_t>(ram[(off + i) & RAM_MASK])
                     << (8 * i);
        }
        return value;
    }

  private:
    Vlcvex_soc_tb *top_;

    void tick() {
        top_->clk = 1;
        top_->eval();
        top_->clk = 0;
        top_->eval();
        // WAIT_RESUME/QEMU immediate-return sideband 只允许影响一个完整 DUT
        // 时钟；若 WFx 提交尚未可见，core 内部 pending latch 会保留请求。
        top_->difftest_wait_release = 0;
        top_->difftest_wait_cntvct_valid = 0;
    }

    CommitPacket read_commit() const {
        CommitPacket p;
        p.pc = top_->commit_pc;
        p.next_pc = top_->commit_next_pc;
        p.insn = top_->commit_insn;
        p.gpr_we = top_->commit_gpr_we;
        p.gpr_rd = top_->commit_gpr_rd;
        p.gpr_wdata = top_->commit_gpr_wdata;
        p.gpr2_we = top_->commit_gpr2_we;
        p.gpr2_rd = top_->commit_gpr2_rd;
        p.gpr2_wdata = top_->commit_gpr2_wdata;
        p.gpr3_we = top_->commit_gpr3_we;
        p.gpr3_rd = top_->commit_gpr3_rd;
        p.gpr3_wdata = top_->commit_gpr3_wdata;
        p.sp_we = top_->commit_sp_we;
        p.sp_wdata = top_->commit_sp_wdata;
        p.nzcv_we = top_->commit_nzcv_we;
        p.nzcv = top_->commit_nzcv;
        p.mem_we = top_->commit_mem_we;
        p.mem_addr = top_->commit_mem_addr;
        p.mem_wdata = top_->commit_mem_wdata;
        p.mem_strb = top_->commit_mem_strb;
        p.mem2_we = top_->commit_mem2_we;
        p.mem2_addr = top_->commit_mem2_addr;
        p.mem2_wdata = top_->commit_mem2_wdata;
        p.mem2_strb = top_->commit_mem2_strb;
        p.exc_valid = top_->commit_exc_valid;
        p.exc_code = top_->commit_exc_code;
        p.exc_esr = top_->commit_exc_esr;
        p.exc_far = top_->commit_exc_far;
        p.mon_we = top_->commit_mon_we;
        p.mon_valid = top_->commit_mon_valid;
        p.mon_addr = top_->commit_mon_addr;
        p.mon_data = top_->commit_mon_data;
        p.mon_data2 = top_->commit_mon_data2;
        p.fp_effect_available = true;
        p.vec_write_count = top_->commit_vec_write_count;
        p.vec_rd[0] = top_->commit_vec_rd0;
        p.vec_rd[1] = top_->commit_vec_rd1;
        p.vec_rd[2] = top_->commit_vec_rd2;
        p.vec_rd[3] = top_->commit_vec_rd3;
        p.vec_wdata[0] = {top_->commit_vec_wdata0_lo,
                          top_->commit_vec_wdata0_hi};
        p.vec_wdata[1] = {top_->commit_vec_wdata1_lo,
                          top_->commit_vec_wdata1_hi};
        p.vec_wdata[2] = {top_->commit_vec_wdata2_lo,
                          top_->commit_vec_wdata2_hi};
        p.vec_wdata[3] = {top_->commit_vec_wdata3_lo,
                          top_->commit_vec_wdata3_hi};
        p.fpcr_we = top_->commit_fpcr_we;
        p.fpcr_wdata = top_->commit_fpcr_wdata;
        p.fpsr_we = top_->commit_fpsr_we;
        p.fpsr_wdata = top_->commit_fpsr_wdata;
        return p;
    }

    static void read_words(const std::string &path, std::vector<uint32_t> *out) {
        std::ifstream f(path, std::ios::binary);
        if (!f) {
            fprintf(stderr, "无法打开镜像 %s\n", path.c_str());
            exit(2);
        }
        uint8_t buf[4];
        while (f.read(reinterpret_cast<char *>(buf), sizeof(buf))) {
            uint32_t w = buf[0] | (buf[1] << 8) | (buf[2] << 16) |
                         (buf[3] << 24);
            out->push_back(w);
        }
    }
};

void apply_commit(ShadowState *s, const CommitPacket &p) {
    if (p.gpr_we && p.gpr_rd != 31) {
        s->x[p.gpr_rd] = p.gpr_wdata;
    }
    if (p.gpr2_we && p.gpr2_rd != 31) {
        s->x[p.gpr2_rd] = p.gpr2_wdata;
    }
    if (p.gpr3_we && p.gpr3_rd != 31) {
        s->x[p.gpr3_rd] = p.gpr3_wdata;
    }
    if (p.sp_we) {
        s->sp = p.sp_wdata;
    }
    if (p.nzcv_we) {
        s->nzcv = p.nzcv;
    }
    s->pc = p.next_pc;
}

static bool commit_equal(const CommitPacket &a, const CommitPacket &b) {
    return a.pc == b.pc && a.next_pc == b.next_pc && a.insn == b.insn &&
           a.gpr_we == b.gpr_we && a.gpr_rd == b.gpr_rd &&
           a.gpr_wdata == b.gpr_wdata && a.gpr2_we == b.gpr2_we &&
           a.gpr2_rd == b.gpr2_rd && a.gpr2_wdata == b.gpr2_wdata &&
           a.gpr3_we == b.gpr3_we && a.gpr3_rd == b.gpr3_rd &&
           a.gpr3_wdata == b.gpr3_wdata && a.sp_we == b.sp_we &&
           a.sp_wdata == b.sp_wdata && a.nzcv_we == b.nzcv_we &&
           a.nzcv == b.nzcv && a.mem_we == b.mem_we &&
           a.mem_addr == b.mem_addr && a.mem_wdata == b.mem_wdata &&
           a.mem_strb == b.mem_strb && a.mem2_we == b.mem2_we &&
           a.mem2_addr == b.mem2_addr && a.mem2_wdata == b.mem2_wdata &&
           a.mem2_strb == b.mem2_strb && a.exc_valid == b.exc_valid &&
           a.exc_code == b.exc_code && a.exc_esr == b.exc_esr &&
           a.exc_far == b.exc_far && a.mon_we == b.mon_we &&
           a.mon_valid == b.mon_valid && a.mon_addr == b.mon_addr &&
           a.mon_data == b.mon_data && a.mon_data2 == b.mon_data2;
}

static int run_dut_restore_smoke(const std::string &image, uint64_t base,
                                 uint64_t split, uint64_t count) {
    if (split == 0 || count == 0 || split + count > 100000) {
        fprintf(stderr, "restore smoke 参数无效：split=%llu count=%llu\n",
                (unsigned long long)split, (unsigned long long)count);
        return 2;
    }
    VerilatorDut continuous;
    continuous.reset_and_load(image, base, "", 0, "", 0, 0, 0);
    std::vector<CommitPacket> expected;
    expected.reserve((size_t)(split + count));
    for (uint64_t i = 0; i < split + count; i++) {
        CommitPacket p;
        if (!continuous.step_until_commit(1000, &p)) {
            fprintf(stderr, "restore smoke 连续运行在 seq=%llu 超时\n",
                    (unsigned long long)i);
            return 1;
        }
        expected.push_back(p);
    }

    ShadowState saved;
    saved.pc = base;
    saved.nzcv = 4;
    for (uint64_t i = 0; i < split; i++) {
        apply_commit(&saved, expected[(size_t)i]);
    }
    lcvex_state state = {};
    state.pc = saved.pc;
    state.next_pc = saved.pc;
    for (int i = 0; i < 31; i++) {
        state.x[i] = saved.x[i];
    }
    state.sp = saved.sp;
    state.nzcv = saved.nzcv;

    VerilatorDut restored;
    restored.reset_and_load(image, base, "", 0, "", 0, 0, 0);
    restored.restore_arch_state(state);
    for (uint64_t i = 0; i < count; i++) {
        CommitPacket actual;
        if (!restored.step_until_commit(1000, &actual)) {
            fprintf(stderr, "restore smoke 恢复后在 seq=%llu 超时\n",
                    (unsigned long long)(split + i));
            return 1;
        }
        const CommitPacket &want = expected[(size_t)(split + i)];
        if (!commit_equal(actual, want)) {
            fprintf(stderr,
                    "restore smoke 分歧：恢复 seq=%llu actual pc=0x%llx "
                    "want pc=0x%llx\n",
                    (unsigned long long)(split + i),
                    (unsigned long long)actual.pc,
                    (unsigned long long)want.pc);
            return 1;
        }
    }
    fprintf(stderr, "PASS: DUT checkpoint restore smoke split=%llu count=%llu\n",
            (unsigned long long)split, (unsigned long long)count);
    return 0;
}

static int run_dut_arch_file_smoke(const std::string &image, uint64_t base,
                                   const std::string &arch_path,
                                   uint64_t count,
                                   const std::string &ram_path,
                                   const std::string &timer_path) {
    uint64_t saved_seq = 0;
    lcvex_state state = {};
    if (!read_arch_state_file(arch_path, &saved_seq, &state)) {
        fprintf(stderr, "无法读取架构 checkpoint：%s\n", arch_path.c_str());
        return 2;
    }
    if (saved_seq > 100000 || count == 0 || count > 100000) {
        fprintf(stderr, "架构 checkpoint seq/count 超出 smoke 范围\n");
        return 2;
    }
    DutTimerState timer_state = {};
    bool have_timer = !timer_path.empty();
    if (have_timer && !read_timer_state_file(timer_path, &timer_state)) {
        fprintf(stderr, "无法读取定时器 checkpoint：%s\n",
                timer_path.c_str());
        return 2;
    }
    uint64_t split = saved_seq + 1;
    VerilatorDut continuous;
    continuous.reset_and_load(image, base, "", 0, "", 0, 0, 0);
    std::vector<CommitPacket> expected;
    expected.reserve((size_t)(split + count));
    for (uint64_t i = 0; i < split + count; i++) {
        CommitPacket p;
        if (!continuous.step_until_commit(1000, &p)) {
            fprintf(stderr, "arch-file smoke 连续运行 seq=%llu 超时\n",
                    (unsigned long long)i);
            return 1;
        }
        expected.push_back(p);
    }
    VerilatorDut restored;
    restored.reset_and_load(image, base, "", 0, "", 0, 0, 0);
    if (!ram_path.empty()) {
        restored.load_ram_file(ram_path);
    }
    restored.restore_arch_state(state, have_timer ? &timer_state : nullptr);
    for (uint64_t i = 0; i < count; i++) {
        CommitPacket actual;
        if (!restored.step_until_commit(1000, &actual) ||
            !commit_equal(actual, expected[(size_t)(split + i)])) {
            fprintf(stderr, "arch-file smoke 恢复后 seq=%llu 分歧\n",
                    (unsigned long long)(split + i));
            return 1;
        }
    }
    fprintf(stderr,
            "PASS: DUT arch-file restore smoke checkpoint_seq=%llu count=%llu\n",
            (unsigned long long)saved_seq, (unsigned long long)count);
    return 0;
}

static int run_dut_gic_file_smoke(const std::string &image, uint64_t base,
                                  const std::string &arch_path,
                                  const std::string &gic_path,
                                  const std::string &timer_path,
                                  uint64_t count) {
    uint64_t saved_seq = 0;
    lcvex_state arch = {};
    DutGicState gic = {};
    DutTimerState timer = {};
    if (!read_arch_state_file(arch_path, &saved_seq, &arch) ||
        !read_gic_state_file(gic_path, &gic) ||
        (!timer_path.empty() && !read_timer_state_file(timer_path, &timer)) ||
        count == 0 || count > 100000) {
        fprintf(stderr, "无法读取 GIC checkpoint smoke 输入\n");
        return 2;
    }
    uint64_t split = saved_seq + 1;
    VerilatorDut continuous;
    continuous.reset_and_load(image, base, "", 0, "", 0, 0, 0);
    std::vector<CommitPacket> expected;
    expected.reserve((size_t)(split + count));
    for (uint64_t i = 0; i < split + count; i++) {
        CommitPacket p;
        if (!continuous.step_until_commit(1000, &p)) return 1;
        expected.push_back(p);
    }
    VerilatorDut restored;
    restored.reset_and_load(image, base, "", 0, "", 0, 0, 0);
    restored.restore_arch_state(arch, !timer_path.empty() ? &timer : nullptr);
    restored.restore_gic_state(gic);
    for (uint64_t i = 0; i < count; i++) {
        CommitPacket actual;
        if (!restored.step_until_commit(1000, &actual) ||
            !commit_equal(actual, expected[(size_t)(split + i)])) {
            fprintf(stderr, "GIC checkpoint smoke seq=%llu 分歧\n",
                    (unsigned long long)(split + i));
            return 1;
        }
    }
    fprintf(stderr, "PASS: DUT GIC checkpoint restore smoke seq=%llu count=%llu\n",
            (unsigned long long)saved_seq, (unsigned long long)count);
    return 0;
}

std::vector<std::string> g_errors;

void check(bool ok, const std::string &what) {
    if (!ok) {
        g_errors.push_back(what);
    }
}

static std::string json_escape(const std::string &value) {
    std::string out;
    out.reserve(value.size() + 8);
    for (unsigned char c : value) {
        switch (c) {
        case '"': out += "\\\""; break;
        case '\\': out += "\\\\"; break;
        case '\b': out += "\\b"; break;
        case '\f': out += "\\f"; break;
        case '\n': out += "\\n"; break;
        case '\r': out += "\\r"; break;
        case '\t': out += "\\t"; break;
        default:
            if (c < 0x20) {
                char buf[8];
                snprintf(buf, sizeof(buf), "\\u%04x", c);
                out += buf;
            } else {
                out.push_back(static_cast<char>(c));
            }
            break;
        }
    }
    return out;
}

static void json_string(std::ostream &out, const std::string &value) {
    out << '"' << json_escape(value) << '"';
}

static std::string hex_value(uint64_t value, unsigned width) {
    char buf[32];
    snprintf(buf, sizeof(buf), "0x%0*llx", width,
             static_cast<unsigned long long>(value));
    return std::string(buf);
}

static std::string fp_raw_value(const lcvex_v128 &value) {
    char buf[48];
    snprintf(buf, sizeof(buf), "0x%016llx%016llx",
             static_cast<unsigned long long>(value.hi),
             static_cast<unsigned long long>(value.lo));
    return std::string(buf);
}

static unsigned store_size(uint8_t strb) {
    unsigned size = 0;
    for (unsigned bit = 0; bit < 8; bit++) {
        size += (strb >> bit) & 1u;
    }
    return size;
}

static void write_fp_state_json(std::ostream &out, const FpState &state,
                                unsigned indent) {
    const std::string pad(indent, ' ');
    out << pad << "{\n";
    out << pad << "  \"fpcr\": " << state.fpcr << ",\n";
    out << pad << "  \"fpcr_hex\": ";
    json_string(out, hex_value(state.fpcr, 8));
    out << ",\n";
    out << pad << "  \"fpsr\": " << state.fpsr << ",\n";
    out << pad << "  \"fpsr_hex\": ";
    json_string(out, hex_value(state.fpsr, 8));
    out << ",\n";
    out << pad << "  \"v\": [\n";
    for (unsigned i = 0; i < state.v.size(); i++) {
        const auto &v = state.v[i];
        out << pad << "    {\"index\": " << i
            << ", \"lo\": " << v.lo
            << ", \"hi\": " << v.hi << ", \"raw\": ";
        json_string(out, fp_raw_value(v));
        out << "}" << (i + 1 == state.v.size() ? "\n" : ",\n");
    }
    out << pad << "  ]\n" << pad << "}";
}

static void write_scalar_state_json(std::ostream &out,
                                    const lcvex_state &state,
                                    unsigned indent) {
    const std::string pad(indent, ' ');
    out << pad << "{\n";
    out << pad << "  \"pc\": " << state.pc << ",\n";
    out << pad << "  \"pc_hex\": ";
    json_string(out, hex_value(state.pc, 16));
    out << ",\n";
    out << pad << "  \"next_pc\": " << state.next_pc << ",\n";
    out << pad << "  \"next_pc_hex\": ";
    json_string(out, hex_value(state.next_pc, 16));
    out << ",\n";
    out << pad << "  \"insn\": " << state.insn << ",\n";
    out << pad << "  \"insn_hex\": ";
    json_string(out, hex_value(state.insn, 8));
    out << ",\n";
    out << pad << "  \"x\": [";
    for (unsigned i = 0; i < 31; i++) {
        out << (i == 0 ? "\n" : ",\n") << pad << "    " << state.x[i];
    }
    out << "\n" << pad << "  ],\n";
    out << pad << "  \"sp\": " << state.sp << ",\n";
    out << pad << "  \"nzcv\": " << state.nzcv << "\n";
    out << pad << "}";
}

static void write_dut_stores_json(std::ostream &out,
                                  const CommitPacket *packet,
                                  unsigned indent) {
    const std::string pad(indent, ' ');
    bool first = true;
    out << pad << "[";
    auto write_one = [&](uint64_t addr, uint64_t data, uint8_t strb) {
        out << (first ? "\n" : ",\n") << pad << "  {\"addr\": " << addr
            << ", \"addr_hex\": ";
        json_string(out, hex_value(addr, 16));
        out << ", \"data\": " << data << ", \"data_hex\": ";
        json_string(out, hex_value(data, 16));
        out << ", \"strb\": " << static_cast<unsigned>(strb)
            << ", \"strb_hex\": ";
        json_string(out, hex_value(strb, 2));
        out << ", \"size_bytes\": " << store_size(strb) << "}";
        first = false;
    };
    if (packet != nullptr && packet->mem_we) {
        write_one(packet->mem_addr, packet->mem_wdata, packet->mem_strb);
    }
    if (packet != nullptr && packet->mem2_we) {
        write_one(packet->mem2_addr, packet->mem2_wdata, packet->mem2_strb);
    }
    if (first) {
        out << "]";
    } else {
        out << "\n" << pad << "]";
    }
}

static void write_qemu_stores_json(std::ostream &out,
                                   const lcvex_commit *commit,
                                   unsigned indent) {
    const std::string pad(indent, ' ');
    out << pad << "[";
    bool first = true;
    if (commit != nullptr) {
        for (uint32_t i = 0; i < commit->store_count &&
             i < LCVEX_MAX_STORES; i++) {
            const auto &store = commit->stores[i];
            out << (first ? "\n" : ",\n") << pad << "  {\"addr\": "
                << store.addr << ", \"addr_hex\": ";
            json_string(out, hex_value(store.addr, 16));
            out << ", \"data\": " << store.data << ", \"data_hex\": ";
            json_string(out, hex_value(store.data, 16));
            out << ", \"strb\": " << static_cast<unsigned>(store.strb)
                << ", \"strb_hex\": ";
            json_string(out, hex_value(store.strb, 2));
            out << ", \"size_bytes\": " << store_size(store.strb) << "}";
            first = false;
        }
    }
    if (first) {
        out << "]";
    } else {
        out << "\n" << pad << "]";
    }
}

static std::string instruction_disassembly(uint32_t insn) {
    // The socket protocol deliberately carries the raw encoding, not host
    // disassembler text.  .inst is an unambiguous AArch64 disassembly form
    // and remains reproducible even when a toolchain is absent.
    return std::string(".inst ") + hex_value(insn, 8);
}

static std::string first_fp_raw_mismatch(const FpState &lhs,
                                         const FpState &rhs,
                                         const char *lhs_name,
                                         const char *rhs_name) {
    if (lhs.fpcr != rhs.fpcr) {
        return std::string("FPCR raw mismatch ") + lhs_name + "=" +
               hex_value(lhs.fpcr, 8) + " " + rhs_name + "=" +
               hex_value(rhs.fpcr, 8);
    }
    if (lhs.fpsr != rhs.fpsr) {
        return std::string("FPSR raw mismatch ") + lhs_name + "=" +
               hex_value(lhs.fpsr, 8) + " " + rhs_name + "=" +
               hex_value(rhs.fpsr, 8);
    }
    for (unsigned i = 0; i < lhs.v.size(); i++) {
        if (lhs.v[i].lo != rhs.v[i].lo || lhs.v[i].hi != rhs.v[i].hi) {
            return std::string("V") + std::to_string(i) +
                   " raw mismatch " + lhs_name + "=" + fp_raw_value(lhs.v[i]) +
                   " " + rhs_name + "=" + fp_raw_value(rhs.v[i]);
        }
    }
    return {};
}

static std::string fp_failure_path(const std::string &dump_path) {
    const size_t slash = dump_path.find_last_of('/');
    if (slash == std::string::npos) return "fail-fp.json";
    return dump_path.substr(0, slash + 1) + "fail-fp.json";
}

static void write_window_records_json(std::ostream &out,
                                      uint64_t failure_seq,
                                      const lcvex_pre *pre,
                                      const CommitPacket *dut_packet,
                                      const lcvex_commit *qemu_commit) {
    std::vector<WindowRec> recent = g_window;
    if (pre != nullptr || dut_packet != nullptr || qemu_commit != nullptr) {
        WindowRec current = {};
        current.ok = false;
        if (pre != nullptr) {
            current.pre_pc = pre->pre.pc;
            current.pre_insn = pre->pre.insn;
        }
        if (dut_packet != nullptr) {
            current.dut_pc = dut_packet->pc;
            current.dut_insn = dut_packet->insn;
            current.dut_next_pc = dut_packet->next_pc;
        }
        if (qemu_commit != nullptr) {
            current.qemu_pc = qemu_commit->post.pc;
            current.qemu_insn = qemu_commit->post.insn;
            current.qemu_next_pc = qemu_commit->post.next_pc;
        }
        current.seq = failure_seq;
        recent.push_back(current);
    }
    if (recent.size() > 32) {
        recent.erase(recent.begin(), recent.end() - 32);
    }

    out << "  \"recent_records\": [";
    for (size_t i = 0; i < recent.size(); i++) {
        const WindowRec &r = recent[i];
        out << (i == 0 ? "\n" : ",\n")
            << "    {\"seq\": " << r.seq
            << ", \"ok\": " << (r.ok ? "true" : "false")
            << ", \"pre_pc\": " << r.pre_pc
            << ", \"pre_pc_hex\": ";
        json_string(out, hex_value(r.pre_pc, 16));
        out << ", \"pre_insn\": " << r.pre_insn
            << ", \"pre_insn_hex\": ";
        json_string(out, hex_value(r.pre_insn, 8));
        out << ", \"pre_disassembly\": ";
        json_string(out, instruction_disassembly(static_cast<uint32_t>(r.pre_insn)));
        out << ", \"dut_pc\": " << r.dut_pc
            << ", \"dut_insn\": " << r.dut_insn
            << ", \"dut_next_pc\": " << r.dut_next_pc
            << ", \"qemu_pc\": " << r.qemu_pc
            << ", \"qemu_insn\": " << r.qemu_insn
            << ", \"qemu_next_pc\": " << r.qemu_next_pc << "}";
    }
    out << (recent.empty() ? "],\n" : "\n  ],\n");
}

static bool write_fail_fp_json(
    const std::string &path, const std::string &stage, uint64_t seq,
    const FpState *qemu_pre, const FpState *dut_pre,
    const FpState *qemu_post, const FpState *dut_post,
    const lcvex_pre *pre, const CommitPacket *dut_packet,
    const lcvex_commit *qemu_commit, const std::vector<std::string> &errors) {
    std::ofstream out(path);
    if (!out) {
        fprintf(stderr, "无法写入 FP 失败诊断 %s: %s\n", path.c_str(),
                strerror(errno));
        return false;
    }

    const FpState zero = {};
    const FpState &qpre = qemu_pre != nullptr ? *qemu_pre : zero;
    const FpState &dpre = dut_pre != nullptr ? *dut_pre : zero;
    const FpState &qpost = qemu_post != nullptr ? *qemu_post : qpre;
    const FpState &dpost = dut_post != nullptr ? *dut_post : dpre;

    uint64_t instruction_pc = 0;
    uint64_t instruction_next_pc = 0;
    uint32_t instruction_insn = 0;
    bool instruction_available = false;
    if (pre != nullptr) {
        instruction_available = true;
        instruction_pc = pre->pre.pc;
        instruction_next_pc = pre->pre.next_pc;
        instruction_insn = pre->pre.insn;
    }
    if (dut_packet != nullptr) {
        instruction_available = true;
        instruction_pc = dut_packet->pc;
        instruction_next_pc = dut_packet->next_pc;
        instruction_insn = dut_packet->insn;
    } else if (qemu_commit != nullptr) {
        instruction_available = true;
        instruction_pc = qemu_commit->post.pc;
        instruction_next_pc = qemu_commit->post.next_pc;
        instruction_insn = qemu_commit->post.insn;
    }

    out << "{\n";
    out << "  \"schema\": \"lcvex-fail-fp-v1\",\n";
    out << "  \"schema_version\": 1,\n";
    out << "  \"status\": \"mismatch\",\n";
    out << "  \"stage\": ";
    json_string(out, stage);
    out << ",\n  \"seq\": " << seq << ",\n";
    out << "  \"reason\": ";
    json_string(out, errors.empty() ? "FP raw state mismatch" : errors.front());
    out << ",\n  \"first_raw_mismatch\": ";
    json_string(out, g_failure_fp_first_mismatch.empty()
                         ? (errors.empty() ? "FP raw state mismatch"
                                            : errors.front())
                         : g_failure_fp_first_mismatch);
    out << ",\n  \"comparison\": {\"transport\": \"raw-bit\","
           " \"nan_policy\": \"raw-bit; no epsilon\"},\n";

    out << "  \"cpu_profile\": ";
    json_string(out, g_fp_failure_context.cpu_profile);
    out << ",\n";
    out << "  \"capability\": {\n"
           "    \"fp_neon_required\": "
        << (g_fp_failure_context.fp_required ? "true" : "false") << ",\n"
           "    \"fp_neon_enabled\": "
        << ((g_fp_failure_context.config_state_mask &
             LCVEX_CFG_CAP_FP_NEON) != 0 ? "true" : "false") << ",\n"
           "    \"hello_api_version\": "
        << g_fp_failure_context.hello_api_version << ",\n"
           "    \"config_state_mask\": "
        << g_fp_failure_context.config_state_mask << ",\n"
           "    \"config_state_mask_hex\": ";
    json_string(out, hex_value(g_fp_failure_context.config_state_mask, 8));
    out << ",\n"
           "    \"protocol_version\": " << LCVEX_MSG_VERSION << ",\n"
           "    \"feature_bits\": " << LCVEX_FP_FEATURE_NEON << ",\n"
           "    \"vector_bytes\": " << LCVEX_FP_VECTOR_BYTES << ",\n"
           "    \"max_vectors_per_commit\": " << LCVEX_FP_MAX_VECTORS
        << ",\n"
           "    \"fp_ready\": "
        << (g_fp_failure_context.fp_ready ? "true" : "false") << "\n"
           "  },\n";

    out << "  \"instruction\": {\n"
           "    \"available\": "
        << (instruction_available ? "true" : "false") << ",\n"
           "    \"seq\": " << seq << ",\n"
           "    \"pc\": " << instruction_pc << ",\n"
           "    \"pc_hex\": ";
    json_string(out, hex_value(instruction_pc, 16));
    out << ",\n    \"next_pc\": " << instruction_next_pc
        << ",\n    \"next_pc_hex\": ";
    json_string(out, hex_value(instruction_next_pc, 16));
    out << ",\n    \"encoding\": " << instruction_insn
        << ",\n    \"encoding_hex\": ";
    json_string(out, hex_value(instruction_insn, 8));
    out << ",\n    \"disassembly\": ";
    json_string(out, instruction_available
                         ? instruction_disassembly(instruction_insn)
                         : "none (FP_INIT handshake, no guest instruction)");
    out << "\n  },\n";

    out << "  \"fp\": {\n    \"pre\":\n";
    write_fp_state_json(out, qpre, 6);
    out << ",\n    \"post\":\n";
    write_fp_state_json(out, qpost, 6);
    out << ",\n    \"dut_pre\":\n";
    write_fp_state_json(out, dpre, 6);
    out << ",\n    \"dut_post\":\n";
    write_fp_state_json(out, dpost, 6);
    out << ",\n    \"qemu\": {\n      \"pre\":\n";
    write_fp_state_json(out, qpre, 8);
    out << ",\n      \"post\":\n";
    write_fp_state_json(out, qpost, 8);
    out << "\n    },\n    \"dut\": {\n      \"pre\":\n";
    write_fp_state_json(out, dpre, 8);
    out << ",\n      \"post\":\n";
    write_fp_state_json(out, dpost, 8);
    out << "\n    }\n  },\n";

    out << "  \"scalar_stores\": {\n    \"dut\":\n";
    write_dut_stores_json(out, dut_packet, 6);
    out << ",\n    \"qemu\":\n";
    write_qemu_stores_json(out, qemu_commit, 6);
    out << "\n  },\n";

    out << "  \"scalar\": {\n";
    out << "    \"pre\": ";
    if (pre != nullptr) {
        out << "\n";
        write_scalar_state_json(out, pre->pre, 6);
    } else {
        out << "null";
    }
    out << ",\n    \"qemu_post\": ";
    if (qemu_commit != nullptr) {
        out << "\n";
        write_scalar_state_json(out, qemu_commit->post, 6);
    } else {
        out << "null";
    }
    out << ",\n    \"dut_commit\": ";
    if (dut_packet != nullptr) {
        out << "{\"pc\": " << dut_packet->pc
            << ", \"next_pc\": " << dut_packet->next_pc
            << ", \"insn\": " << dut_packet->insn
            << ", \"gpr_we\": " << (dut_packet->gpr_we ? "true" : "false")
            << ", \"gpr_rd\": " << static_cast<unsigned>(dut_packet->gpr_rd)
            << ", \"gpr_wdata\": " << dut_packet->gpr_wdata
            << ", \"sp_we\": " << (dut_packet->sp_we ? "true" : "false")
            << ", \"sp_wdata\": " << dut_packet->sp_wdata
            << ", \"nzcv_we\": " << (dut_packet->nzcv_we ? "true" : "false")
            << ", \"nzcv\": " << static_cast<unsigned>(dut_packet->nzcv)
            << ", \"exc_valid\": "
            << (dut_packet->exc_valid ? "true" : "false") << "}";
    } else {
        out << "null";
    }
    out << "\n  },\n";

    out << "  \"checkpoint_provenance\": {\n"
           "    \"diff_ckpt\": "
        << (g_fp_failure_context.diff_ckpt ? "true" : "false") << ",\n"
           "    \"restore_mode\": "
        << (g_fp_failure_context.restore_mode ? "true" : "false") << ",\n"
           "    \"restore_fp_mode\": "
        << (g_fp_failure_context.restore_fp_mode ? "true" : "false") << ",\n"
           "    \"max_insns\": " << g_fp_failure_context.max_insns << ",\n"
           "    \"ckpt_every\": " << g_fp_failure_context.ckpt_every << ",\n"
           "    \"next_ckpt_seq\": " << g_fp_failure_context.next_ckpt_seq
        << ",\n"
           "    \"base\": " << g_fp_failure_context.base << ",\n"
           "    \"image\": ";
    json_string(out, g_fp_failure_context.image);
    out << ",\n    \"checkpoint_dir\": ";
    json_string(out, g_fp_failure_context.ckpt_dir);
    out << ",\n    \"monitor_path\": ";
    json_string(out, g_fp_failure_context.monitor_path);
    out << ",\n    \"ram_path\": ";
    json_string(out, g_fp_failure_context.ram_path);
    out << ",\n    \"restore_arch_path\": ";
    json_string(out, g_fp_failure_context.restore_arch_path);
    out << ",\n    \"restore_sys_path\": ";
    json_string(out, g_fp_failure_context.restore_sys_path);
    out << ",\n    \"restore_fp_path\": ";
    json_string(out, g_fp_failure_context.restore_fp_path);
    out << "\n  },\n";

    write_window_records_json(out, seq, pre, dut_packet, qemu_commit);
    out << "  \"errors\": [";
    for (size_t i = 0; i < errors.size(); i++) {
        out << (i == 0 ? "\n    " : ",\n    ");
        json_string(out, errors[i]);
    }
    out << (errors.empty() ? "]\n" : "\n  ]\n");
    out << "}\n";
    out.close();
    if (!out) {
        fprintf(stderr, "写入 FP 失败诊断时发生 I/O 错误: %s\n", path.c_str());
        return false;
    }
    fprintf(stderr, "FP 失败诊断已写入 %s\n", path.c_str());
    return true;
}

std::string shadow_vs_qemu(const ShadowState &s, const lcvex_state &q) {
    std::string out;
    for (int i = 0; i < 31; i++) {
        if (s.x[i] != q.x[i]) {
            char buf[128];
            snprintf(buf, sizeof(buf),
                     "x%d DUT=0x%016llx QEMU=0x%016llx",
                     i, (unsigned long long)s.x[i],
                     (unsigned long long)q.x[i]);
            out += buf;
            out += "\n";
        }
    }
    if (s.sp != q.sp) {
        char buf[128];
        snprintf(buf, sizeof(buf),
                 "sp DUT=0x%016llx QEMU=0x%016llx",
                 (unsigned long long)s.sp, (unsigned long long)q.sp);
        out += buf;
        out += "\n";
    }
    if (s.nzcv != q.nzcv) {
        char buf[128];
        snprintf(buf, sizeof(buf), "nzcv DUT=0x%x QEMU=0x%x",
                 s.nzcv, q.nzcv);
        out += buf;
        out += "\n";
    }
    if (s.pc != q.next_pc) {
        char buf[128];
        snprintf(buf, sizeof(buf),
                 "next_pc DUT=0x%016llx QEMU=0x%016llx",
                 (unsigned long long)s.pc,
                 (unsigned long long)q.next_pc);
        out += buf;
        out += "\n";
    }
    return out;
}

void dump_failure(const std::string &path, uint64_t seq,
                  const lcvex_pre *pre, const CommitPacket *pkt,
                  const lcvex_commit *cm, const lcvex_discon *dc,
                  const std::string &note) {
    std::ofstream f(path);
    f << "note: " << note << "\n";
    f << "seq=" << seq << "\n";
    if (dc != nullptr) {
        f << "DISCON kind=" << dc->kind << " from_pc=0x" << std::hex
          << dc->pc << " to_pc=0x" << dc->data << "\n";
    }
    if (pre != nullptr) {
        f << "PRE pc=0x" << std::hex << pre->pre.pc << " insn=0x"
          << pre->pre.insn << " next_pc=0x" << pre->pre.next_pc << "\n";
        for (int i = 0; i < 31; i++) {
            f << "PRE x" << std::dec << i << "=0x" << std::hex
              << pre->pre.x[i] << "\n";
        }
        f << "PRE sp=0x" << std::hex << pre->pre.sp
          << " nzcv=0x" << std::hex << pre->pre.nzcv << "\n";
    }
    if (pkt != nullptr) {
        f << "DUT commit pc=0x" << std::hex << pkt->pc << " insn=0x"
          << pkt->insn << " next_pc=0x" << pkt->next_pc << "\n";
        f << "DUT gpr_we=" << pkt->gpr_we << " rd=" << (unsigned)pkt->gpr_rd
          << " wdata=0x" << std::hex << pkt->gpr_wdata << "\n";
        f << "DUT sp_we=" << pkt->sp_we << " wdata=0x" << std::hex
          << pkt->sp_wdata << " nzcv_we=" << pkt->nzcv_we
          << " nzcv=0x" << std::hex << (unsigned)pkt->nzcv << "\n";
        if (pkt->mem_we) {
            f << "DUT store addr=0x" << std::hex << pkt->mem_addr
              << " data=0x" << pkt->mem_wdata
              << " strb=0x" << std::hex << (unsigned)pkt->mem_strb << "\n";
        }
        if (pkt->exc_valid) {
            f << "DUT exc_valid=1 exc_code=0x" << std::hex
              << pkt->exc_code << "\n";
            f << "DUT exc_esr=0x" << std::hex << pkt->exc_esr
              << " exc_far=0x" << pkt->exc_far << "\n";
        }
        if (pkt->mon_we) {
            f << "DUT mon_we=1 valid=" << pkt->mon_valid
              << " addr=0x" << std::hex << pkt->mon_addr
              << " data=0x" << pkt->mon_data
              << " data2=0x" << pkt->mon_data2 << "\n";
        }
    }
    if (cm != nullptr) {
        f << "QEMU post pc=0x" << std::hex << cm->post.pc << " insn=0x"
          << cm->post.insn << " next_pc=0x" << cm->post.next_pc << "\n";
        for (int i = 0; i < 31; i++) {
            f << "QEMU post x" << std::dec << i << "=0x" << std::hex
              << cm->post.x[i] << "\n";
        }
        f << "QEMU post sp=0x" << std::hex << cm->post.sp
          << " nzcv=0x" << std::hex << cm->post.nzcv << "\n";
        for (uint32_t i = 0; i < cm->store_count && i < LCVEX_MAX_STORES;
             i++) {
            f << "QEMU store addr=0x" << std::hex << cm->stores[i].addr
              << " data=0x" << cm->stores[i].data
              << " strb=0x" << std::hex << (unsigned)cm->stores[i].strb
              << "\n";
        }
        if (cm->exc_valid) {
            f << "QEMU exc_valid=1 exc_code=0x" << std::hex
              << cm->exc_code << "\n";
            f << "QEMU exc_esr=0x" << std::hex << cm->exc_esr
              << " exc_far=0x" << cm->exc_far << "\n";
        }
        if (cm->mon_we) {
            f << "QEMU mon_we=1 valid=" << cm->mon_valid
              << " addr=0x" << std::hex << cm->mon_addr
              << " data=0x" << cm->mon_data
              << " data2=0x" << cm->mon_data2 << "\n";
        }
    }
    if (g_failure_fp_valid) {
        f << "FP raw state (little-endian halves):\n";
        if (!g_failure_fp_first_mismatch.empty()) {
            f << "first_fp_raw_mismatch: " << g_failure_fp_first_mismatch
              << "\n";
        }
        f << "DUT fpcr=0x" << std::hex << g_failure_dut_fp.fpcr
          << " fpsr=0x" << g_failure_dut_fp.fpsr << "\n";
        f << "QEMU fpcr=0x" << std::hex << g_failure_qemu_fp.fpcr
          << " fpsr=0x" << g_failure_qemu_fp.fpsr << "\n";
        for (unsigned i = 0; i < 32; i++) {
            f << "DUT V" << std::dec << i << "=0x" << std::hex
              << std::setfill('0') << std::setw(16)
              << g_failure_dut_fp.v[i].hi << std::setw(16)
              << g_failure_dut_fp.v[i].lo
              << std::setfill(' ') << "\n";
            f << "QEMU V" << std::dec << i << "=0x" << std::hex
              << std::setfill('0') << std::setw(16)
              << g_failure_qemu_fp.v[i].hi << std::setw(16)
              << g_failure_qemu_fp.v[i].lo
              << std::setfill(' ') << "\n";
        }
    }
    f << "recent_window:\n";
    for (const auto &r : g_window) {
        f << (r.ok ? "  ok" : "  !!") << " seq=" << std::dec << r.seq
          << " pre_pc=0x" << std::hex << r.pre_pc
          << " dut_pc=0x" << r.dut_pc << " qemu_pc=0x" << r.qemu_pc
          << " dut_next=0x" << r.dut_next_pc
          << " qemu_next=0x" << r.qemu_next_pc << "\n";
    }
    f << "errors:\n";
    for (const auto &e : g_errors) {
        f << "ERR: " << e << "\n";
    }
    f.close();
    fprintf(stderr, "失败诊断已写入 %s\n", path.c_str());
}

void append_pipeline_debug(const std::string &path, const VerilatorDut &dut) {
    if (FILE *df = fopen(path.c_str(), "a")) {
        dut.dump_pipeline_debug(df);
        fclose(df);
    }
}

static bool protocol_fp_commit_length_valid(const uint8_t *payload,
                                            size_t plen) {
    if (plen < LCVEX_FP_COMMIT_HEADER_BYTES) {
        return false;
    }
    uint32_t flags = 0;
    uint32_t v_mask = 0;
    memcpy(&flags, payload, sizeof(flags));
    memcpy(&v_mask, payload + sizeof(flags), sizeof(v_mask));
    if ((flags & ~UINT32_C(3)) != 0 ||
        __builtin_popcount(v_mask) > LCVEX_FP_MAX_VECTORS) {
        return false;
    }
    const size_t expected = LCVEX_FP_COMMIT_HEADER_BYTES +
                            static_cast<size_t>(__builtin_popcount(v_mask)) *
                                sizeof(lcvex_v128);
    return plen == expected && expected <= LCVEX_FP_COMMIT_MAX_BYTES;
}

static bool protocol_payload_length_valid(uint16_t type,
                                          const uint8_t *payload,
                                          size_t plen) {
    size_t expected = 0;
    switch (type) {
    case LCVEX_MSG_HELLO: expected = sizeof(lcvex_hello); break;
    case LCVEX_MSG_CONFIG: expected = sizeof(lcvex_config); break;
    case LCVEX_MSG_INIT: expected = sizeof(lcvex_state); break;
    case LCVEX_MSG_PRE: expected = sizeof(lcvex_pre); break;
    case LCVEX_MSG_GO: expected = 0; break;
    case LCVEX_MSG_COMMIT: expected = sizeof(lcvex_commit); break;
    case LCVEX_MSG_ACK: expected = sizeof(lcvex_ack); break;
    case LCVEX_MSG_DISCON: expected = sizeof(lcvex_discon); break;
    case LCVEX_MSG_STOP: expected = 0; break;
    case LCVEX_MSG_EXIT: expected = sizeof(lcvex_exit); break;
    case LCVEX_MSG_CKPT_REQ: expected = sizeof(lcvex_ckpt_req); break;
    case LCVEX_MSG_CKPT_READY: expected = sizeof(lcvex_ckpt_ready); break;
    case LCVEX_MSG_ASYNC: expected = sizeof(lcvex_commit); break;
    case LCVEX_MSG_WAIT: expected = 0; break;
    case LCVEX_MSG_WAIT_RESUME: expected = sizeof(lcvex_wait_resume); break;
    case LCVEX_MSG_FP_INIT: expected = sizeof(lcvex_fp_state_v1); break;
    case LCVEX_MSG_FP_COMMIT:
        return protocol_fp_commit_length_valid(payload, plen);
    case LCVEX_MSG_P7_REJECT: expected = sizeof(lcvex_p7_reject); break;
    default: return false;
    }
    return plen == expected;
}

/* 返回：1=成功，0=对端关闭(EOF)，-1=超时/协议/IO 错误。所有
 * SOCK_SEQPACKET 接收均同时校验 header 声明长度和实际 datagram 长度。 */
int recv_msg(int fd, lcvex_msg_header *hdr, void *payload, size_t cap) {
    uint8_t buf[4096];
    ssize_t n = recv(fd, buf, sizeof(buf), 0);
    if (n == 0) {
        return 0;  /* EOF */
    }
    if (n < 0) {
        if (errno == EAGAIN || errno == EWOULDBLOCK) {
            return -1;  /* 超时 */
        }
        perror("recv");
        return -1;
    }
    if ((size_t)n < sizeof(*hdr)) {
        fprintf(stderr, "协议错误：消息过短 %zd\n", n);
        return -1;
    }
    memcpy(hdr, buf, sizeof(*hdr));
    if (hdr->magic != LCVEX_MSG_MAGIC || hdr->version != LCVEX_MSG_VERSION) {
        fprintf(stderr, "协议错误：magic=0x%x version=%u\n",
                hdr->magic, hdr->version);
        return -1;
    }
    if (hdr->flags != 0 || hdr->payload_len !=
            static_cast<uint32_t>((size_t)n - sizeof(*hdr)) ||
        hdr->payload_len > cap ||
        !protocol_payload_length_valid(hdr->type, buf + sizeof(*hdr),
                                       hdr->payload_len)) {
        fprintf(stderr, "协议错误：payload_len=%u 超过容量 %zu\n",
                hdr->payload_len, cap);
        return -1;
    }
    if (hdr->payload_len > 0) {
        memcpy(payload, buf + sizeof(*hdr), hdr->payload_len);
    }
    return 1;
}

bool send_msg(int fd, uint16_t type, uint64_t seq, const void *payload,
              uint32_t plen) {
    lcvex_msg_header hdr;
    uint8_t buf[4096];
    if (!protocol_payload_length_valid(type,
                                       static_cast<const uint8_t *>(payload),
                                       plen)) {
        fprintf(stderr, "协议错误：发送 type=%u 的 payload_len=%u 非法\n",
                type, plen);
        return false;
    }
    memset(&hdr, 0, sizeof(hdr));
    hdr.magic = LCVEX_MSG_MAGIC;
    hdr.version = LCVEX_MSG_VERSION;
    hdr.type = type;
    hdr.payload_len = plen;
    hdr.seq = seq;
    size_t total = lcvex_msg_encode(&hdr, payload, buf, sizeof(buf));
    if (total == 0) {
        return false;
    }
    return send(fd, buf, total, MSG_NOSIGNAL) == (ssize_t)total;
}

void set_timeout(int fd, int ms) {
    timeval tv = {};
    tv.tv_sec = ms / 1000;
    tv.tv_usec = (ms % 1000) * 1000;
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
}

// ---- P1 批量 trace 回放（不运行 QEMU：固定运行轨迹逐条比较）----
// trace 行格式（lcvex_difftest.so trace 模式，gzip 或明文）：
//   commit pc=.. insn=.. disas=".." x0=.. .. x30=.. sp=.. next_pc=..
//   nzcv=.. exc_valid=.. [exc_code=.. exc_esr=.. exc_far=..]
//   mon_we=.. mon_valid=.. mon_addr=.. mon_data=.. stores=N
//   s0_addr=.. s0_data=.. s0_size=.. ..
static bool find_u64(const char *line, const char *key, uint64_t *out)
{
    const char *p = strstr(line, key);
    if (!p) {
        return false;
    }
    /* key 形如 "pc=0x"，其后是纯十六进制数字（无 0x 前缀），
     * 必须显式 base=16：base=0 会把前导零按八进制解析。 */
    *out = strtoull(p + strlen(key), nullptr, 16);
    return true;
}

static bool find_u32(const char *line, const char *key, uint32_t *out)
{
    const char *p = strstr(line, key);
    if (!p) {
        return false;
    }
    *out = (uint32_t)strtoul(p + strlen(key), nullptr, 16);
    return true;
}

static bool parse_trace_commit(const std::string &line, lcvex_commit *cm)
{
    memset(cm, 0, sizeof(*cm));
    const char *p = line.c_str();
    if (!find_u64(p, "pc=0x", &cm->post.pc)) {
        return false;
    }
    find_u32(p, "insn=0x", &cm->post.insn);
    for (int i = 0; i < 31; i++) {
        char key[32];
        snprintf(key, sizeof(key), "x%d=0x", i);
        find_u64(p, key, &cm->post.x[i]);
    }
    find_u64(p, "sp=0x", &cm->post.sp);
    find_u64(p, "next_pc=0x", &cm->post.next_pc);
    find_u32(p, "nzcv=0x", &cm->post.nzcv);
    uint32_t ev = 0;
    find_u32(p, "exc_valid=", &ev);
    cm->exc_valid = (uint8_t)ev;
    find_u32(p, "exc_code=0x", &cm->exc_code);
    find_u32(p, "exc_esr=0x", &cm->exc_esr);
    find_u64(p, "exc_far=0x", &cm->exc_far);
    find_u32(p, "mon_we=", &ev);
    cm->mon_we = (uint8_t)ev;
    find_u32(p, "mon_valid=", &ev);
    cm->mon_valid = (uint8_t)ev;
    find_u64(p, "mon_addr=0x", &cm->mon_addr);
    find_u64(p, "mon_data=0x", &cm->mon_data);
    find_u64(p, "mon_data2=0x", &cm->mon_data2);
    uint32_t nstores = 0;
    find_u32(p, "stores=", &nstores);
    cm->store_count = nstores;
    for (uint32_t i = 0; i < nstores && i < LCVEX_MAX_STORES; i++) {
        char key[32];
        uint32_t sz = 0;
        snprintf(key, sizeof(key), "s%u_addr=0x", i);
        find_u64(p, key, &cm->stores[i].addr);
        snprintf(key, sizeof(key), "s%u_data=0x", i);
        find_u64(p, key, &cm->stores[i].data);
        snprintf(key, sizeof(key), "s%u_size=", i);
        find_u32(p, key, &sz);
        cm->stores[i].strb = (uint8_t)((1u << sz) - 1);
    }
    return true;
}

static int replay_trace(const std::string &trace_path, VerilatorDut &dut,
                        uint64_t skip_insns, uint64_t max_cycles_per_insn,
                        uint64_t max_insns,
                        const std::string &dump_path)
{
    FILE *fp = nullptr;
    gzFile gz = nullptr;
    unsigned char magic[2] = {0, 0};
    {
        FILE *probe = fopen(trace_path.c_str(), "rb");
        if (!probe) {
            fprintf(stderr, "无法打开 trace 文件 %s\n", trace_path.c_str());
            return 1;
        }
        size_t got = fread(magic, 1, 2, probe);
        fclose(probe);
        if (got == 2 && magic[0] == 0x1f && magic[1] == 0x8b) {
            gz = gzopen(trace_path.c_str(), "rb");
        } else {
            fp = fopen(trace_path.c_str(), "r");
        }
    }
    if (!gz && !fp) {
        fprintf(stderr, "无法打开 trace 文件 %s\n", trace_path.c_str());
        return 1;
    }

    ShadowState shadow;
    shadow.nzcv = 4;   /* DUT/QEMU 复位 nzcv（Z=1），与 socket INIT 一致 */
    uint64_t seq = 0;
    char buf[16384];
    bool shadow_from_init = false;
    /* 切片快进：DUT 先执行 skip 条（不比较；状态自然与 trace 前段一致），
     * 从切片起点开始逐条比较。 */
    for (uint64_t i = 0; i < skip_insns; i++) {
        CommitPacket pkt;
        if (!dut.step_until_commit(max_cycles_per_insn, &pkt)) {
            fprintf(stderr, "DUT 快进超时（skip seq=%llu）\n",
                    (unsigned long long)i);
            return 1;
        }
        apply_commit(&shadow, pkt);   /* shadow 与 DUT 同步推进 */
    }
    shadow_from_init = (skip_insns > 0);
    for (;;) {
        if (max_insns != 0 && seq >= max_insns) {
            break;
        }
        const char *r = gz ? gzgets(gz, buf, sizeof(buf))
                           : fgets(buf, sizeof(buf), fp);
        if (!r) {
            break;
        }
        std::string line(buf);
        if (line.rfind("#", 0) == 0) {
            continue;
        }
        if (line.rfind("init ", 0) == 0) {
            /* 用 trace 初始状态初始化 shadow（与 socket 模式 INIT 一致） */
            if (!shadow_from_init) {
                lcvex_commit cm;
                if (parse_trace_commit(line, &cm)) {
                    shadow = ShadowState{};
                    for (int i = 0; i < 31; i++) {
                        shadow.x[i] = cm.post.x[i];
                    }
                    shadow.sp = cm.post.sp;
                    shadow.nzcv = (uint8_t)cm.post.nzcv;
                    shadow.pc = cm.post.pc;
                }
            }
            continue;
        }
        if (line.rfind("commit ", 0) != 0) {
            continue;
        }
        lcvex_commit cm;
        if (!parse_trace_commit(line, &cm)) {
            fprintf(stderr, "trace 行解析失败（seq=%llu）：%.120s\n",
                    (unsigned long long)seq, buf);
            return 1;
        }
        CommitPacket pkt;
        if (!dut.step_until_commit(max_cycles_per_insn, &pkt)) {
            fprintf(stderr, "DUT 超时未提交（seq=%llu pc=0x%llx）\n",
                    (unsigned long long)seq,
                    (unsigned long long)cm.post.pc);
            dump_failure(dump_path, seq, nullptr, nullptr, &cm, nullptr,
                         "DUT 超过 max_cycles_per_insn 未提交");
            return 1;
        }
        g_errors.clear();
        apply_commit(&shadow, pkt);
        check(cm.post.pc == pkt.pc, "trace pc 与 DUT 不一致");
        if (!cm.exc_valid) {
            check(cm.post.insn == pkt.insn, "trace insn 与 DUT 不一致");
        }
        std::string diffs = shadow_vs_qemu(shadow, cm.post);
        if (!diffs.empty()) {
            size_t pos = 0;
            while ((pos = diffs.find('\n')) != std::string::npos) {
                g_errors.push_back(diffs.substr(0, pos));
                diffs.erase(0, pos + 1);
            }
        }
        // 内存写列表（DUT mem/mem2 vs trace stores）
        std::vector<std::string> dut_stores, qemu_stores;
        if (pkt.mem_we) {
            int size = 0;
            for (int b = 0; b < 8; b++) {
                if (pkt.mem_strb & (1u << b)) size++;
            }
            char b[128];
            snprintf(b, sizeof(b), "%llx/%llx/%d",
                     (unsigned long long)pkt.mem_addr,
                     (unsigned long long)pkt.mem_wdata, size);
            dut_stores.push_back(b);
        }
        if (pkt.mem2_we) {
            int size = 0;
            for (int b = 0; b < 8; b++) {
                if (pkt.mem2_strb & (1u << b)) size++;
            }
            char b[128];
            snprintf(b, sizeof(b), "%llx/%llx/%d",
                     (unsigned long long)pkt.mem2_addr,
                     (unsigned long long)pkt.mem2_wdata, size);
            dut_stores.push_back(b);
        }
        for (uint32_t i = 0; i < cm.store_count && i < LCVEX_MAX_STORES;
             i++) {
            int size = 0;
            for (int b = 0; b < 8; b++) {
                if (cm.stores[i].strb & (1u << b)) size++;
            }
            char b[128];
            snprintf(b, sizeof(b), "%llx/%llx/%d",
                     (unsigned long long)cm.stores[i].addr,
                     (unsigned long long)cm.stores[i].data, size);
            qemu_stores.push_back(b);
        }
        check(dut_stores == qemu_stores, "内存写列表不一致");
        check(cm.exc_valid == pkt.exc_valid, "exc_valid 不一致");
        // 回放模式：trace 无 fork step hook（EC/ESR/FAR 不可得），
        // 只比较 exc_valid 与 next_pc（shadow_vs_qemu 已覆盖）。
        check(cm.mon_we == pkt.mon_we, "mon_we 不一致");
        check(!cm.mon_we || cm.mon_valid == pkt.mon_valid,
              "mon_valid 不一致");
        check(!cm.mon_we || !cm.mon_valid ||
              cm.mon_addr == pkt.mon_addr, "mon_addr 不一致");
        check(!cm.mon_we || !cm.mon_valid ||
              cm.mon_data == pkt.mon_data, "mon_data 不一致");
        check(!cm.mon_we || !cm.mon_valid ||
              cm.mon_data2 == pkt.mon_data2, "mon_data2 不一致");

        if (!g_errors.empty()) {
            dump_failure(dump_path, seq, nullptr, &pkt, &cm, nullptr,
                         "trace 回放状态不一致");
            fprintf(stderr, "FAIL: seq=%llu 有 %zu 处不一致\n",
                    (unsigned long long)seq, g_errors.size());
            return 1;
        }
        seq++;
    }
    if (gz) {
        gzclose(gz);
    }
    if (fp) {
        fclose(fp);
    }
    fprintf(stdout, "PASS: trace 回放 %llu 条与 DUT 完全一致（%s）\n",
            (unsigned long long)seq, trace_path.c_str());
    return 0;
}

}  // namespace

int main(int argc, char **argv)
{
    std::string socket_path, image, image2, image3,
                dump_path = "lockstep_fail.txt", trace_path;
    std::string cpu_profile;
    uint64_t skip_insns = 0;
    std::string ckpt_dir;       // 非空时周期保存 QEMU vmstate checkpoint
    uint64_t ckpt_every = 0;    // 每 N 条 OK 提交保存一次（0=禁用）
    std::string monitor_path;   // QEMU HMP unix socket（migrate 触发用）
    std::string ram_path;       // 差分 checkpoint：共享 RAM backend 文件
    bool diff_ckpt = false;
    bool selftest_restore = false;
    std::string selftest_arch_path;
    std::string selftest_ram_path;
    std::string selftest_timer_path;
    std::string selftest_gic_path;
    std::string restore_arch_path;
    std::string restore_ram_path;
    std::string restore_sys_path;
    std::string restore_timer_path;
    std::string restore_gic_path;
    std::string restore_mmio_path;
    std::string restore_fp_path;
    bool restore_mode = false;
    bool fp_required = false;
    bool restore_sys_mode = false;
    bool restore_timer_mode = false;
    bool restore_gic_mode = false;
    bool restore_mmio_mode = false;
    bool restore_fp_mode = false;
    bool restore_smcr_mode = false;
    uint64_t restore_smcr = 0;
    lcvex_state restore_state = {};
    DutSysState restore_sys = {};
    DutTimerState restore_timer = {};
    DutGicState restore_gic = {};
    LcvexMmioFabricState restore_mmio = {};
    FpState restore_fp = {};
    uint64_t selftest_split = 10;
    uint64_t selftest_count = 10;
    uint64_t base = 0x44000000;
    uint64_t base2 = 0x40000000;
    uint64_t base3 = 0x44000000;
    uint64_t init_pc = 0;
    uint64_t boot_dtb = 0;
    uint64_t boot_entry = 0;
    uint64_t max_insns = 0;
    uint64_t max_cycles_per_insn = 1000;
    // WFIT/WFET 在 QEMU icount 下可一次跨过数千至数十万虚拟 ns；普通
    // 指令仍使用严格的小上限，只有 QEMU 已正常退休的等待指令之后才放宽。
    uint64_t max_wait_cycles = 1000000;
    uint64_t progress_every = 1;  // 0=关闭逐提交进度；失败仍完整记录
    int timeout_ms = 30000;
    bool have_max = false;
    const bool debug_wait = getenv("LCVEX_DEBUG_WAIT") != nullptr;

    for (int i = 1; i < argc; i++) {
        std::string a = argv[i];
        auto val = [&](const char *name) -> std::string {
            return (i + 1 < argc) ? argv[++i] : "";
        };
        if (a == "--socket") socket_path = val("--socket");
        else if (a == "--image") image = val("--image");
        else if (a == "--base") base = strtoull(val("--base").c_str(), nullptr, 0);
        else if (a == "--image2") image2 = val("--image2");
        else if (a == "--image2-addr")
            base2 = strtoull(val("--image2-addr").c_str(), nullptr, 0);
        else if (a == "--image3") image3 = val("--image3");
        else if (a == "--image3-addr")
            base3 = strtoull(val("--image3-addr").c_str(), nullptr, 0);
        else if (a == "--boot-dtb")
            boot_dtb = strtoull(val("--boot-dtb").c_str(), nullptr, 0);
        else if (a == "--boot-entry")
            boot_entry = strtoull(val("--boot-entry").c_str(), nullptr, 0);
        else if (a == "--init-pc")
            init_pc = strtoull(val("--init-pc").c_str(), nullptr, 0);
        else if (a == "--max-insns") {
            max_insns = strtoull(val("--max-insns").c_str(), nullptr, 0);
            have_max = true;
        } else if (a == "--max-cycles-per-insn") {
            max_cycles_per_insn =
                strtoull(val("--max-cycles-per-insn").c_str(), nullptr, 0);
        } else if (a == "--max-wait-cycles") {
            max_wait_cycles =
                strtoull(val("--max-wait-cycles").c_str(), nullptr, 0);
        } else if (a == "--progress-every") {
            progress_every =
                strtoull(val("--progress-every").c_str(), nullptr, 0);
        } else if (a == "--timeout-ms") {
            timeout_ms = atoi(val("--timeout-ms").c_str());
        } else if (a == "--dump") dump_path = val("--dump");
        else if (a == "--cpu-profile") cpu_profile = val("--cpu-profile");
        else if (a == "--trace") trace_path = val("--trace");
        else if (a == "--skip") {
            skip_insns = strtoull(val("--skip").c_str(), nullptr, 0);
        } else if (a == "--ckpt-dir") {
            ckpt_dir = val("--ckpt-dir");
        } else if (a == "--ckpt-every") {
            ckpt_every = strtoull(val("--ckpt-every").c_str(), nullptr, 0);
        } else if (a == "--monitor") {
            monitor_path = val("--monitor");
        } else if (a == "--ram-file") {
            ram_path = val("--ram-file");
        } else if (a == "--diff-ckpt") {
            diff_ckpt = true;
        } else if (a == "--selftest-restore") {
            selftest_restore = true;
            image = val("--selftest-restore");
        } else if (a == "--selftest-arch") {
            selftest_arch_path = val("--selftest-arch");
        } else if (a == "--selftest-ram") {
            selftest_ram_path = val("--selftest-ram");
        } else if (a == "--selftest-timer") {
            selftest_timer_path = val("--selftest-timer");
        } else if (a == "--selftest-gic") {
            selftest_gic_path = val("--selftest-gic");
        } else if (a == "--restore-arch") {
            restore_arch_path = val("--restore-arch");
        } else if (a == "--restore-ram") {
            restore_ram_path = val("--restore-ram");
        } else if (a == "--restore-sys") {
            restore_sys_path = val("--restore-sys");
        } else if (a == "--restore-timer") {
            restore_timer_path = val("--restore-timer");
        } else if (a == "--restore-gic") {
            restore_gic_path = val("--restore-gic");
        } else if (a == "--restore-mmio") {
            restore_mmio_path = val("--restore-mmio");
        } else if (a == "--restore-fp") {
            restore_fp_path = val("--restore-fp");
        } else if (a == "--fp-neon") {
            std::string mode = val("--fp-neon");
            if (mode == "required") {
                fp_required = true;
            } else if (mode == "off") {
                fp_required = false;
            } else {
                fprintf(stderr, "--fp-neon 只接受 off|required\n");
                return 2;
            }
        } else if (a == "--restore-smcr") {
            restore_smcr_mode = true;
            restore_smcr = strtoull(val("--restore-smcr").c_str(), nullptr, 0);
        } else if (a == "--split") {
            selftest_split = strtoull(val("--split").c_str(), nullptr, 0);
        } else if (a == "--count") {
            selftest_count = strtoull(val("--count").c_str(), nullptr, 0);
        }
        else {
            fprintf(stderr, "未知参数 %s\n", a.c_str());
            return 2;
        }
    }
    if (selftest_restore) {
        return run_dut_restore_smoke(image, base, selftest_split,
                                     selftest_count);
    }
    if (!selftest_gic_path.empty()) {
        if (selftest_arch_path.empty()) {
            fprintf(stderr, "--selftest-gic 需要同时提供 --selftest-arch\n");
            return 2;
        }
        return run_dut_gic_file_smoke(image, base, selftest_arch_path,
                                      selftest_gic_path, selftest_timer_path,
                                      selftest_count);
    }
    if (!selftest_arch_path.empty()) {
        return run_dut_arch_file_smoke(image, base, selftest_arch_path,
                                       selftest_count, selftest_ram_path,
                                       selftest_timer_path);
    }
    if (!restore_arch_path.empty() || !restore_sys_path.empty() ||
        !restore_timer_path.empty() || !restore_gic_path.empty() ||
        !restore_mmio_path.empty() || !restore_fp_path.empty()) {
        uint64_t ignored_seq = 0;
        if (!restore_ram_path.empty() &&
            (restore_arch_path.empty() ||
             read_arch_state_file(restore_arch_path, &ignored_seq,
                                  &restore_state)) &&
            (restore_sys_path.empty() || read_sys_state_file(restore_sys_path,
                                                               &restore_sys)) &&
            (restore_timer_path.empty() ||
             read_timer_state_file(restore_timer_path, &restore_timer)) &&
            (restore_gic_path.empty() ||
             read_gic_state_file(restore_gic_path, &restore_gic)) &&
            (restore_mmio_path.empty() ||
             read_mmio_state_file(restore_mmio_path, &restore_mmio)) &&
            (restore_fp_path.empty() ||
             read_fp_state_file(restore_fp_path,
                                std::numeric_limits<uint64_t>::max(),
                                &restore_fp)) &&
            (!restore_arch_path.empty() || !restore_sys_path.empty())) {
            restore_mode = true;
            restore_sys_mode = !restore_sys_path.empty();
            restore_timer_mode = !restore_timer_path.empty();
            restore_gic_mode = !restore_gic_path.empty();
            restore_mmio_mode = !restore_mmio_path.empty();
            restore_fp_mode = !restore_fp_path.empty();
            if (restore_sys_mode && restore_arch_path.empty()) {
                restore_state.pc = restore_sys.pc;
                restore_state.next_pc = restore_sys.next_pc;
                memcpy(restore_state.x, restore_sys.x, sizeof(restore_state.x));
                restore_state.sp = restore_sys.sp_el1;
                restore_state.nzcv = restore_sys.nzcv;
            }
        } else {
            fprintf(stderr,
                    "恢复模式需要有效 arch/sys sidecar、--restore-ram，且 timer（如提供）格式正确\n");
            return 2;
        }
    }
    if (fp_required && restore_mode && !restore_fp_mode) {
        fprintf(stderr, "P7 restore 必须提供 --restore-fp（LCVXFP01）\n");
        return 2;
    }
    if (socket_path.empty() && trace_path.empty()) {
        fprintf(stderr,
                "用法: %s --socket PATH [--image FILE [--base ADDR]] "
                "[--image2 FILE --image2-addr ADDR] [--init-pc ADDR] "
                "[--image3 FILE --image3-addr ADDR] "
                "[--boot-dtb ADDR --boot-entry ADDR] "
                "[--max-insns N] [--max-cycles-per-insn N] "
                "[--timeout-ms N] [--dump PATH]\n"
                "       或 %s --trace TRACE --image FILE [--base ADDR] "
                "[--max-insns N] [--dump PATH]\n", argv[0], argv[0]);
        return 2;
    }
    if (diff_ckpt && (ckpt_dir.empty() || monitor_path.empty() ||
                      ram_path.empty())) {
        fprintf(stderr,
                "--diff-ckpt 需要 --ckpt-dir、--monitor、--ram-file\n");
        return 2;
    }

    if (cpu_profile.empty()) {
        const char *profile = getenv("LCVEX_CPU_PROFILE");
        if (profile == nullptr || *profile == '\0') profile = getenv("QEMU_CPU");
        cpu_profile = (profile != nullptr && *profile != '\0')
                          ? profile
                          : "cortex-a76,has_el3=false,has_el2=false";
    }
    g_fp_failure_context.cpu_profile = cpu_profile;
    g_fp_failure_context.fp_required = fp_required;
    g_fp_failure_context.restore_mode = restore_mode;
    g_fp_failure_context.restore_fp_mode = restore_fp_mode;
    g_fp_failure_context.max_insns = max_insns;
    g_fp_failure_context.ckpt_every = ckpt_every;
    g_fp_failure_context.diff_ckpt = diff_ckpt;
    g_fp_failure_context.image = image;
    g_fp_failure_context.base = base;
    g_fp_failure_context.ckpt_dir = ckpt_dir;
    g_fp_failure_context.monitor_path = monitor_path;
    g_fp_failure_context.ram_path = ram_path;
    g_fp_failure_context.restore_arch_path = restore_arch_path;
    g_fp_failure_context.restore_sys_path = restore_sys_path;
    g_fp_failure_context.restore_fp_path = restore_fp_path;

    VerilatorDut dut;
    dut.reset_and_load(image, base, image2, base2, image3, base3,
                       boot_dtb, boot_entry);
    if (restore_mode) {
        dut.load_ram_file(restore_ram_path);
        if (restore_sys_mode) {
            dut.restore_sys_state(restore_sys,
                                  restore_timer_mode ? &restore_timer : nullptr,
                                  restore_fp_mode ? &restore_fp : nullptr);
        } else {
            dut.restore_arch_state(restore_state,
                                   restore_timer_mode ? &restore_timer : nullptr,
                                   restore_fp_mode ? &restore_fp : nullptr);
        }
        if (restore_gic_mode) {
            dut.restore_gic_state(restore_gic);
        }
        if (restore_mmio_mode) {
            dut.restore_mmio_fabric_state(restore_mmio);
        }
        if (restore_smcr_mode) {
            dut.restore_smcr_control(restore_smcr);
        }
    }
    if (!trace_path.empty()) {
        return replay_trace(trace_path, dut, skip_insns,
                            max_cycles_per_insn, max_insns, dump_path);
    }

    int listen_fd = socket(AF_UNIX, SOCK_SEQPACKET, 0);
    if (listen_fd < 0) {
        perror("socket");
        return 2;
    }
    sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    snprintf(addr.sun_path, sizeof(addr.sun_path), "%s",
             socket_path.c_str());
    unlink(socket_path.c_str());
    if (bind(listen_fd, reinterpret_cast<sockaddr *>(&addr), sizeof(addr)) < 0 ||
        listen(listen_fd, 1) < 0) {
        perror("bind/listen");
        return 2;
    }
    fprintf(stderr, "协调器等待 QEMU 连接：%s\n", socket_path.c_str());
    int fd = accept(listen_fd, nullptr, nullptr);
    if (fd < 0) {
        perror("accept");
        return 2;
    }
    set_timeout(fd, timeout_ms);
    close(listen_fd);
    unlink(socket_path.c_str());

    // HELLO / CONFIG
    lcvex_msg_header hdr;
    lcvex_hello hello;
    if (!recv_msg(fd, &hdr, &hello, sizeof(hello)) ||
        hdr.type != LCVEX_MSG_HELLO || hdr.seq != 0) {
        fprintf(stderr, "握手失败：未收到 HELLO\n");
        return 1;
    }
    if (hello.arch != 1 || hello.vcpu_count != 1) {
        fprintf(stderr, "握手失败：arch=%u vcpu=%u\n",
                hello.arch, hello.vcpu_count);
        return 1;
    }
    lcvex_config cfg = {};
    cfg.vcpu_count = 1;
    cfg.max_insns = max_insns;
    cfg.timeout_ms = timeout_ms;
    cfg.state_mask = 0xFFFF & ~LCVEX_CFG_CAP_FP_NEON;
    if (fp_required && hello.api_version != 2) {
        lcvex_p7_reject reject = {
            LCVEX_P7_REJECT_NO_CAP, LCVEX_FP_VECTOR_BYTES};
        fprintf(stderr,
                "P7 required 拒绝 api_version=%u（期望 2），不读取 INIT\n",
                hello.api_version);
        send_msg(fd, LCVEX_MSG_P7_REJECT, 0, &reject, sizeof(reject));
        return 1;
    }
    if (fp_required) {
        cfg.state_mask |= LCVEX_CFG_CAP_FP_NEON;
    }
    g_fp_failure_context.hello_api_version = hello.api_version;
    g_fp_failure_context.config_state_mask = cfg.state_mask;
    if (!send_msg(fd, LCVEX_MSG_CONFIG, 0, &cfg, sizeof(cfg))) {
        return 1;
    }

    ShadowState shadow;
    bool shadow_ready = false;
    CommitPacket last_pkt;
    lcvex_pre last_pre;
    bool have_pkt = false;
    bool have_pre = false;
    uint64_t last_pre_seq = 0;
    uint64_t expected_pre_seq = 0;
    uint64_t insns = 0;
    bool fp_ready = false;
    FpState qemu_fp_shadow = {};
    FpState dut_fp_shadow = {};
    lcvex_commit pending_qemu_commit = {};
    uint64_t next_ckpt_seq = ckpt_every;
    g_fp_failure_context.next_ckpt_seq = next_ckpt_seq;
    // QEMU 已正常退休的等待指令；WAIT 消息表明 helper 真正进入 idle。
    // 若无 WAIT 而直接收到 PRE，QEMU 是 cpu_has_work() 立即返回；WFIT/WFET
    // 仅在有 WAIT 时才应让 DUT 推进虚拟时间到 timeout。
    bool qemu_wait_committed = false;
    bool qemu_wait_halted = false;
    bool qemu_wait_count_valid = false;
    uint64_t qemu_wait_cntvct = 0;

    for (;;) {
        lcvex_commit cm;  // 最大载荷类型，所有消息都收进这里
        int r = recv_msg(fd, &hdr, &cm, sizeof(cm));
        if (r == 0) {
            std::string note = "连接中断：QEMU 关闭连接（EOF）";
            fprintf(stderr, "%s，已提交 %llu 条\n", note.c_str(),
                    (unsigned long long)insns);
            dump_failure(dump_path, insns, have_pre ? &last_pre : nullptr,
                         have_pkt ? &last_pkt : nullptr, nullptr,
                         nullptr, note);
            append_pipeline_debug(dump_path, dut);
            return 1;
        }
        if (r < 0) {
            std::string note = "连接中断：等待消息超时（" +
                               std::to_string(timeout_ms) + " ms）";
            fprintf(stderr, "%s 或 IO 错误\n", note.c_str());
            dump_failure(dump_path, insns, have_pre ? &last_pre : nullptr,
                         have_pkt ? &last_pkt : nullptr, nullptr,
                         nullptr, note);
            append_pipeline_debug(dump_path, dut);
            return 1;
        }

        if (hdr.type == LCVEX_MSG_INIT) {
            lcvex_state st;
            memcpy(&st, &cm, sizeof(st));
            if (hdr.seq != 0) {
                fprintf(stderr, "协议错误：INIT seq=%llu（期望 0）\n",
                        (unsigned long long)hdr.seq);
                return 1;
            }
            expected_pre_seq = 0;
            // 普通模式检查复位状态；恢复模式检查 checkpoint 的下一条状态。
            uint64_t expect_pc = init_pc ? init_pc : base;
            bool init_ok = false;
            if (restore_mode) {
                init_ok = st.pc == restore_state.next_pc &&
                          st.next_pc == restore_state.next_pc &&
                          st.sp == restore_state.sp &&
                          st.nzcv == restore_state.nzcv;
                for (int i = 0; init_ok && i < 31; i++) {
                    init_ok = st.x[i] == restore_state.x[i];
                }
            } else {
                init_ok = st.pc == expect_pc && st.sp == 0 && st.nzcv == 4;
                for (int i = 0; init_ok && i < 31; i++) {
                    init_ok = st.x[i] == 0;
                }
            }
            if (!init_ok) {
                fprintf(stderr, "INIT 与 DUT 复位不一致：pc=0x%llx "
                        "（期望 0x%llx）sp=0x%llx nzcv=0x%x restore=%d\n",
                        (unsigned long long)st.pc,
                        (unsigned long long)(restore_mode
                                                 ? restore_state.next_pc
                                                 : expect_pc),
                        (unsigned long long)st.sp, st.nzcv,
                        restore_mode ? 1 : 0);
                return 1;
            }
            shadow = ShadowState{};
            for (int i = 0; i < 31; i++) {
                shadow.x[i] = st.x[i];
            }
            shadow.sp = st.sp;
            shadow.nzcv = st.nzcv;
            shadow.pc = st.pc;
            shadow_ready = true;
            fp_ready = !fp_required;
            g_fp_failure_context.fp_ready = fp_ready;
            continue;
        }

        if (hdr.type == LCVEX_MSG_FP_INIT) {
            FpState init_fp = {};
            FpState expected_fp = {};
            FpState dut_fp = dut.read_fp_state();
            if (restore_fp_mode) {
                expected_fp = restore_fp;
            }
            g_errors.clear();
            if (!fp_required || fp_ready || hdr.seq != 0 ||
                !parse_fp_init(reinterpret_cast<const uint8_t *>(&cm),
                               hdr.payload_len, &init_fp)) {
                g_failure_fp_valid = true;
                g_failure_qemu_fp = init_fp;
                g_failure_dut_fp = dut_fp;
                g_failure_fp_first_mismatch =
                    "FP_INIT protocol/state mismatch";
                g_errors.push_back(g_failure_fp_first_mismatch);
                fprintf(stderr, "协议错误：非法 FP_INIT seq=%llu\n",
                        static_cast<unsigned long long>(hdr.seq));
                dump_failure(dump_path, hdr.seq,
                             have_pre ? &last_pre : nullptr,
                             have_pkt ? &last_pkt : nullptr, nullptr, nullptr,
                             "FP_INIT 协议或长度不一致");
                write_fail_fp_json(fp_failure_path(dump_path), "FP_INIT",
                                   hdr.seq, &expected_fp, &dut_fp, &init_fp,
                                   &dut_fp, have_pre ? &last_pre : nullptr,
                                   nullptr, nullptr, g_errors);
                return 1;
            }
            if (!fp_state_equal(init_fp, expected_fp)) {
                g_errors.push_back("FP_INIT 与期望 restore FP state 不一致");
            }
            if (!fp_state_equal(init_fp, dut_fp)) {
                g_errors.push_back("FP_INIT 与 DUT FP state 不一致");
            }
            if (!g_errors.empty()) {
                g_failure_fp_valid = true;
                g_failure_qemu_fp = init_fp;
                g_failure_dut_fp = dut_fp;
                g_failure_fp_first_mismatch =
                    first_fp_raw_mismatch(expected_fp, init_fp,
                                          "expected", "QEMU");
                if (g_failure_fp_first_mismatch.empty()) {
                    g_failure_fp_first_mismatch =
                        first_fp_raw_mismatch(init_fp, dut_fp,
                                              "QEMU", "DUT");
                }
                if (g_failure_fp_first_mismatch.empty()) {
                    g_failure_fp_first_mismatch = g_errors.front();
                }
                fprintf(stderr, "FP_INIT 与 DUT/restore FP state 不一致\n");
                dump_failure(dump_path, hdr.seq,
                             have_pre ? &last_pre : nullptr,
                             have_pkt ? &last_pkt : nullptr, nullptr, nullptr,
                             "FP_INIT raw state 不一致");
                write_fail_fp_json(fp_failure_path(dump_path), "FP_INIT",
                                   hdr.seq, &expected_fp, &dut_fp, &init_fp,
                                   &dut_fp, have_pre ? &last_pre : nullptr,
                                   nullptr, nullptr, g_errors);
                return 1;
            }
            qemu_fp_shadow = init_fp;
            dut_fp_shadow = dut_fp;
            g_failure_fp_valid = true;
            g_failure_qemu_fp = init_fp;
            g_failure_dut_fp = dut_fp;
            fp_ready = true;
            g_fp_failure_context.fp_ready = true;
            continue;
        }

        /* DISCON/EXIT 可能在 INIT 之前到达（如首条指令即触发异常），
         * 必须先于 shadow_ready 检查处理。 */
        if (hdr.type == LCVEX_MSG_DISCON) {
            lcvex_discon dc;
            memcpy(&dc, &cm, sizeof(dc));
            if (dc.kind == LCVEX_DISCON_GUEST_RESET) {
                fprintf(stderr,
                        "访客请求复位/关机（PSCI fn=0x%llx）at pc=0x%llx "
                        "seq=%llu；窗口以该事件终止，需人工确认原因\n",
                        (unsigned long long)dc.data,
                        (unsigned long long)dc.pc,
                        (unsigned long long)hdr.seq);
                dump_failure(dump_path, hdr.seq, nullptr, nullptr, nullptr,
                             &dc,
                             "访客请求复位/关机（PSCI SYSTEM_RESET/"
                             "SYSTEM_OFF），窗口终止");
                return 3;
            }
            fprintf(stderr,
                    "QEMU 上报 DISCON（PC discontinuity，P2 阶段视为失败）："
                    "kind=%u from=0x%llx to=0x%llx\n",
                    dc.kind, (unsigned long long)dc.pc,
                    (unsigned long long)dc.data);
            dump_failure(dump_path, hdr.seq, nullptr, nullptr, nullptr, &dc,
                         "DISCON（P2 阶段视为失败，见 Q5）");
            return 1;
        }

        if (hdr.type == LCVEX_MSG_EXIT) {
            lcvex_exit ex;
            memcpy(&ex, &cm, sizeof(ex));
            fprintf(stderr,
                    "QEMU 提前退出：reason=%u insns_committed=%llu "
                    "（max_insns=%llu 未达到）\n",
                    ex.reason, (unsigned long long)ex.insns_committed,
                    (unsigned long long)max_insns);
            dump_failure(dump_path, hdr.seq, nullptr, nullptr, nullptr,
                         nullptr, "QEMU 提前退出（EXIT）");
            return 1;
        }

        if (hdr.type == LCVEX_MSG_ASYNC) {
            lcvex_commit async_cm;
            memcpy(&async_cm, &cm, sizeof(async_cm));
            if (!shadow_ready || async_cm.exc_code != 0x40u ||
                hdr.seq != last_pre_seq) {
                fprintf(stderr, "协议错误：非法 ASYNC IRQ 提交 seq=%llu\n",
                        (unsigned long long)hdr.seq);
                return 1;
            }
            CommitPacket pkt;
            uint64_t async_budget = qemu_wait_committed ? max_wait_cycles
                                                        : max_cycles_per_insn;
            if (!dut.step_until_commit(async_budget, &pkt)) {
                fprintf(stderr, "DUT 未产生 WFI 唤醒 IRQ 提交\n");
                return 1;
            }
            g_errors.clear();
            check(pkt.pc == async_cm.post.pc, "ASYNC pc 与 DUT 不一致");
            check(pkt.next_pc == async_cm.post.next_pc,
                  "ASYNC next_pc 与 DUT 不一致");
            check(pkt.exc_valid && pkt.exc_code == 0x40u,
                  "ASYNC IRQ packet 与 DUT 不一致");
            apply_commit(&shadow, pkt);
            std::string async_diffs = shadow_vs_qemu(shadow, async_cm.post);
            if (!async_diffs.empty()) {
                size_t pos = 0;
                while ((pos = async_diffs.find('\n')) != std::string::npos) {
                    g_errors.push_back(async_diffs.substr(0, pos));
                    async_diffs.erase(0, pos + 1);
                }
            }
            lcvex_ack async_ack = {};
            if (!g_errors.empty()) {
                async_ack.status = LCVEX_ACK_FAIL;
                std::string msg;
                for (const auto &e : g_errors) {
                    msg += e;
                    msg += "; ";
                }
                snprintf(async_ack.detail, sizeof(async_ack.detail), "%s",
                         msg.c_str());
                send_msg(fd, LCVEX_MSG_ACK, hdr.seq, &async_ack,
                         sizeof(async_ack));
                send_msg(fd, LCVEX_MSG_STOP, hdr.seq, nullptr, 0);
                return 1;
            }
            send_msg(fd, LCVEX_MSG_ACK, hdr.seq, &async_ack,
                     sizeof(async_ack));
            qemu_wait_committed = false;
            qemu_wait_halted = false;
            qemu_wait_count_valid = false;
            continue;
        }

        if (hdr.type == LCVEX_MSG_WAIT) {
            if (!shadow_ready || !qemu_wait_committed ||
                hdr.seq != last_pre_seq || hdr.payload_len != 0) {
                fprintf(stderr, "协议错误：非法 WAIT seq=%llu\n",
                        (unsigned long long)hdr.seq);
                return 1;
            }
            qemu_wait_halted = true;
            if (debug_wait) {
                fprintf(stderr, "wait: QEMU idle seq=%llu\n",
                        (unsigned long long)hdr.seq);
            }
            continue;
        }

        if (hdr.type == LCVEX_MSG_WAIT_RESUME) {
            lcvex_wait_resume wr = {};
            memcpy(&wr, &cm, sizeof(wr));
            if (!shadow_ready || !qemu_wait_committed || !qemu_wait_halted ||
                hdr.seq != last_pre_seq ||
                hdr.payload_len != sizeof(wr)) {
                fprintf(stderr, "协议错误：非法 WAIT_RESUME seq=%llu\n",
                        (unsigned long long)hdr.seq);
                return 1;
            }
            qemu_wait_cntvct = wr.cntvct;
            qemu_wait_count_valid = true;
            if (debug_wait) {
                fprintf(stderr, "wait: QEMU resume seq=%llu cntvct=%llu\n",
                        (unsigned long long)hdr.seq,
                        (unsigned long long)wr.cntvct);
            }
            continue;
        }

        if (!shadow_ready) {
            fprintf(stderr, "协议错误：INIT 之前收到 type=%u\n", hdr.type);
            return 1;
        }
        if (fp_required && !fp_ready) {
            fprintf(stderr, "协议错误：P7 FP_INIT 之前收到 type=%u\n",
                    hdr.type);
            return 1;
        }

        if (hdr.type == LCVEX_MSG_PRE) {
            lcvex_pre pre;
            memcpy(&pre, &cm, sizeof(pre));

            if (hdr.seq != expected_pre_seq) {
                fprintf(stderr,
                        "协议错误：PRE seq=%llu（期望 %llu，旧序号/跳号）\n",
                        (unsigned long long)hdr.seq,
                        (unsigned long long)expected_pre_seq);
                return 1;
            }
            g_errors.clear();
            check(pre.pre.pc == shadow.pc, "PRE pc 与 DUT 不一致");
            check(pre.pre.sp == shadow.sp, "PRE sp 与 DUT 不一致");
            check(pre.pre.nzcv == shadow.nzcv, "PRE nzcv 与 DUT 不一致");
            for (int i = 0; i < 31; i++) {
                char buf[64];
                snprintf(buf, sizeof(buf), "PRE x%d 与 DUT 不一致", i);
                check(pre.pre.x[i] == shadow.x[i], buf);
            }
            if (!g_errors.empty()) {
                dump_failure(dump_path, hdr.seq, &pre, nullptr, nullptr,
                             nullptr, "PRE 状态与 DUT shadow 不一致");
                return 1;
            }

            // QEMU 的 WFI/WFE helper 在 cpu_has_work() 为真时可立即返回，
            // 不触发 idle callback；此时上一条等待指令已正常 COMMIT，而本条
            // PRE 是它之后的普通指令。DUT 已按通用 WFI 语义进入 idle，必须
            // 在推进本条前注入非架构 wake event。真正 halt 的情形不会有 PRE，
            // 而由插件以 ASYNC IRQ（或后续 timeout/event PRE）单独处理。
            bool resume_wait = qemu_wait_committed;
            bool wait_halted = qemu_wait_halted;
            if (resume_wait) {
                // 没有 WAIT：QEMU helper 因 cpu_has_work() 直接返回；有 WAIT
                // 的 WFE 也可由无 IRQ event 恢复。二者都不该把 WFIT/WFET
                // 的 timeout 时间误推进到目标值。
                if (debug_wait) {
                    fprintf(stderr,
                            "wait: PRE seq=%llu halted=%d count_valid=%d "
                            "last_insn=0x%08x cntvct=%llu\n",
                            (unsigned long long)hdr.seq, wait_halted ? 1 : 0,
                            qemu_wait_count_valid ? 1 : 0, last_pkt.insn,
                            (unsigned long long)qemu_wait_cntvct);
                }
                if (!wait_halted || qemu_wait_count_valid ||
                    is_wfi_wfe_instruction(last_pkt.insn)) {
                    if (debug_wait) {
                        fprintf(stderr,
                                "wait: QEMU 等待恢复为普通 PRE，释放 DUT idle "
                                "(seq=%llu)\n",
                                (unsigned long long)hdr.seq);
                    }
                    dut.stage_wait_resume(wait_halted &&
                                          qemu_wait_count_valid,
                                          qemu_wait_cntvct);
                }
                qemu_wait_committed = false;
                qemu_wait_halted = false;
                qemu_wait_count_valid = false;
            }

            CommitPacket pkt;
            uint64_t step_budget = (resume_wait && wait_halted &&
                                    !is_wfi_wfe_instruction(last_pkt.insn))
                                       ? max_wait_cycles : max_cycles_per_insn;
            if (!dut.step_until_commit(step_budget, &pkt)) {
                std::string note = "DUT 超过 max_cycles_per_insn 未提交";
                fprintf(stderr, "DUT 超时未提交（seq=%llu pc=0x%llx）\n",
                        (unsigned long long)hdr.seq,
                        (unsigned long long)pre.pre.pc);
                dut.dump_pipeline_debug(stderr);
                dump_failure(dump_path, hdr.seq, &pre, nullptr, nullptr,
                             nullptr, note);
                append_pipeline_debug(dump_path, dut);
                return 1;
            }
            g_errors.clear();
            check(pkt.pc == pre.pre.pc, "DUT commit pc 与 PRE 不一致");
            /*
             * 异常提交时 insn 仅为诊断字段：IABT 的取指地址未映射，
             * QEMU 报告 0，RTL 报告 SRAM 回绕后的数据，二者无意义
             * 差异，跳过比较（pc/exc_code/next_pc 仍严格比较）。
             */
            if (!pkt.exc_valid) {
                check(pkt.insn == pre.pre.insn,
                      "DUT commit insn 与 PRE 不一致");
            }
            if (!g_errors.empty()) {
                dump_failure(dump_path, hdr.seq, &pre, &pkt, nullptr,
                             nullptr, "DUT commit 与 PRE 不一致");
                return 1;
            }
            last_pkt = pkt;
            last_pre = pre;
            have_pkt = true;
            have_pre = true;
            last_pre_seq = hdr.seq;
            expected_pre_seq = hdr.seq + 1;
            if (!send_msg(fd, LCVEX_MSG_GO, hdr.seq, nullptr, 0)) {
                return 1;
            }
            continue;
        }

        if (hdr.type == LCVEX_MSG_COMMIT) {
            if (!have_pkt || !have_pre || hdr.seq != last_pre_seq) {
                fprintf(stderr,
                        "协议错误：COMMIT seq=%llu（期望 %llu）或缺少 PRE\n",
                        (unsigned long long)hdr.seq,
                        (unsigned long long)last_pre_seq);
                return 1;
            }

            g_errors.clear();
            // 先应用 DUT 提交包，再与 QEMU post-state 比较
            apply_commit(&shadow, last_pkt);
            check(cm.post.pc == last_pkt.pc, "QEMU post pc 与 DUT 不一致");
            if (!cm.exc_valid) {
                check(cm.post.insn == last_pkt.insn,
                      "QEMU post insn 与 DUT 不一致");
            }
            std::string diffs = shadow_vs_qemu(shadow, cm.post);
            if (!diffs.empty()) {
                // 拆成逐条错误
                size_t pos = 0;
                while ((pos = diffs.find('\n')) != std::string::npos) {
                    g_errors.push_back(diffs.substr(0, pos));
                    diffs.erase(0, pos + 1);
                }
            }
            if (!g_errors.empty()) {
                // P6 内核锁步调试：DUT 核心 decode/mmu 内部状态
                fprintf(stderr,
                        "DUT dbg mmu_en=%d el=%d vbar=0x%llx dec_valid=%d "
                        "dec_exc=%d dec_insn=0x%08x dec_pc=0x%llx "
                        "dec_exc_code=0x%x\n",
                        dut.dbg_mmu_en() ? 1 : 0,
                        dut.dbg_el() ? 1 : 0,
                        (unsigned long long)dut.dbg_vbar_el1(),
                        dut.dbg_dec_valid() ? 1 : 0,
                        dut.dbg_dec_exc() ? 1 : 0,
                        (unsigned)dut.dbg_dec_insn(),
                        (unsigned long long)dut.dbg_dec_pc(),
                        (unsigned)dut.dbg_dec_exc_code());
                // 调试：打印 DUT RAM 在故障访存地址附近的内容（对齐 64）
                uint64_t bases[] = {last_pkt.mem_addr & ~63ull,
                                    0x00000000ull, 0x02000000ull,
                                    0x02400000ull, 0x04000000ull,
                                    0x20000000ull, 0x40000000ull,
                                    0x42000000ull, 0x42400000ull,
                                    0x44000000ull, 0x40517000ull,
                                    0x40560000ull, 0x40561000ull,
                                    0x40562000ull};
                for (uint64_t base_a : bases) {
                    uint64_t vals[8];
                    for (int k = 0; k < 8; k++) {
                        vals[k] = dut.read_mem(base_a + 8 * k);
                    }
                    fprintf(stderr,
                            "DUT RAM @0x%llx: 0x%llx 0x%llx 0x%llx 0x%llx "
                            "0x%llx 0x%llx 0x%llx 0x%llx\n",
                            (unsigned long long)base_a,
                            (unsigned long long)vals[0],
                            (unsigned long long)vals[1],
                            (unsigned long long)vals[2],
                            (unsigned long long)vals[3],
                            (unsigned long long)vals[4],
                            (unsigned long long)vals[5],
                            (unsigned long long)vals[6],
                            (unsigned long long)vals[7]);
                }
            }
            // 内存写
            std::vector<std::string> dut_stores, qemu_stores;
            if (last_pkt.mem_we) {
                int size = 0;
                for (int b = 0; b < 8; b++) {
                    if (last_pkt.mem_strb & (1u << b)) size++;
                }
                char buf[128];
                snprintf(buf, sizeof(buf), "%llx/%llx/%d",
                         (unsigned long long)last_pkt.mem_addr,
                         (unsigned long long)last_pkt.mem_wdata, size);
                dut_stores.push_back(buf);
            }
            if (last_pkt.mem2_we) {
                int size = 0;
                for (int b = 0; b < 8; b++) {
                    if (last_pkt.mem2_strb & (1u << b)) size++;
                }
                char buf[128];
                snprintf(buf, sizeof(buf), "%llx/%llx/%d",
                         (unsigned long long)last_pkt.mem2_addr,
                         (unsigned long long)last_pkt.mem2_wdata, size);
                dut_stores.push_back(buf);
            }
            for (uint32_t i = 0; i < cm.store_count && i < LCVEX_MAX_STORES;
                 i++) {
                int size = 0;
                for (int b = 0; b < 8; b++) {
                    if (cm.stores[i].strb & (1u << b)) size++;
                }
                char buf[128];
                snprintf(buf, sizeof(buf), "%llx/%llx/%d",
                         (unsigned long long)cm.stores[i].addr,
                         (unsigned long long)cm.stores[i].data, size);
                qemu_stores.push_back(buf);
            }
            check(dut_stores == qemu_stores, "内存写列表不一致");
            check(cm.exc_valid == last_pkt.exc_valid,
                  "exc_valid 不一致");
            check(!cm.exc_valid || cm.exc_code == last_pkt.exc_code,
                  "exc_code 不一致");
            check(!cm.exc_valid || cm.exc_esr == last_pkt.exc_esr,
                  "exc_esr 不一致");
            check(!cm.exc_valid || cm.exc_far == last_pkt.exc_far,
                  "exc_far 不一致");
            // exclusive 监视器（M3）：本提交是否更新 + 新值
            check(cm.mon_we == last_pkt.mon_we, "mon_we 不一致");
            check(!cm.mon_we || cm.mon_valid == last_pkt.mon_valid,
                  "mon_valid 不一致");
            // 地址/值仅在“记录”（valid=1）时有意义；STXR/CLREX/ERET
            // 的清除提交不比较这两个字段
            check(!cm.mon_we || !cm.mon_valid ||
                  cm.mon_addr == last_pkt.mon_addr,
                  "mon_addr 不一致");
            check(!cm.mon_we || !cm.mon_valid ||
                  cm.mon_data == last_pkt.mon_data,
                  "mon_data 不一致");
            check(!cm.mon_we || !cm.mon_valid ||
                  cm.mon_data2 == last_pkt.mon_data2,
                  "mon_data2 不一致");

            /* P7 普通提交严格插入 FP_COMMIT；只有它完成后才允许
             * CKPT_REQ/READY 和 ACK。ASYNC/WAIT 分支不经过这里，故不带
             * FP frame。 */
            if (fp_required) {
                uint8_t fp_payload[LCVEX_FP_COMMIT_MAX_BYTES] = {};
                lcvex_msg_header fp_hdr = {};
                int fp_result = recv_msg(fd, &fp_hdr, fp_payload,
                                         sizeof(fp_payload));
                if (fp_result != 1 || fp_hdr.type != LCVEX_MSG_FP_COMMIT ||
                    fp_hdr.seq != hdr.seq) {
                    FpState dut_actual = dut.read_fp_state();
                    g_errors.clear();
                    g_failure_fp_valid = true;
                    g_failure_qemu_fp = qemu_fp_shadow;
                    g_failure_dut_fp = dut_actual;
                    g_failure_fp_first_mismatch =
                        "FP_COMMIT protocol/frame mismatch";
                    g_errors.push_back(g_failure_fp_first_mismatch);
                    fprintf(stderr,
                            "协议错误：COMMIT 后缺少匹配 FP_COMMIT seq=%llu\n",
                            static_cast<unsigned long long>(hdr.seq));
                    dump_failure(dump_path, hdr.seq, &last_pre, &last_pkt,
                                 &cm, nullptr,
                                 "FP_COMMIT 协议或长度不一致");
                    write_fail_fp_json(
                        fp_failure_path(dump_path), "FP_COMMIT", hdr.seq,
                        &qemu_fp_shadow, &dut_fp_shadow, &qemu_fp_shadow,
                        &dut_actual, &last_pre, &last_pkt, &cm, g_errors);
                    return 1;
                }
                FpState qemu_next = qemu_fp_shadow;
                FpState dut_effect_next = dut_fp_shadow;
                FpState dut_actual = dut.read_fp_state();
                std::string fp_error;
                std::vector<std::string> fp_errors;
                if (!apply_fp_delta(fp_payload, fp_hdr.payload_len,
                                    &qemu_next, &fp_error) ||
                    !apply_dut_fp_effect(last_pkt, &dut_effect_next, &fp_error)) {
                    fp_errors.push_back(fp_error.empty()
                                            ? "FP_COMMIT 应用失败" : fp_error);
                } else if (!fp_state_equal(dut_effect_next, dut_actual)) {
                    fp_errors.push_back(
                        "DUT FP raw state 与 commit effect 不一致");
                } else if (!fp_state_equal(qemu_next, dut_actual)) {
                    fp_errors.push_back(
                        "QEMU/DUT FP raw state 不一致");
                }
                g_failure_fp_valid = true;
                g_failure_qemu_fp = qemu_next;
                g_failure_dut_fp = dut_actual;
                if (!fp_errors.empty()) {
                    g_failure_fp_first_mismatch =
                        first_fp_raw_mismatch(qemu_next, dut_actual,
                                              "QEMU", "DUT");
                    if (g_failure_fp_first_mismatch.empty()) {
                        g_failure_fp_first_mismatch =
                            first_fp_raw_mismatch(dut_effect_next, dut_actual,
                                                  "effect", "DUT");
                    }
                    if (g_failure_fp_first_mismatch.empty()) {
                        g_failure_fp_first_mismatch = fp_errors.front();
                    }
                    for (auto it = fp_errors.rbegin(); it != fp_errors.rend();
                         ++it) {
                        g_errors.insert(g_errors.begin(), *it);
                    }
                    lcvex_ack fp_ack = {};
                    fp_ack.status = LCVEX_ACK_FAIL;
                    snprintf(fp_ack.detail, sizeof(fp_ack.detail), "%s",
                             fp_errors.front().c_str());
                    dump_failure(dump_path, hdr.seq, &last_pre, &last_pkt,
                                 &cm, nullptr, "FP_COMMIT 状态不一致");
                    write_fail_fp_json(
                        fp_failure_path(dump_path), "FP_COMMIT", hdr.seq,
                        &qemu_fp_shadow, &dut_fp_shadow, &qemu_next,
                        &dut_actual, &last_pre, &last_pkt, &cm, g_errors);
                    send_msg(fd, LCVEX_MSG_ACK, hdr.seq, &fp_ack,
                             sizeof(fp_ack));
                    send_msg(fd, LCVEX_MSG_STOP, hdr.seq, nullptr, 0);
                    return 1;
                }
                qemu_fp_shadow = qemu_next;
                dut_fp_shadow = dut_actual;
            }

            lcvex_ack ack = {};
            if (!g_errors.empty()) {
                ack.status = LCVEX_ACK_FAIL;
                std::string msg;
                for (const auto &e : g_errors) {
                    msg += e;
                    msg += "; ";
                }
                snprintf(ack.detail, sizeof(ack.detail), "%s", msg.c_str());
                dump_failure(dump_path, hdr.seq, &last_pre, &last_pkt, &cm,
                             nullptr, "COMMIT 状态不一致");
                append_pipeline_debug(dump_path, dut);
                send_msg(fd, LCVEX_MSG_ACK, hdr.seq, &ack, sizeof(ack));
                send_msg(fd, LCVEX_MSG_STOP, hdr.seq, nullptr, 0);
                fprintf(stderr, "FAIL: seq=%llu 有 %zu 处不一致\n",
                        (unsigned long long)hdr.seq, g_errors.size());
                return 1;
            }
            ack.status = LCVEX_ACK_OK;
            insns++;
            qemu_wait_committed = is_wait_instruction(last_pkt.insn);
            qemu_wait_halted = false;
            qemu_wait_count_valid = false;
            bool checkpoint_due = ckpt_every &&
                                  (diff_ckpt || !monitor_path.empty()) &&
                                  insns >= next_ckpt_seq;
            if (checkpoint_due && diff_ckpt &&
                !(fp_required
                      ? qemu_diff_ckpt_save_p7(fd, ram_path, ckpt_dir,
                                               hdr.seq, cm.post)
                      : qemu_diff_ckpt_save(fd, ram_path, ckpt_dir, hdr.seq,
                                            cm.post))) {
                fprintf(stderr, "差分 checkpoint 保存失败（seq=%llu）\n",
                        (unsigned long long)hdr.seq);
                ack.status = LCVEX_ACK_FAIL;
                snprintf(ack.detail, sizeof(ack.detail),
                         "差分 checkpoint 保存失败");
                send_msg(fd, LCVEX_MSG_ACK, hdr.seq, &ack, sizeof(ack));
                send_msg(fd, LCVEX_MSG_STOP, hdr.seq, nullptr, 0);
                return 1;
            }
            send_msg(fd, LCVEX_MSG_ACK, hdr.seq, &ack, sizeof(ack));
            if (checkpoint_due && !diff_ckpt) {
                qemu_ckpt_save(monitor_path, ckpt_dir, hdr.seq);
            }
            if (checkpoint_due) {
                next_ckpt_seq += ckpt_every;
                g_fp_failure_context.next_ckpt_seq = next_ckpt_seq;
            }
            WindowRec rec;
            rec.seq = hdr.seq;
            rec.pre_pc = last_pre.pre.pc;
            rec.pre_insn = last_pre.pre.insn;
            rec.dut_pc = last_pkt.pc;
            rec.dut_insn = last_pkt.insn;
            rec.dut_next_pc = last_pkt.next_pc;
            rec.qemu_pc = cm.post.pc;
            rec.qemu_insn = cm.post.insn;
            rec.qemu_next_pc = cm.post.next_pc;
            rec.ok = true;
            window_push(rec);
            have_pkt = false;
            have_pre = false;
            if (progress_every &&
                (insns == 1 || (insns % progress_every) == 0)) {
                fprintf(stderr, "seq=%llu OK (pc=0x%llx next=0x%llx "
                                "exc=%d mon_we=%d mon_v=%d)\n",
                        (unsigned long long)hdr.seq,
                        (unsigned long long)last_pkt.pc,
                        (unsigned long long)last_pkt.next_pc,
                        last_pkt.exc_valid, last_pkt.mon_we,
                        last_pkt.mon_valid);
            }
            if (have_max && insns >= max_insns) {
                send_msg(fd, LCVEX_MSG_STOP, hdr.seq, nullptr, 0);
                fprintf(stderr, "达到 max_insns=%llu，锁步结束\n",
                        (unsigned long long)max_insns);
                return 0;
            }
            continue;
        }

        fprintf(stderr, "未处理消息 type=%u\n", hdr.type);
        return 1;
    }
}
