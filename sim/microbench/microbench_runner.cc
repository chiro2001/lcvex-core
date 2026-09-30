// LCVEX microbench 运行器（无 QEMU）：
//   加载 mb_all.bin -> 运行 -> 轮询提交包中 MAGIC 地址的 store，
//   以其 wdata 为返回码（0=通过，非 0=失败数）；超时判 FAIL。
//   F0 扩展：同时收集 retired instruction、stall 代理、cache 事件和
//   内存事务计数，并在 --json 模式输出结构化性能基线。

#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <array>
#include <deque>
#include <fstream>
#include <string>
#include <sys/resource.h>
#include <vector>

#include "verilated.h"
#include "Vlcvex_soc_tb.h"
#include "Vlcvex_soc_tb___024root.h"
#include "commit_digest.h"

static void read_words(const std::string &path, std::vector<uint32_t> *out) {
    std::ifstream f(path, std::ios::binary);
    if (!f) {
        fprintf(stderr, "无法打开镜像 %s\n", path.c_str());
        exit(2);
    }
    uint8_t buf[4];
    while (f.read(reinterpret_cast<char *>(buf), sizeof(buf))) {
        out->push_back(buf[0] | (buf[1] << 8) | (buf[2] << 16) |
                       (buf[3] << 24));
    }
}

static std::string shell_quote(const std::string &s) {
    std::string q = "'";
    for (char c : s) {
        if (c == '\'') q += "'\\''";
        else q += c;
    }
    q += "'";
    return q;
}

static std::string shell_output(const std::string &cmd) {
    FILE *p = popen(cmd.c_str(), "r");
    if (!p) return "";
    std::string out;
    char buf[512];
    while (fgets(buf, sizeof(buf), p)) out += buf;
    int rc = pclose(p);
    (void)rc;
    return out;
}

static std::string sha256_file(const std::string &path) {
    std::string cmd = "sha256sum -- " + shell_quote(path) + " 2>/dev/null";
    std::string out = shell_output(cmd);
    size_t sp = out.find(' ');
    if (sp != std::string::npos) return out.substr(0, sp);
    return "";
}

static std::string git_sha() {
    std::string out = shell_output("git rev-parse HEAD 2>/dev/null");
    while (!out.empty() && (out.back() == '\n' || out.back() == '\r'))
        out.pop_back();
    return out.empty() ? "unknown" : out;
}

static std::string source_sha256(const std::string &name) {
    std::string base = name;
    if (base.rfind("t_", 0) == 0) base = base.substr(2);
    if (base.size() >= 2 && base.compare(base.size() - 2, 2, ".c") == 0)
        base = base.substr(0, base.size() - 2);
    std::string files =
        "baremetal/perf/t_" + base + ".c "
        "baremetal/perf/perf_common.h "
        "baremetal/tests.h "
        "baremetal/microbench_main.c "
        "baremetal/startup_mb.s "
        "baremetal/link.ld "
        "scripts/build-microbench.sh "
        "sim/microbench/microbench_runner.cc "
        "sim/microbench/commit_digest.h";
    std::string cmd =
        "for f in " + files +
        "; do [ -f \"$f\" ] && sha256sum -- \"$f\"; done | sha256sum 2>/dev/null";
    std::string out = shell_output(cmd);
    size_t sp = out.find(' ');
    if (sp != std::string::npos) return out.substr(0, sp);
    return out;
}

static std::string json_escape(const std::string &s) {
    std::string out;
    for (unsigned char c : s) {
        switch (c) {
        case '"': out += "\\\""; break;
        case '\\': out += "\\\\"; break;
        case '\n': out += "\\n"; break;
        case '\r': out += "\\r"; break;
        case '\t': out += "\\t"; break;
        default:
            if (c < 0x20) {
                char buf[8];
                snprintf(buf, sizeof(buf), "\\u%04x", c);
                out += buf;
            } else {
                out += (char)c;
            }
        }
    }
    return out;
}

// Stable, cycle-independent digests used by F1c off/on equivalence checks.
// FNV-1a is intentionally tiny and deterministic; fields are fed byte-wise so
// the digest is independent of host endianness and C++ struct layout.
static constexpr uint64_t kFnvOffset = 1469598103934665603ULL;
static constexpr uint64_t kFnvPrime = 1099511628211ULL;

static void digest_u64(uint64_t *digest, uint64_t value) {
    for (unsigned i = 0; i < 8; ++i) {
        *digest ^= (value >> (i * 8)) & 0xffU;
        *digest *= kFnvPrime;
    }
}

static void digest_u32(uint64_t *digest, uint32_t value) {
    for (unsigned i = 0; i < 4; ++i) {
        *digest ^= (value >> (i * 8)) & 0xffU;
        *digest *= kFnvPrime;
    }
}

static void digest_u8(uint64_t *digest, uint8_t value) {
    *digest ^= value;
    *digest *= kFnvPrime;
}

static std::string trace_hex_u64(uint64_t value) {
    char buf[19];
    snprintf(buf, sizeof(buf), "0x%016llx", (unsigned long long)value);
    return buf;
}

static std::string trace_hex_u32(uint32_t value) {
    char buf[11];
    snprintf(buf, sizeof(buf), "0x%08x", value);
    return buf;
}

// T-009 bounded event probe.  It is deliberately kept in the runner rather
// than the architectural digest path: enabling it may add an artifact, but
// must not alter simulation inputs, commit sequencing, or default JSON.
struct ProbeEvent {
    std::string kind;
    uint64_t cycle = 0;
    uint64_t epoch = 0;
    uint64_t occupancy = 0;
    uint64_t delay_count = 0;
    uint64_t delay_lfsr = 0;
    bool delay_req_pending = false;
    bool delay_rsp_pending = false;
};

struct ProbeCommit {
    uint64_t seq = 0;
    uint64_t cycle = 0;
    std::string key;
};

struct ProbeKillWindow {
    uint64_t cycle = 0;
    bool drop_seen = false;
    bool drain_seen = false;
    bool drain_end_seen = false;
    uint64_t drain_start = 0;
};

struct ProbeWindowKind {
    const char *name = nullptr;
    uint64_t recorded = 0;
    uint64_t suppressed = 0;
};

static void probe_key_u8(std::string *out, uint8_t value) {
    char buf[8];
    snprintf(buf, sizeof(buf), "%02x", (unsigned)value);
    *out += buf;
    *out += ',';
}

static void probe_key_u32(std::string *out, uint32_t value) {
    char buf[16];
    snprintf(buf, sizeof(buf), "%08x", value);
    *out += buf;
    *out += ',';
}

static void probe_key_u64(std::string *out, uint64_t value) {
    char buf[24];
    snprintf(buf, sizeof(buf), "%016llx", (unsigned long long)value);
    *out += buf;
    *out += ',';
}

static void probe_key_enable(std::string *out, uint8_t enable, uint8_t rd,
                             uint64_t data) {
    probe_key_u8(out, enable);
    probe_key_u8(out, enable ? rd : 0);
    probe_key_u64(out, enable ? data : 0);
}

static void probe_key_memory(std::string *out, uint8_t enable, uint64_t addr,
                             uint64_t data, uint8_t strb) {
    probe_key_u8(out, enable);
    probe_key_u64(out, enable ? addr : 0);
    probe_key_u64(out, enable ? data : 0);
    probe_key_u8(out, enable ? strb : 0);
}

static std::string probe_commit_key(
    const lcvex_commit_digest::CommitPacket &p) {
    std::string out;
    out.reserve(640);
    probe_key_u64(&out, p.seq);
    probe_key_u64(&out, p.pc);
    probe_key_u64(&out, p.next_pc);
    probe_key_u32(&out, p.insn);
    probe_key_enable(&out, p.gpr_we, p.gpr_rd, p.gpr_wdata);
    probe_key_enable(&out, p.gpr2_we, p.gpr2_rd, p.gpr2_wdata);
    probe_key_enable(&out, p.gpr3_we, p.gpr3_rd, p.gpr3_wdata);
    probe_key_u8(&out, p.sp_we);
    probe_key_u64(&out, p.sp_we ? p.sp_wdata : 0);
    probe_key_u8(&out, p.nzcv_we);
    probe_key_u8(&out, p.nzcv_we ? p.nzcv : 0);
    probe_key_memory(&out, p.mem_we, p.mem_addr, p.mem_wdata, p.mem_strb);
    probe_key_memory(&out, p.mem2_we, p.mem2_addr, p.mem2_wdata,
                     p.mem2_strb);
    probe_key_u8(&out, p.exc_valid);
    probe_key_u32(&out, p.exc_valid ? p.exc_code : 0);
    probe_key_u32(&out, p.exc_valid ? p.exc_esr : 0);
    probe_key_u64(&out, p.exc_valid ? p.exc_far : 0);
    probe_key_u8(&out, p.mon_we);
    probe_key_u8(&out, p.mon_we ? p.mon_valid : 0);
    probe_key_u64(&out, p.mon_we ? p.mon_addr : 0);
    probe_key_u64(&out, p.mon_we ? p.mon_data : 0);
    probe_key_u64(&out, p.mon_we ? p.mon_data2 : 0);
    probe_key_u8(&out, p.vec_write_count);
    for (uint8_t i = 0; i < lcvex_commit_digest::kMaxVectorWrites; ++i) {
        const bool active = i < p.vec_write_count;
        probe_key_u8(&out, active ? p.vec_rd[i] : 0);
        probe_key_u64(&out, active ? p.vec_wdata_lo[i] : 0);
        probe_key_u64(&out, active ? p.vec_wdata_hi[i] : 0);
    }
    probe_key_u8(&out, p.fpcr_we);
    probe_key_u32(&out, p.fpcr_we ? p.fpcr_wdata : 0);
    probe_key_u8(&out, p.fpsr_we);
    probe_key_u32(&out, p.fpsr_we ? p.fpsr_wdata : 0);
    return out;
}

class EventProbe {
public:
    static constexpr size_t kEventWindowLimit = 128;
    static constexpr uint64_t kPerKindLimit = 8;
    static constexpr size_t kCommitPrefixLimit = 32;
    static constexpr size_t kKillTrackingLimit = 8192;

    explicit EventProbe(bool enabled) : enabled_(enabled) {}

    bool enabled() const { return enabled_; }

    void observe_commit(const lcvex_commit_digest::CommitPacket &packet,
                        uint64_t cycle) {
        if (!enabled_) return;
        if (commit_prefix_.size() < kCommitPrefixLimit) {
            commit_prefix_.push_back(
                ProbeCommit{packet.seq, cycle, probe_commit_key(packet)});
        } else {
            commit_prefix_truncated_ = true;
        }
    }

    void observe_cycle(uint64_t cycle, const Vlcvex_soc_tb &top,
                       bool commit_fire) {
        if (!enabled_) return;

        const bool stale = top.fetch_stale_drain;
        const bool delay_req_pending = top.probe_delay_req_pending;
        const bool delay_rsp_pending = top.probe_delay_rsp_pending;
        const bool delay_pending = delay_req_pending || delay_rsp_pending;
        // The core suppresses fetch_req_valid during stale quarantine, so a
        // valid&&!ready test alone would miss the dominant blocked interval.
        // Count quarantine as fetch issue blocking and retain the raw signal
        // in the event window for distinction.
        const bool fetch_issue_blocked =
            top.probe_fetch_issue_blocked || stale;
        const bool fetch_issue_not_ready = top.probe_fetch_issue_blocked;
        const bool mem_stall = top.probe_dmem_pending || top.probe_mem_busy;
        // A translated-only fetch has no response in flight.  Existing stale
        // flags are included for a repeated kill while quarantine is already
        // draining a prior context.
        const bool stale_candidate = top.probe_fetch_pending ||
                                     top.probe_fetch_trans_busy ||
                                     top.probe_fetch_stale_mmu ||
                                     top.probe_fetch_stale_imem;
        const bool imem_req_fire = top.probe_imem_req_valid &&
                                   top.probe_imem_req_ready;
        const bool imem_rsp_fire = top.probe_imem_rsp_valid &&
                                   top.probe_imem_rsp_ready;

        if (top.probe_frontend_kill) {
            ++kill_count_;
            ++flush_count_;
            record_event("frontend_kill", cycle, top);
            if (stale_candidate) {
                ++kill_with_stale_context_count_;
                if (kill_windows_.size() >= kKillTrackingLimit) {
                    tracking_truncated_ = true;
                } else {
                    kill_windows_.push_back(ProbeKillWindow{cycle});
                }
            } else {
                ++kill_without_stale_context_count_;
            }
            reissue_armed_ = stale_candidate;
        }
        if (top.fetch_fifo_flush && !top.probe_frontend_kill)
            ++flush_count_;

        if (top.fetch_stale_rsp_drop) {
            ++stale_context_drop_count_;
            record_event("stale_context_drop", cycle, top);
            bool matched = false;
            for (auto it = kill_windows_.rbegin(); it != kill_windows_.rend();
                 ++it) {
                if (!it->drop_seen) {
                    it->drop_seen = true;
                    record_latency(&kill_to_stale_context_drop_hist_,
                                   cycle - it->cycle);
                    matched = true;
                    break;
                }
            }
            if (!matched) ++orphan_stale_context_drop_count_;
        }

        if (stale && !previous_stale_drain_) {
            ++stale_context_drain_windows_;
            record_event("stale_context_drain_start", cycle, top);
            for (auto it = kill_windows_.rbegin(); it != kill_windows_.rend();
                 ++it) {
                if (!it->drain_seen) {
                    it->drain_seen = true;
                    it->drain_start = cycle;
                    break;
                }
            }
        }
        if (!stale && previous_stale_drain_) {
            record_event("stale_context_drain_end", cycle, top);
            for (auto it = kill_windows_.rbegin(); it != kill_windows_.rend();
                 ++it) {
                if (it->drain_seen && !it->drain_end_seen) {
                    it->drain_end_seen = true;
                    record_latency(&kill_to_stale_context_drain_end_hist_,
                                   cycle - it->cycle);
                    break;
                }
            }
        }
        previous_stale_drain_ = stale;

        if (stale) {
            ++stale_context_drain_cycles_;
            if (delay_req_pending) ++stale_context_delay_req_overlap_;
            if (delay_rsp_pending) ++stale_context_delay_rsp_overlap_;
            if (delay_pending) ++stale_context_delay_any_overlap_;
        }
        if (delay_req_pending) ++delay_req_pending_cycles_;
        if (delay_rsp_pending) ++delay_rsp_pending_cycles_;
        if (delay_pending) ++delay_pending_cycles_;

        if (fetch_issue_blocked) {
            ++fetch_issue_blocked_cycles_;
            if (!previous_fetch_issue_blocked_)
                record_event("fetch_issue_blocked_start", cycle, top);
            ++current_fetch_issue_blocked_run_;
            if (current_fetch_issue_blocked_run_ >
                max_fetch_issue_blocked_run_)
                max_fetch_issue_blocked_run_ = current_fetch_issue_blocked_run_;
        } else if (previous_fetch_issue_blocked_) {
            record_event("fetch_issue_blocked_end", cycle, top);
            current_fetch_issue_blocked_run_ = 0;
        }
        previous_fetch_issue_blocked_ = fetch_issue_blocked;
        if (fetch_issue_not_ready)
            ++fetch_issue_not_ready_cycles_;

        if (imem_req_fire) {
            ++imem_req_count_;
            if (reissue_armed_) {
                ++imem_reissue_after_stale_kill_count_;
                record_event("imem_reissue_after_stale_kill", cycle, top);
                reissue_armed_ = false;
            }
        }
        if (imem_rsp_fire) ++imem_rsp_count_;

        if (mem_stall) {
            ++mem_stall_cycles_;
            if (stale) ++mem_stall_stale_context_overlap_;
            if (delay_pending) ++mem_stall_delay_overlap_;
            if (stale && delay_pending)
                ++mem_stall_stale_context_delay_overlap_;
        }

        if (commit_fire) {
            ++commit_count_;
            finish_starvation_run();
        } else {
            ++current_starvation_run_;
            if (current_starvation_run_ > max_starvation_run_)
                max_starvation_run_ = current_starvation_run_;
        }

        retire_completed_kill_windows();
    }

    void finish(uint64_t cycles, uint64_t retired_insn) {
        if (!enabled_) return;
        if (current_starvation_run_ != 0) finish_starvation_run();
        cycles_ = cycles;
        retired_insn_ = retired_insn;
        imem_extra_vs_retired_ = imem_req_count_ > retired_insn_
                                      ? imem_req_count_ - retired_insn_
                                      : 0;
        // Any unfinished window is retained as unresolved rather than being
        // silently counted as a completed kill-to-drain interval.
        unresolved_stale_context_windows_ = kill_windows_.size();
    }

    bool write_json(const std::string &path, const std::string &name,
                    uint64_t cycles, uint64_t retired_insn, uint64_t digest,
                    uint64_t memory_digest, const char *status) const {
        std::ofstream out(path, std::ios::out | std::ios::trunc);
        if (!out) return false;
        out << "{\"schema\":\"lcvex-f1a-d2-event-v2-stale-context\""
            << ",\"name\":\"" << json_escape(name) << "\""
            << ",\"status\":\"" << status << "\""
            << ",\"cycles\":" << cycles
            << ",\"retired_insn\":" << retired_insn
            << ",\"commit_digest\":\"" << trace_hex_u64(digest) << "\""
            << ",\"memory_digest\":\"" << trace_hex_u64(memory_digest)
            << "\""
            << ",\"event_window_limit\":" << kEventWindowLimit
            << ",\"event_window_truncated\":"
            << (event_window_truncated_ ? "true" : "false")
            << ",\"truncated\":"
            << ((event_window_truncated_ || tracking_truncated_) ? "true"
                                                                  : "false")
            << ",\"commit_prefix_limit\":" << kCommitPrefixLimit
            << ",\"commit_prefix_truncated\":"
            << (commit_prefix_truncated_ ? "true" : "false")
            << ",\"tracking_truncated\":"
            << (tracking_truncated_ ? "true" : "false")
            << ",\"aggregate\":{";
        out << "\"kill\":" << kill_count_
            << ",\"flush\":" << flush_count_
            << ",\"kill_with_stale_context\":"
            << kill_with_stale_context_count_
            << ",\"kill_without_stale_context\":"
            << kill_without_stale_context_count_
            << ",\"kill_partition_valid\":"
            << ((kill_count_ == kill_with_stale_context_count_ +
                 kill_without_stale_context_count_) ? "true" : "false")
            << ",\"stale_context_drop\":" << stale_context_drop_count_
            << ",\"orphan_stale_context_drop\":"
            << orphan_stale_context_drop_count_
            << ",\"stale_context_drain_windows\":"
            << stale_context_drain_windows_
            << ",\"stale_context_drain_cycles\":"
            << stale_context_drain_cycles_
            << ",\"stale_context_delay_req_overlap\":"
            << stale_context_delay_req_overlap_
            << ",\"stale_context_delay_rsp_overlap\":"
            << stale_context_delay_rsp_overlap_
            << ",\"stale_context_delay_any_overlap\":"
            << stale_context_delay_any_overlap_
            << ",\"delay_req_pending_cycles\":"
            << delay_req_pending_cycles_
            << ",\"delay_rsp_pending_cycles\":"
            << delay_rsp_pending_cycles_
            << ",\"delay_pending_cycles\":" << delay_pending_cycles_
            << ",\"fetch_issue_blocked_cycles\":"
            << fetch_issue_blocked_cycles_
            << ",\"fetch_issue_not_ready_cycles\":"
            << fetch_issue_not_ready_cycles_
            << ",\"max_fetch_issue_blocked_run\":"
            << max_fetch_issue_blocked_run_
            << ",\"imem_requests\":" << imem_req_count_
            << ",\"imem_responses\":" << imem_rsp_count_
            << ",\"imem_reissue_after_stale_kill\":"
            << imem_reissue_after_stale_kill_count_
            << ",\"imem_extra_vs_retired\":" << imem_extra_vs_retired_
            << ",\"mem_stall_cycles\":" << mem_stall_cycles_
            << ",\"mem_stall_stale_context_overlap\":"
            << mem_stall_stale_context_overlap_
            << ",\"mem_stall_delay_overlap\":" << mem_stall_delay_overlap_
            << ",\"mem_stall_stale_context_delay_overlap\":"
            << mem_stall_stale_context_delay_overlap_
            << ",\"commit_count\":" << commit_count_
            << ",\"starvation_runs\":" << starvation_runs_
            << ",\"max_starvation_run\":" << max_starvation_run_
            << ",\"unresolved_stale_context_windows\":"
            << unresolved_stale_context_windows_
            << ",\"imem_request_counted_by_probe\":true}"
            << ",\"latency_histogram\":{";
        write_histogram(out, "kill_to_stale_context_drop",
                        kill_to_stale_context_drop_hist_);
        out << ",";
        write_histogram(out, "kill_to_stale_context_drain_end",
                        kill_to_stale_context_drain_end_hist_);
        out << "},\"latency_histogram_bins\":[\"0\",\"1\",\"2\",\"3\",\"4\",\"5-8\",\"9-16\",\"17+\"]"
            << ",\"starvation_histogram\":[";
        for (size_t i = 0; i < starvation_hist_.size(); ++i) {
            if (i != 0) out << ',';
            out << starvation_hist_[i];
        }
        out << "],\"starvation_histogram_bins\":[\"0\",\"1\",\"2\",\"3\",\"4-7\",\"8-15\",\"16-63\",\"64+\"]"
            << ",\"event_window\":[";
        for (size_t i = 0; i < event_window_.size(); ++i) {
            if (i != 0) out << ',';
            const ProbeEvent &event = event_window_[i];
            out << "{\"kind\":\"" << event.kind << "\",\"cycle\":"
                << event.cycle << ",\"epoch\":" << event.epoch
                << ",\"occupancy\":" << event.occupancy
                << ",\"delay_count\":" << event.delay_count
                << ",\"delay_lfsr\":" << event.delay_lfsr
                << ",\"delay_req_pending\":"
                << (event.delay_req_pending ? "true" : "false")
                << ",\"delay_rsp_pending\":"
                << (event.delay_rsp_pending ? "true" : "false") << "}";
        }
        out << "],\"event_window_suppressed\":{";
        for (size_t i = 0; i < window_kind_count_; ++i) {
            if (i != 0) out << ',';
            out << "\"" << window_kinds_[i].name << "\":"
                << window_kinds_[i].suppressed;
        }
        out << "},\"commit_prefix\":[";
        for (size_t i = 0; i < commit_prefix_.size(); ++i) {
            if (i != 0) out << ',';
            const ProbeCommit &commit = commit_prefix_[i];
            out << "{\"seq\":" << commit.seq << ",\"cycle\":"
                << commit.cycle << ",\"key\":\"" << commit.key
                << "\"}";
        }
        out << "]}\n";
        return static_cast<bool>(out);
    }

private:
    static size_t latency_bin(uint64_t value) {
        if (value == 0) return 0;
        if (value == 1) return 1;
        if (value == 2) return 2;
        if (value == 3) return 3;
        if (value <= 4) return 4;
        if (value <= 8) return 5;
        if (value <= 16) return 6;
        return 7;
    }

    static size_t starvation_bin(uint64_t value) {
        if (value == 0) return 0;
        if (value == 1) return 1;
        if (value == 2) return 2;
        if (value == 3) return 3;
        if (value <= 7) return 4;
        if (value <= 15) return 5;
        if (value <= 63) return 6;
        return 7;
    }

    static void record_latency(std::array<uint64_t, 8> *hist,
                               uint64_t value) {
        ++(*hist)[latency_bin(value)];
    }

    static void write_histogram(std::ofstream &out, const char *name,
                                const std::array<uint64_t, 8> &hist) {
        out << "\"" << name << "\":[";
        for (size_t i = 0; i < hist.size(); ++i) {
            if (i != 0) out << ',';
            out << hist[i];
        }
        out << "]";
    }

    void record_event(const char *kind, uint64_t cycle,
                      const Vlcvex_soc_tb &top) {
        size_t index = window_kind_count_;
        for (size_t i = 0; i < window_kind_count_; ++i) {
            if (strcmp(window_kinds_[i].name, kind) == 0) {
                index = i;
                break;
            }
        }
        if (index == window_kind_count_) {
            if (window_kind_count_ >= window_kinds_.size()) {
                event_window_truncated_ = true;
                return;
            }
            window_kinds_[window_kind_count_].name = kind;
            index = window_kind_count_++;
        }
        ProbeWindowKind &category = window_kinds_[index];
        if (category.recorded >= kPerKindLimit) {
            ++category.suppressed;
            return;
        }
        if (event_window_.size() >= kEventWindowLimit) {
            event_window_truncated_ = true;
            ++category.suppressed;
            return;
        }
        ++category.recorded;
        event_window_.push_back(ProbeEvent{
            kind, cycle, static_cast<uint64_t>(top.fetch_epoch),
            static_cast<uint64_t>(top.fetch_fifo_occupancy),
            static_cast<uint64_t>(top.probe_delay_count),
            static_cast<uint64_t>(top.probe_delay_lfsr),
            static_cast<bool>(top.probe_delay_req_pending),
            static_cast<bool>(top.probe_delay_rsp_pending)});
    }

    void finish_starvation_run() {
        if (current_starvation_run_ == 0) return;
        ++starvation_runs_;
        ++starvation_hist_[starvation_bin(current_starvation_run_)];
        current_starvation_run_ = 0;
    }

    void retire_completed_kill_windows() {
        for (auto it = kill_windows_.begin(); it != kill_windows_.end();) {
            if (it->drop_seen &&
                (!it->drain_seen || it->drain_end_seen)) {
                it = kill_windows_.erase(it);
            } else {
                ++it;
            }
        }
    }

    bool enabled_ = false;
    uint64_t cycles_ = 0;
    uint64_t retired_insn_ = 0;
    uint64_t kill_count_ = 0;
    uint64_t flush_count_ = 0;
    uint64_t kill_with_stale_context_count_ = 0;
    uint64_t kill_without_stale_context_count_ = 0;
    uint64_t stale_context_drop_count_ = 0;
    uint64_t orphan_stale_context_drop_count_ = 0;
    uint64_t stale_context_drain_windows_ = 0;
    uint64_t stale_context_drain_cycles_ = 0;
    uint64_t stale_context_delay_req_overlap_ = 0;
    uint64_t stale_context_delay_rsp_overlap_ = 0;
    uint64_t stale_context_delay_any_overlap_ = 0;
    uint64_t delay_req_pending_cycles_ = 0;
    uint64_t delay_rsp_pending_cycles_ = 0;
    uint64_t delay_pending_cycles_ = 0;
    uint64_t fetch_issue_blocked_cycles_ = 0;
    uint64_t fetch_issue_not_ready_cycles_ = 0;
    uint64_t current_fetch_issue_blocked_run_ = 0;
    uint64_t max_fetch_issue_blocked_run_ = 0;
    uint64_t imem_req_count_ = 0;
    uint64_t imem_rsp_count_ = 0;
    uint64_t imem_reissue_after_stale_kill_count_ = 0;
    uint64_t imem_extra_vs_retired_ = 0;
    uint64_t mem_stall_cycles_ = 0;
    uint64_t mem_stall_stale_context_overlap_ = 0;
    uint64_t mem_stall_delay_overlap_ = 0;
    uint64_t mem_stall_stale_context_delay_overlap_ = 0;
    uint64_t commit_count_ = 0;
    uint64_t current_starvation_run_ = 0;
    uint64_t starvation_runs_ = 0;
    uint64_t max_starvation_run_ = 0;
    uint64_t unresolved_stale_context_windows_ = 0;
    bool previous_stale_drain_ = false;
    bool previous_fetch_issue_blocked_ = false;
    bool reissue_armed_ = false;
    bool event_window_truncated_ = false;
    bool commit_prefix_truncated_ = false;
    bool tracking_truncated_ = false;
    std::array<uint64_t, 8> kill_to_stale_context_drop_hist_{};
    std::array<uint64_t, 8> kill_to_stale_context_drain_end_hist_{};
    std::array<uint64_t, 8> starvation_hist_{};
    std::deque<ProbeKillWindow> kill_windows_;
    std::array<ProbeWindowKind, 16> window_kinds_{};
    size_t window_kind_count_ = 0;
    std::vector<ProbeEvent> event_window_;
    std::vector<ProbeCommit> commit_prefix_;
};

int main(int argc, char **argv) {
    std::string image, name = "mb";
    std::string git_sha_arg, source_sha_arg, params, trace_path, probe_path;
    uint64_t base = 0x44000000;
    uint64_t magic = 0x4400FE00;
    uint64_t max_cycles = 5000000;
    bool json_mode = false;

    for (int i = 1; i < argc; i++) {
        std::string a = argv[i];
        auto val = [&](const char *n) -> std::string {
            return (i + 1 < argc) ? argv[++i] : "";
        };
        if (a == "--image") image = val("--image");
        else if (a == "--base") base = strtoull(val("--base").c_str(), nullptr, 0);
        else if (a == "--magic") magic = strtoull(val("--magic").c_str(), nullptr, 0);
        else if (a == "--max-cycles") {
            max_cycles = strtoull(val("--max-cycles").c_str(), nullptr, 0);
        } else if (a == "--name") name = val("--name");
        else if (a == "--json") json_mode = true;
        else if (a == "--git-sha") git_sha_arg = val("--git-sha");
        else if (a == "--source-sha") source_sha_arg = val("--source-sha");
        else if (a == "--params") params = val("--params");
        else if (a == "--trace") trace_path = val("--trace");
        else if (a == "--probe") probe_path = val("--probe");
        else {
            fprintf(stderr, "未知参数 %s\n", a.c_str());
            return 2;
        }
    }
    if (image.empty()) {
        fprintf(stderr,
                "用法: %s --image FILE [--base ADDR] [--magic ADDR] "
                "[--max-cycles N] [--name NAME] [--json] [--git-sha SHA] "
                "[--source-sha SHA] [--params TEXT] [--trace FILE] "
                "[--probe FILE]\n", argv[0]);
        return 2;
    }
    if (!trace_path.empty()) {
        // Trace is deliberately opt-in. Opening it before simulation makes a
        // bad diagnostic path an explicit trace-mode error instead of silently
        // running without the requested evidence.
        std::ofstream probe(trace_path, std::ios::out | std::ios::trunc);
        if (!probe) {
            fprintf(stderr, "无法打开 commit trace %s\n", trace_path.c_str());
            return 2;
        }
    }
    const bool probe_enabled = !probe_path.empty();
    if (probe_enabled) {
        std::ofstream probe(probe_path, std::ios::out | std::ios::trunc);
        if (!probe) {
            fprintf(stderr, "无法打开 event probe %s\n", probe_path.c_str());
            return 2;
        }
    }

    auto t_start = std::chrono::steady_clock::now();
    Vlcvex_soc_tb top;
    std::vector<uint32_t> words;
    read_words(image, &words);

    auto tick = [&]() {
        top.clk = 1;
        top.eval();
        top.clk = 0;
        top.eval();
    };

    top.clk = 0;
    top.rst_n = 0;
    top.commit_ready = 1;
    top.difftest_wait_release = 0;
    top.difftest_wait_cntvct_valid = 0;
    top.difftest_wait_cntvct = 0;
    top.difftest_restore_sys_valid = 0;
    top.difftest_restore_fp_valid = 0;
    top.difftest_restore_fpcr = 0;
    top.difftest_restore_fpsr = 0;
    for (int i = 0; i < 32; i++) {
        top.difftest_restore_fp_v_lo[i] = 0;
        top.difftest_restore_fp_v_hi[i] = 0;
    }
    top.difftest_restore_pc = 0;
    top.difftest_restore_sp_el0 = 0;
    top.difftest_restore_sp_el1 = 0;
    top.difftest_restore_nzcv = 0;
    top.difftest_restore_el = 0;
    top.difftest_restore_sp_sel = 0;
    top.difftest_restore_daif = 0;
    top.difftest_restore_pan = 0;
    top.difftest_restore_dit = 0;
    top.difftest_restore_elr_el1 = 0;
    top.difftest_restore_spsr_el1 = 0;
    top.difftest_restore_vbar_el1 = 0;
    top.difftest_restore_sctlr_el1 = 0;
    top.difftest_restore_tcr_el1 = 0;
    top.difftest_restore_ttbr0_el1 = 0;
    top.difftest_restore_ttbr1_el1 = 0;
    top.difftest_restore_mair_el1 = 0;
    top.difftest_restore_esr_el1 = 0;
    top.difftest_restore_far_el1 = 0;
    top.difftest_restore_par_el1 = 0;
    top.difftest_restore_cpacr_el1 = 0;
    top.difftest_restore_mdscr_el1 = 0;
    top.difftest_restore_pmuserenr_el0 = 0;
    top.difftest_restore_cntkctl_el1 = 0;
    top.difftest_restore_tpidr_el0 = 0;
    top.difftest_restore_tpidrro_el0 = 0;
    top.difftest_restore_tpidr_el1 = 0;
    top.difftest_restore_pir_el1 = 0;
    top.difftest_restore_pire0_el1 = 0;
    top.difftest_restore_zcr_el1 = 0;
    top.difftest_restore_smcr_el1 = 0;
    top.difftest_restore_csselr_el1 = 0;
    top.difftest_restore_tcr2_el1 = 0;
    top.difftest_restore_contextidr_el1 = 0;
    top.difftest_restore_excl_valid = 0;
    top.difftest_restore_excl_addr = 0;
    top.difftest_restore_excl_data = 0;
    top.difftest_restore_excl_data_hi = 0;
    top.difftest_restore_cntpct = 0;
    top.difftest_restore_cntp_cval = 0;
    top.difftest_restore_cntp_ctl = 0;
    top.difftest_restore_cntv_cval = 0;
    top.difftest_restore_cntv_ctl = 0;
    top.prog_we = 0;
    top.prog_addr = 0;
    top.prog_strb = 0;
    top.prog_wdata = 0;
    top.eval();
    for (size_t i = 0; i < words.size(); i++) {
        top.prog_we = 1;
        top.prog_addr = base + 4 * i;
        top.prog_strb = 0x0f;
        top.prog_wdata = words[i];
        tick();
    }
    top.prog_we = 0;
    top.rst_n = 1;
    tick();

    uint64_t rc = 0;
    bool done = false;
    uint64_t cycles = 0;

    // ---- F0 counters ----
    uint64_t retired_insn = 0;
    uint64_t stall_if_cycles = 0;
    uint64_t fetch_wait_cycles = 0;
    uint64_t branch_flush_cycles = 0;
    uint64_t mem_stall_cycles = 0;
    uint64_t ptw_stall_cycles = 0;
    uint64_t muldiv_stall_cycles = 0;
    uint64_t wb_stall_cycles = 0;
    uint64_t load_use_cycles = 0;

    uint64_t imem_req_count = 0, imem_rsp_count = 0;
    uint64_t dmem_req_count = 0, dmem_rsp_count = 0;
    uint64_t ptw_req_count = 0, ptw_rsp_count = 0;
    uint64_t arb_req_count = 0, arb_rsp_count = 0;
    uint64_t l2_req_count = 0, l2_rsp_count = 0;
    uint64_t del_req_count = 0, del_rsp_count = 0;
    uint64_t ram_req_count = 0, ram_rsp_count = 0;

    uint64_t il1_up = 0, il1_hit = 0, il1_miss = 0;
    uint64_t il1_refill_beat = 0, il1_down = 0;
    uint64_t dl1_up = 0, dl1_hit = 0, dl1_miss = 0, dl1_write = 0;
    uint64_t dl1_refill_beat = 0, dl1_down = 0;
    uint64_t l2_up = 0, l2_hit = 0, l2_miss = 0, l2_write = 0;
    uint64_t l2_refill_beat = 0, l2_down = 0;

    // T-041 F1a read-only ports. These are observation counters, not PMU
    // state, and remain zero in a feature-off runner.
    uint64_t fetch_fifo_push_count = 0;
    uint64_t fetch_fifo_pop_count = 0;
    uint64_t fetch_fifo_flush_count = 0;
    uint64_t fetch_stale_drop_count = 0;
    uint64_t fetch_stale_drain_cycles = 0;
    uint64_t fetch_epoch_bump_count = 0;
    uint64_t fetch_fifo_occupancy_max = 0;
    uint64_t fetch_fifo_peak_signal_max = 0;
    uint64_t fetch_fifo_overflow = 0;
    uint64_t fetch_epoch_final = 0;
    uint64_t prev_fetch_epoch = 0;

    lcvex_commit_digest::Accumulator commit_digest;
    uint64_t memory_digest = kFnvOffset;
    uint64_t committed_memory_effects = 0;

    const bool trace_enabled = !trace_path.empty();
    std::ofstream trace_file;
    uint64_t trace_records = 0;
    std::string trace_sha;
    std::string trace_git;
    std::string trace_source;
    EventProbe event_probe(probe_enabled);

    if (trace_enabled) {
        trace_git = git_sha_arg.empty() ? git_sha() : git_sha_arg;
        trace_source = source_sha_arg.empty() ? source_sha256(name)
                                               : source_sha_arg;
        trace_file.open(trace_path, std::ios::out | std::ios::trunc);
        if (!trace_file) {
            fprintf(stderr, "无法打开 commit trace %s\n", trace_path.c_str());
            return 2;
        }
        trace_file << "{\"kind\":\"header\",\"schema\":\"lcvex-commit-trace-v1\",";
        trace_file << "\"digest_schema\":\""
                   << lcvex_commit_digest::kSchema << "\",";
        trace_file << "\"name\":\"" << json_escape(name) << "\",";
        trace_file << "\"image\":\"" << json_escape(image) << "\",";
        trace_file << "\"image_sha256\":\"" << json_escape(sha256_file(image))
                   << "\",";
        trace_file << "\"git_sha\":\"" << json_escape(trace_git) << "\",";
        trace_file << "\"measurement_source_sha\":\""
                   << json_escape(trace_git) << "\",";
        trace_file << "\"source_sha256\":\"" << json_escape(trace_source)
                   << "\",";
        trace_file << "\"max_cycles\":" << max_cycles << ",\"params\":\""
                   << json_escape(params) << "\"}\n";
    }

    auto write_trace_commit = [&](uint64_t seq, uint64_t cycle) {
        if (!trace_enabled) return;
        trace_file << "{\"kind\":\"commit\",\"seq\":" << seq
                   << ",\"cycle\":" << cycle
                   << ",\"pc\":\"" << trace_hex_u64(top.commit_pc)
                   << "\",\"insn\":\"" << trace_hex_u32(top.commit_insn)
                   << "\",\"next_pc\":\""
                   << trace_hex_u64(top.commit_next_pc) << "\",\"effects\":{";
        bool first_effect = true;
        auto effect_sep = [&]() {
            if (!first_effect) trace_file << ',';
            first_effect = false;
        };
        if (top.commit_gpr_we) {
            effect_sep();
            trace_file << "\"gpr\":{\"rd\":" << (unsigned)top.commit_gpr_rd
                       << ",\"value\":\""
                       << trace_hex_u64(top.commit_gpr_wdata) << "\"}";
        }
        if (top.commit_gpr2_we) {
            effect_sep();
            trace_file << "\"gpr2\":{\"rd\":" << (unsigned)top.commit_gpr2_rd
                       << ",\"value\":\""
                       << trace_hex_u64(top.commit_gpr2_wdata) << "\"}";
        }
        if (top.commit_gpr3_we) {
            effect_sep();
            trace_file << "\"gpr3\":{\"rd\":" << (unsigned)top.commit_gpr3_rd
                       << ",\"value\":\""
                       << trace_hex_u64(top.commit_gpr3_wdata) << "\"}";
        }
        if (top.commit_sp_we) {
            effect_sep();
            trace_file << "\"sp\":{\"value\":\""
                       << trace_hex_u64(top.commit_sp_wdata) << "\"}";
        }
        if (top.commit_nzcv_we) {
            effect_sep();
            trace_file << "\"nzcv\":\""
                       << trace_hex_u32(top.commit_nzcv).substr(8) << "\"";
        }
        if (top.commit_mem_we || top.commit_mem2_we) {
            effect_sep();
            trace_file << "\"memory\":[";
            bool first_mem = true;
            auto memory_sep = [&]() {
                if (!first_mem) trace_file << ',';
                first_mem = false;
            };
            if (top.commit_mem_we) {
                memory_sep();
                trace_file << "{\"addr\":\""
                           << trace_hex_u64(top.commit_mem_addr)
                           << "\",\"wdata\":\""
                           << trace_hex_u64(top.commit_mem_wdata)
                           << "\",\"strb\":\""
                           << trace_hex_u32(top.commit_mem_strb).substr(6)
                           << "\"}";
            }
            if (top.commit_mem2_we) {
                memory_sep();
                trace_file << "{\"addr\":\""
                           << trace_hex_u64(top.commit_mem2_addr)
                           << "\",\"wdata\":\""
                           << trace_hex_u64(top.commit_mem2_wdata)
                           << "\",\"strb\":\""
                           << trace_hex_u32(top.commit_mem2_strb).substr(6)
                           << "\"}";
            }
            trace_file << ']';
        }
        if (top.commit_exc_valid) {
            effect_sep();
            trace_file << "\"exception\":{\"code\":\""
                       << trace_hex_u32(top.commit_exc_code)
                       << "\",\"esr\":\""
                       << trace_hex_u32(top.commit_exc_esr)
                       << "\",\"far\":\""
                       << trace_hex_u64(top.commit_exc_far) << "\"}";
        }
        if (top.commit_mon_we) {
            effect_sep();
            trace_file << "\"monitor\":{\"valid\":"
                       << (unsigned)top.commit_mon_valid
                       << ",\"addr\":\""
                       << trace_hex_u64(top.commit_mon_addr)
                       << "\",\"data\":\""
                       << trace_hex_u64(top.commit_mon_data)
                       << "\",\"data2\":\""
                       << trace_hex_u64(top.commit_mon_data2) << "\"}";
        }
        unsigned vec_count = top.commit_vec_write_count;
        if (vec_count > 4) vec_count = 4;
        if (vec_count != 0) {
            effect_sep();
            trace_file << "\"vector\":[";
            for (unsigned i = 0; i < vec_count; ++i) {
                if (i != 0) trace_file << ',';
                uint8_t rd = i == 0 ? top.commit_vec_rd0
                            : i == 1 ? top.commit_vec_rd1
                            : i == 2 ? top.commit_vec_rd2
                                      : top.commit_vec_rd3;
                uint64_t lo = i == 0 ? top.commit_vec_wdata0_lo
                              : i == 1 ? top.commit_vec_wdata1_lo
                              : i == 2 ? top.commit_vec_wdata2_lo
                                        : top.commit_vec_wdata3_lo;
                uint64_t hi = i == 0 ? top.commit_vec_wdata0_hi
                              : i == 1 ? top.commit_vec_wdata1_hi
                              : i == 2 ? top.commit_vec_wdata2_hi
                                        : top.commit_vec_wdata3_hi;
                trace_file << "{\"rd\":" << (unsigned)rd
                           << ",\"lo\":\"" << trace_hex_u64(lo)
                           << "\",\"hi\":\"" << trace_hex_u64(hi)
                           << "\"}";
            }
            trace_file << ']';
        }
        if (top.commit_fpcr_we) {
            effect_sep();
            trace_file << "\"fpcr\":\""
                       << trace_hex_u32(top.commit_fpcr_wdata) << "\"";
        }
        if (top.commit_fpsr_we) {
            effect_sep();
            trace_file << "\"fpsr\":\""
                       << trace_hex_u32(top.commit_fpsr_wdata) << "\"";
        }
        trace_file << "},\"fetch\":{\"epoch\":"
                   << (unsigned)top.fetch_epoch
                   << ",\"occupancy\":"
                   << (unsigned)top.fetch_fifo_occupancy
                   << ",\"peak\":" << (unsigned)top.fetch_fifo_peak
                   << ",\"push\":" << (unsigned)top.fetch_fifo_push
                   << ",\"pop\":" << (unsigned)top.fetch_fifo_pop
                   << ",\"flush\":" << (unsigned)top.fetch_fifo_flush
                   << ",\"stale_drain\":"
                   << (unsigned)top.fetch_stale_drain
                   << ",\"stale_drop\":"
                   << (unsigned)top.fetch_stale_rsp_drop << "}}\n";
        ++trace_records;
    };

    for (uint64_t c = 0; c < max_cycles && !done; c++) {
        tick();

        if (top.fetch_epoch != prev_fetch_epoch) {
            fetch_epoch_bump_count++;
            prev_fetch_epoch = top.fetch_epoch;
        }
        fetch_epoch_final = top.fetch_epoch;
        if (top.fetch_fifo_occupancy > fetch_fifo_occupancy_max)
            fetch_fifo_occupancy_max = top.fetch_fifo_occupancy;
        if (top.fetch_fifo_peak > fetch_fifo_peak_signal_max)
            fetch_fifo_peak_signal_max = top.fetch_fifo_peak;
        if (top.fetch_fifo_occupancy > 2)
            fetch_fifo_overflow++;
        if (top.fetch_fifo_push) fetch_fifo_push_count++;
        if (top.fetch_fifo_pop) fetch_fifo_pop_count++;
        if (top.fetch_fifo_flush) fetch_fifo_flush_count++;
        if (top.fetch_stale_rsp_drop) fetch_stale_drop_count++;
        if (top.fetch_stale_drain) fetch_stale_drain_cycles++;

        if (top.commit_valid && top.commit_ready) {
            retired_insn++;
            // Include the complete scalar commit packet and the appended
            // FP/vector effect view. No cycle counter or wall-clock value is
            // hashed, so equivalent off/on runs get the same summary even
            // when their latency differs.
            lcvex_commit_digest::CommitPacket packet{};
            packet.seq = retired_insn;
            packet.pc = top.commit_pc;
            packet.next_pc = top.commit_next_pc;
            packet.insn = top.commit_insn;
            packet.gpr_we = top.commit_gpr_we;
            packet.gpr_rd = top.commit_gpr_rd;
            packet.gpr_wdata = top.commit_gpr_wdata;
            packet.gpr2_we = top.commit_gpr2_we;
            packet.gpr2_rd = top.commit_gpr2_rd;
            packet.gpr2_wdata = top.commit_gpr2_wdata;
            packet.gpr3_we = top.commit_gpr3_we;
            packet.gpr3_rd = top.commit_gpr3_rd;
            packet.gpr3_wdata = top.commit_gpr3_wdata;
            packet.sp_we = top.commit_sp_we;
            packet.sp_wdata = top.commit_sp_wdata;
            packet.nzcv_we = top.commit_nzcv_we;
            packet.nzcv = top.commit_nzcv;
            packet.mem_we = top.commit_mem_we;
            packet.mem_addr = top.commit_mem_addr;
            packet.mem_wdata = top.commit_mem_wdata;
            packet.mem_strb = top.commit_mem_strb;
            packet.mem2_we = top.commit_mem2_we;
            packet.mem2_addr = top.commit_mem2_addr;
            packet.mem2_wdata = top.commit_mem2_wdata;
            packet.mem2_strb = top.commit_mem2_strb;
            packet.exc_valid = top.commit_exc_valid;
            packet.exc_code = top.commit_exc_code;
            packet.exc_esr = top.commit_exc_esr;
            packet.exc_far = top.commit_exc_far;
            packet.mon_we = top.commit_mon_we;
            packet.mon_valid = top.commit_mon_valid;
            packet.mon_addr = top.commit_mon_addr;
            packet.mon_data = top.commit_mon_data;
            packet.mon_data2 = top.commit_mon_data2;
            packet.vec_write_count = top.commit_vec_write_count;
            packet.vec_rd[0] = top.commit_vec_rd0;
            packet.vec_rd[1] = top.commit_vec_rd1;
            packet.vec_rd[2] = top.commit_vec_rd2;
            packet.vec_rd[3] = top.commit_vec_rd3;
            packet.vec_wdata_lo[0] = top.commit_vec_wdata0_lo;
            packet.vec_wdata_lo[1] = top.commit_vec_wdata1_lo;
            packet.vec_wdata_lo[2] = top.commit_vec_wdata2_lo;
            packet.vec_wdata_lo[3] = top.commit_vec_wdata3_lo;
            packet.vec_wdata_hi[0] = top.commit_vec_wdata0_hi;
            packet.vec_wdata_hi[1] = top.commit_vec_wdata1_hi;
            packet.vec_wdata_hi[2] = top.commit_vec_wdata2_hi;
            packet.vec_wdata_hi[3] = top.commit_vec_wdata3_hi;
            packet.fpcr_we = top.commit_fpcr_we;
            packet.fpcr_wdata = top.commit_fpcr_wdata;
            packet.fpsr_we = top.commit_fpsr_we;
            packet.fpsr_wdata = top.commit_fpsr_wdata;
            event_probe.observe_commit(packet, c);
            commit_digest.update(packet);

            if (top.commit_mem_we) {
                committed_memory_effects++;
                digest_u64(&memory_digest, top.commit_mem_addr);
                digest_u64(&memory_digest, top.commit_mem_wdata);
                digest_u8(&memory_digest, top.commit_mem_strb);
            }
            if (top.commit_mem2_we) {
                committed_memory_effects++;
                digest_u64(&memory_digest, top.commit_mem2_addr);
                digest_u64(&memory_digest, top.commit_mem2_wdata);
                digest_u8(&memory_digest, top.commit_mem2_strb);
            }
            write_trace_commit(retired_insn, c);
        }
        if (top.rootp->lcvex_soc_tb__DOT__core__DOT__stall_if)
            stall_if_cycles++;
        if (top.rootp->lcvex_soc_tb__DOT__core__DOT__fetch_pending ||
            top.rootp->lcvex_soc_tb__DOT__core__DOT__fetch_got_data ||
            top.rootp->lcvex_soc_tb__DOT__core__DOT__fetch_translated ||
            top.fetch_stale_drain)
            fetch_wait_cycles++;
        if (top.rootp->lcvex_soc_tb__DOT__core__DOT__flush_id)
            branch_flush_cycles++;
        if (top.rootp->lcvex_soc_tb__DOT__core__DOT__dmem_pending ||
            top.rootp->lcvex_soc_tb__DOT__core__DOT__mem_busy)
            mem_stall_cycles++;
        if (top.rootp->lcvex_soc_tb__DOT__core__DOT__fetch_walk ||
            top.rootp->lcvex_soc_tb__DOT__core__DOT__data_mmu_issue)
            ptw_stall_cycles++;
        if (top.rootp->lcvex_soc_tb__DOT__core__DOT__ex_busy &&
            top.rootp->lcvex_soc_tb__DOT__core__DOT__muldiv_busy)
            muldiv_stall_cycles++;
        if (top.rootp->lcvex_soc_tb__DOT__core__DOT__stall_wb)
            wb_stall_cycles++;
        if (top.rootp->lcvex_soc_tb__DOT__core__DOT__load_use)
            load_use_cycles++;

        if (top.rootp->lcvex_soc_tb__DOT__imem_req_valid &&
            top.rootp->lcvex_soc_tb__DOT__imem_req_ready)
            imem_req_count++;
        if (top.rootp->lcvex_soc_tb__DOT__imem_rsp_valid &&
            top.rootp->lcvex_soc_tb__DOT__imem_rsp_ready)
            imem_rsp_count++;
        if (top.rootp->lcvex_soc_tb__DOT__dmem_req_valid &&
            top.rootp->lcvex_soc_tb__DOT__dmem_req_ready)
            dmem_req_count++;
        if (top.rootp->lcvex_soc_tb__DOT__dmem_rsp_valid &&
            top.rootp->lcvex_soc_tb__DOT__dmem_rsp_ready)
            dmem_rsp_count++;
        if (top.rootp->lcvex_soc_tb__DOT__ptw_req_valid &&
            top.rootp->lcvex_soc_tb__DOT__ptw_req_ready)
            ptw_req_count++;
        if (top.rootp->lcvex_soc_tb__DOT__ptw_rsp_valid &&
            top.rootp->lcvex_soc_tb__DOT__ptw_rsp_ready)
            ptw_rsp_count++;

        if (top.rootp->lcvex_soc_tb__DOT__arb_req_valid &&
            top.rootp->lcvex_soc_tb__DOT__arb_req_accept)
            arb_req_count++;
        if (top.rootp->lcvex_soc_tb__DOT__arb_rsp_valid &&
            top.rootp->lcvex_soc_tb__DOT__arb_rsp_ready)
            arb_rsp_count++;
        if (top.rootp->lcvex_soc_tb__DOT__l2_req_valid &&
            top.rootp->lcvex_soc_tb__DOT__l2_req_accept)
            l2_req_count++;
        if (top.rootp->lcvex_soc_tb__DOT__l2_rsp_valid &&
            top.rootp->lcvex_soc_tb__DOT__l2_rsp_ready)
            l2_rsp_count++;
        if (top.rootp->lcvex_soc_tb__DOT__del_req_valid &&
            top.rootp->lcvex_soc_tb__DOT__del_req_ready)
            del_req_count++;
        if (top.rootp->lcvex_soc_tb__DOT__del_rsp_valid &&
            top.rootp->lcvex_soc_tb__DOT__del_rsp_ready)
            del_rsp_count++;
        if (top.rootp->lcvex_soc_tb__DOT__ram_req_valid &&
            top.rootp->lcvex_soc_tb__DOT__ram_req_accept)
            ram_req_count++;
        if (top.rootp->lcvex_soc_tb__DOT__ram_rsp_valid &&
            top.rootp->lcvex_soc_tb__DOT__ram_rsp_ready)
            ram_rsp_count++;

        if (top.perf_il1_upstream) il1_up++;
        if (top.perf_il1_read_hit) il1_hit++;
        if (top.perf_il1_read_miss) il1_miss++;
        if (top.perf_il1_refill_beat) il1_refill_beat++;
        if (top.perf_il1_downstream) il1_down++;
        if (top.perf_dl1_upstream) dl1_up++;
        if (top.perf_dl1_read_hit) dl1_hit++;
        if (top.perf_dl1_read_miss) dl1_miss++;
        if (top.perf_dl1_write) dl1_write++;
        if (top.perf_dl1_refill_beat) dl1_refill_beat++;
        if (top.perf_dl1_downstream) dl1_down++;
        if (top.perf_l2_upstream) l2_up++;
        if (top.perf_l2_read_hit) l2_hit++;
        if (top.perf_l2_read_miss) l2_miss++;
        if (top.perf_l2_write) l2_write++;
        if (top.perf_l2_refill_beat) l2_refill_beat++;
        if (top.perf_l2_downstream) l2_down++;

        event_probe.observe_cycle(c, top,
                                  top.commit_valid && top.commit_ready);

        if (top.commit_valid && top.commit_mem_we &&
            top.commit_mem_addr == magic) {
            rc = top.commit_mem_wdata;
            done = true;
            cycles = c;
            if (!json_mode) {
                if (rc == 0) {
                    printf("PASS: %s (%llu cycles)\n", name.c_str(),
                           (unsigned long long)c);
                } else {
                    printf("FAIL: %s (rc=%llu, %llu cycles)\n", name.c_str(),
                           (unsigned long long)rc, (unsigned long long)c);
                }
            }
        }
    }
    if (!done) {
        cycles = max_cycles;
        if (!json_mode) {
            printf("FAIL: %s (timeout %llu cycles)\n", name.c_str(),
                   (unsigned long long)max_cycles);
        }
    }

    std::string probe_sha;
    if (probe_enabled) {
        event_probe.finish(cycles, retired_insn);
        const char *probe_status = !commit_digest.valid()
                                        ? "error"
                                        : (done ? (rc == 0 ? "pass" : "fail")
                                                : "timeout");
        if (!event_probe.write_json(probe_path, name, cycles, retired_insn,
                                    commit_digest.value(), memory_digest,
                                    probe_status)) {
            fprintf(stderr, "无法写入 event probe %s\n", probe_path.c_str());
            return 2;
        }
        probe_sha = sha256_file(probe_path);
    }

    if (!commit_digest.valid() && !json_mode) {
        fprintf(stderr,
                "ERROR: commit digest invalid (vector write count exceeds %u)\n",
                (unsigned)lcvex_commit_digest::kMaxVectorWrites);
    }

    if (trace_enabled) {
        const char *trace_status = !commit_digest.valid()
                                       ? "error"
                                       : (done ? (rc == 0 ? "pass" : "fail")
                                               : "timeout");
        trace_file << "{\"kind\":\"footer\",\"digest_schema\":\""
                   << lcvex_commit_digest::kSchema
                   << "\",\"digest_valid\":"
                   << (commit_digest.valid() ? "true" : "false")
                   << ",\"status\":\""
                   << trace_status << "\",\"cycles\":" << cycles
                   << ",\"retired_insn\":" << retired_insn
                   << ",\"commit_digest\":\""
                   << trace_hex_u64(commit_digest.value())
                   << "\",\"memory_digest\":\""
                   << trace_hex_u64(memory_digest) << "\"}\n";
        trace_file.close();
        trace_sha = sha256_file(trace_path);
    }

    auto t_end = std::chrono::steady_clock::now();
    double wall_sec = std::chrono::duration<double>(t_end - t_start).count();
    struct rusage ru {};
    getrusage(RUSAGE_SELF, &ru);
    long rss_kb = ru.ru_maxrss;

    if (json_mode) {
        std::string status = !commit_digest.valid()
                                  ? "error"
                                  : (done ? (rc == 0 ? "pass" : "fail")
                                          : "timeout");
        int ret = !commit_digest.valid() ? 2
                                        : (done ? (rc == 0 ? 0 : 1) : 1);
        std::string git = git_sha_arg.empty() ? git_sha() : git_sha_arg;
        std::string src =
            source_sha_arg.empty() ? source_sha256(name) : source_sha_arg;
        double ipc = cycles ? (double)retired_insn / (double)cycles : 0.0;
        printf("{\n");
        printf("  \"name\": \"%s\",\n", json_escape(name).c_str());
        printf("  \"sha\": \"%s\",\n", json_escape(git).c_str());
        printf("  \"git_sha\": \"%s\",\n", json_escape(git).c_str());
        printf("  \"source_hash\": \"%s\",\n", json_escape(src).c_str());
        printf("  \"source_sha256\": \"%s\",\n", json_escape(src).c_str());
        printf("  \"image_hash\": \"%s\",\n",
               json_escape(sha256_file(image)).c_str());
        printf("  \"image_sha256\": \"%s\",\n",
               json_escape(sha256_file(image)).c_str());
        printf("  \"cycles\": %llu,\n", (unsigned long long)cycles);
        printf("  \"retired_insn\": %llu,\n", (unsigned long long)retired_insn);
        printf("  \"ipc\": %.6f,\n", ipc);
        printf("  \"stall_cycles\": {\n");
        printf("    \"stall_if\": %llu,\n", (unsigned long long)stall_if_cycles);
        printf("    \"fetch_wait\": %llu,\n", (unsigned long long)fetch_wait_cycles);
        printf("    \"branch_flush\": %llu,\n", (unsigned long long)branch_flush_cycles);
        printf("    \"mem_stall\": %llu,\n", (unsigned long long)mem_stall_cycles);
        printf("    \"ptw_stall\": %llu,\n", (unsigned long long)ptw_stall_cycles);
        printf("    \"muldiv_stall\": %llu,\n", (unsigned long long)muldiv_stall_cycles);
        printf("    \"load_use\": %llu,\n", (unsigned long long)load_use_cycles);
        printf("    \"wb_stall\": %llu\n", (unsigned long long)wb_stall_cycles);
        printf("  },\n");
        printf("  \"requests\": {\n");
        printf("    \"imem\": %llu,\n", (unsigned long long)imem_req_count);
        printf("    \"dmem\": %llu,\n", (unsigned long long)dmem_req_count);
        printf("    \"ptw\": %llu,\n", (unsigned long long)ptw_req_count);
        printf("    \"arb\": %llu,\n", (unsigned long long)arb_req_count);
        printf("    \"l2\": %llu,\n", (unsigned long long)l2_req_count);
        printf("    \"delay_router\": %llu,\n", (unsigned long long)del_req_count);
        printf("    \"ram\": %llu\n", (unsigned long long)ram_req_count);
        printf("  },\n");
        printf("  \"responses\": {\n");
        printf("    \"imem\": %llu,\n", (unsigned long long)imem_rsp_count);
        printf("    \"dmem\": %llu,\n", (unsigned long long)dmem_rsp_count);
        printf("    \"ptw\": %llu,\n", (unsigned long long)ptw_rsp_count);
        printf("    \"arb\": %llu,\n", (unsigned long long)arb_rsp_count);
        printf("    \"l2\": %llu,\n", (unsigned long long)l2_rsp_count);
        printf("    \"delay_router\": %llu,\n", (unsigned long long)del_rsp_count);
        printf("    \"ram\": %llu\n", (unsigned long long)ram_rsp_count);
        printf("  },\n");
        printf("  \"cache\": {\n");
        printf("    \"il1\": {\"upstream\":%llu,\"hit\":%llu,\"miss\":%llu,"
               "\"refill_beat\":%llu,\"downstream\":%llu},\n",
               (unsigned long long)il1_up, (unsigned long long)il1_hit,
               (unsigned long long)il1_miss, (unsigned long long)il1_refill_beat,
               (unsigned long long)il1_down);
        printf("    \"dl1\": {\"upstream\":%llu,\"read_hit\":%llu,"
               "\"read_miss\":%llu,\"write\":%llu,\"refill_beat\":%llu,"
               "\"downstream\":%llu},\n",
               (unsigned long long)dl1_up, (unsigned long long)dl1_hit,
               (unsigned long long)dl1_miss, (unsigned long long)dl1_write,
               (unsigned long long)dl1_refill_beat, (unsigned long long)dl1_down);
        printf("    \"l2\": {\"upstream\":%llu,\"read_hit\":%llu,"
               "\"read_miss\":%llu,\"write\":%llu,\"refill_beat\":%llu,"
               "\"downstream\":%llu}\n",
               (unsigned long long)l2_up, (unsigned long long)l2_hit,
               (unsigned long long)l2_miss, (unsigned long long)l2_write,
               (unsigned long long)l2_refill_beat, (unsigned long long)l2_down);
        printf("  },\n");
        bool fifo_enabled =
            params.find("FETCH_FIFO_ENABLE=1") != std::string::npos ||
            params.find("\\\"FETCH_FIFO_ENABLE\\\": 1") != std::string::npos ||
            fetch_fifo_push_count || fetch_fifo_pop_count ||
            fetch_fifo_flush_count || fetch_stale_drop_count ||
            fetch_epoch_bump_count || fetch_fifo_occupancy_max;
        printf("  \"fetch_fifo\": {\n");
        printf("    \"enable\": %d,\n", fifo_enabled ? 1 : 0);
        printf("    \"epoch_final\": %llu,\n",
               (unsigned long long)fetch_epoch_final);
        printf("    \"epoch_bumps\": %llu,\n",
               (unsigned long long)fetch_epoch_bump_count);
        printf("    \"occupancy_max\": %llu,\n",
               (unsigned long long)fetch_fifo_occupancy_max);
        printf("    \"peak_signal_max\": %llu,\n",
               (unsigned long long)fetch_fifo_peak_signal_max);
        printf("    \"push\": %llu,\n",
               (unsigned long long)fetch_fifo_push_count);
        printf("    \"pop\": %llu,\n",
               (unsigned long long)fetch_fifo_pop_count);
        printf("    \"flush\": %llu,\n",
               (unsigned long long)fetch_fifo_flush_count);
        printf("    \"stale_drop\": %llu,\n",
               (unsigned long long)fetch_stale_drop_count);
        printf("    \"stale_drain_cycles\": %llu,\n",
               (unsigned long long)fetch_stale_drain_cycles);
        printf("    \"overflow\": %llu\n",
               (unsigned long long)fetch_fifo_overflow);
        printf("  },\n");
        printf("  \"commit_digest_schema\": \"%s\",\n",
               lcvex_commit_digest::kSchema);
        printf("  \"commit_digest_valid\": %s,\n",
               commit_digest.valid() ? "true" : "false");
        printf("  \"stable_digest\": {\n");
        printf("    \"schema\": \"%s\",\n",
               lcvex_commit_digest::kSchema);
        printf("    \"commit_packet\": \"%016llx\",\n",
               (unsigned long long)commit_digest.value());
        printf("    \"memory_side_effect\": \"%016llx\",\n",
               (unsigned long long)memory_digest);
        printf("    \"committed_memory_effects\": %llu\n",
               (unsigned long long)committed_memory_effects);
        printf("  },\n");
        printf("  \"commit_digest\": \"%016llx\",\n",
               (unsigned long long)commit_digest.value());
        printf("  \"memory_digest\": \"%016llx\",\n",
               (unsigned long long)memory_digest);
        if (trace_enabled) {
            printf("  \"trace\": {\"path\":\"%s\",\"sha256\":\"%s\",\"records\":%llu},\n",
                   json_escape(trace_path).c_str(),
                   json_escape(trace_sha).c_str(),
                   (unsigned long long)trace_records);
        }
        if (probe_enabled) {
            printf("  \"probe\": {\"path\":\"%s\",\"sha256\":\"%s\"},\n",
                   json_escape(probe_path).c_str(),
                   json_escape(probe_sha).c_str());
        }
        printf("  \"measurement_source_sha\": \"%s\",\n",
               json_escape(git).c_str());
        printf("  \"wall_sec\": %.6f,\n", wall_sec);
        printf("  \"rss_kb\": %ld,\n", rss_kb);
        printf("  \"rss\": %.3f,\n", rss_kb / 1024.0);
        printf("  \"status\": \"%s\",\n", status.c_str());
        printf("  \"params\": \"%s\",\n", json_escape(params).c_str());
        printf("  \"max_cycles\": %llu,\n", (unsigned long long)max_cycles);
        printf("  \"returncode\": %d\n", ret);
        printf("}\n");
        return ret;
    }
    if (!done) return 1;
    return rc == 0 ? 0 : 1;
}
