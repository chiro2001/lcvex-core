#ifndef LCVEX_COMMIT_DIGEST_H
#define LCVEX_COMMIT_DIGEST_H

#include <cstdint>

namespace lcvex_commit_digest {

// This is the digest contract, not the JSONL record-format version.  The
// latter remains lcvex-commit-trace-v1 for compatibility with the stream
// comparator; consumers must check this field before comparing summaries.
inline constexpr const char kSchema[] =
    "lcvex-commit-digest-v2-active-payload";
inline constexpr uint8_t kMaxVectorWrites = 4;
inline constexpr uint64_t kFnvOffset = 1469598103934665603ULL;
inline constexpr uint64_t kFnvPrime = 1099511628211ULL;

struct CommitPacket {
    uint64_t seq = 0;
    uint64_t pc = 0;
    uint64_t next_pc = 0;
    uint32_t insn = 0;

    uint8_t gpr_we = 0;
    uint8_t gpr_rd = 0;
    uint64_t gpr_wdata = 0;
    uint8_t gpr2_we = 0;
    uint8_t gpr2_rd = 0;
    uint64_t gpr2_wdata = 0;
    uint8_t gpr3_we = 0;
    uint8_t gpr3_rd = 0;
    uint64_t gpr3_wdata = 0;

    uint8_t sp_we = 0;
    uint64_t sp_wdata = 0;
    uint8_t nzcv_we = 0;
    uint8_t nzcv = 0;

    uint8_t mem_we = 0;
    uint64_t mem_addr = 0;
    uint64_t mem_wdata = 0;
    uint8_t mem_strb = 0;
    uint8_t mem2_we = 0;
    uint64_t mem2_addr = 0;
    uint64_t mem2_wdata = 0;
    uint8_t mem2_strb = 0;

    uint8_t exc_valid = 0;
    uint32_t exc_code = 0;
    uint32_t exc_esr = 0;
    uint64_t exc_far = 0;

    // mon_we is the top-level validity boundary.  When it is zero, even
    // mon_valid is an inactive payload and is canonicalized to zero.
    uint8_t mon_we = 0;
    uint8_t mon_valid = 0;
    uint64_t mon_addr = 0;
    uint64_t mon_data = 0;
    uint64_t mon_data2 = 0;

    // The raw count is always hashed.  Slots [0, min(count, 4)) are active;
    // all remaining slot payloads are canonicalized to zero.  A count above
    // four is invalid and is never silently converted to four.
    uint8_t vec_write_count = 0;
    uint8_t vec_rd[4] = {0, 0, 0, 0};
    uint64_t vec_wdata_lo[4] = {0, 0, 0, 0};
    uint64_t vec_wdata_hi[4] = {0, 0, 0, 0};

    uint8_t fpcr_we = 0;
    uint32_t fpcr_wdata = 0;
    uint8_t fpsr_we = 0;
    uint32_t fpsr_wdata = 0;
};

class Accumulator {
public:
    explicit Accumulator(uint64_t seed = kFnvOffset)
        : digest_(seed), valid_(true) {}

    // Returns false if this packet violates the v2 contract.  The raw vector
    // count is still included in the deterministic digest, so the invalid
    // condition cannot be hidden by truncation.
    bool update(const CommitPacket &p) {
        feed_u64(p.seq);
        feed_u64(p.pc);
        feed_u64(p.next_pc);
        feed_u32(p.insn);

        feed_enable_payload(p.gpr_we, p.gpr_rd, p.gpr_wdata);
        feed_enable_payload(p.gpr2_we, p.gpr2_rd, p.gpr2_wdata);
        feed_enable_payload(p.gpr3_we, p.gpr3_rd, p.gpr3_wdata);

        feed_u8(p.sp_we);
        feed_u64(p.sp_we ? p.sp_wdata : 0);
        feed_u8(p.nzcv_we);
        feed_u8(p.nzcv_we ? p.nzcv : 0);

        feed_memory(p.mem_we, p.mem_addr, p.mem_wdata, p.mem_strb);
        feed_memory(p.mem2_we, p.mem2_addr, p.mem2_wdata, p.mem2_strb);

        feed_u8(p.exc_valid);
        feed_u32(p.exc_valid ? p.exc_code : 0);
        feed_u32(p.exc_valid ? p.exc_esr : 0);
        feed_u64(p.exc_valid ? p.exc_far : 0);

        feed_u8(p.mon_we);
        feed_u8(p.mon_we ? p.mon_valid : 0);
        feed_u64(p.mon_we ? p.mon_addr : 0);
        feed_u64(p.mon_we ? p.mon_data : 0);
        feed_u64(p.mon_we ? p.mon_data2 : 0);

        feed_u8(p.vec_write_count);
        const bool vector_count_valid =
            p.vec_write_count <= kMaxVectorWrites;
        if (!vector_count_valid) valid_ = false;
        for (uint8_t i = 0; i < kMaxVectorWrites; ++i) {
            const bool active = i < p.vec_write_count;
            feed_u8(active ? p.vec_rd[i] : 0);
            feed_u64(active ? p.vec_wdata_lo[i] : 0);
            feed_u64(active ? p.vec_wdata_hi[i] : 0);
        }

        feed_u8(p.fpcr_we);
        feed_u32(p.fpcr_we ? p.fpcr_wdata : 0);
        feed_u8(p.fpsr_we);
        feed_u32(p.fpsr_we ? p.fpsr_wdata : 0);
        return vector_count_valid;
    }

    uint64_t value() const { return digest_; }
    bool valid() const { return valid_; }

private:
    void feed_u8(uint8_t value) {
        digest_ ^= value;
        digest_ *= kFnvPrime;
    }

    void feed_u32(uint32_t value) {
        for (unsigned i = 0; i < 4; ++i)
            feed_u8(static_cast<uint8_t>(value >> (i * 8)));
    }

    void feed_u64(uint64_t value) {
        for (unsigned i = 0; i < 8; ++i)
            feed_u8(static_cast<uint8_t>(value >> (i * 8)));
    }

    void feed_enable_payload(uint8_t enable, uint8_t rd, uint64_t data) {
        feed_u8(enable);
        feed_u8(enable ? rd : 0);
        feed_u64(enable ? data : 0);
    }

    void feed_memory(uint8_t enable, uint64_t addr, uint64_t data,
                     uint8_t strb) {
        feed_u8(enable);
        feed_u64(enable ? addr : 0);
        feed_u64(enable ? data : 0);
        feed_u8(enable ? strb : 0);
    }

    uint64_t digest_;
    bool valid_;
};

}  // namespace lcvex_commit_digest

#endif  // LCVEX_COMMIT_DIGEST_H
