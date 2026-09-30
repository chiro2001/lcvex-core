#include "commit_digest.h"

#include <cassert>
#include <cstdint>
#include <cstdio>

using lcvex_commit_digest::Accumulator;
using lcvex_commit_digest::CommitPacket;

static uint64_t digest(const CommitPacket &packet, bool *valid = nullptr) {
    Accumulator accumulator;
    bool ok = accumulator.update(packet);
    if (valid) *valid = accumulator.valid();
    assert(ok == accumulator.valid());
    return accumulator.value();
}

static CommitPacket baseline() {
    CommitPacket p;
    p.seq = 7;
    p.pc = 0x44000020;
    p.next_pc = 0x44000024;
    p.insn = 0x91000400;
    return p;
}

static void expect_equal_when_inactive() {
    const CommitPacket zero = baseline();
    CommitPacket changed = zero;
    changed.gpr_rd = 31;
    changed.gpr_wdata = 0x1111222233334444ULL;
    changed.gpr2_rd = 30;
    changed.gpr2_wdata = 0x5555666677778888ULL;
    changed.gpr3_rd = 29;
    changed.gpr3_wdata = 0x9999aaaabbbbccccULL;
    changed.sp_wdata = 0x123456789abcdef0ULL;
    changed.nzcv = 0xf;
    changed.mem_addr = 0x1000;
    changed.mem_wdata = 0xdeadbeef;
    changed.mem_strb = 0xff;
    changed.mem2_addr = 0x2000;
    changed.mem2_wdata = 0xcafebabe;
    changed.mem2_strb = 0x0f;
    changed.exc_code = 0x11;
    changed.exc_esr = 0x22;
    changed.exc_far = 0x3333;
    changed.mon_valid = 1;
    changed.mon_addr = 0x4000;
    changed.mon_data = 0x5555;
    changed.mon_data2 = 0x6666;
    changed.vec_rd[0] = 3;
    changed.vec_wdata_lo[0] = 0x7777;
    changed.vec_wdata_hi[0] = 0x8888;
    changed.vec_rd[3] = 4;
    changed.vec_wdata_lo[3] = 0x9999;
    changed.vec_wdata_hi[3] = 0xaaaa;
    changed.fpcr_wdata = 0xbbbb;
    changed.fpsr_wdata = 0xcccc;

    // Every changed payload above is inactive in this packet.
    assert(digest(zero) == digest(changed));

    changed = zero;
    changed.gpr_we = 1;
    changed.gpr_rd = 1;
    changed.gpr_wdata = 0x1111;
    assert(digest(zero) != digest(changed));
    changed = zero;
    changed.gpr2_we = 1;
    changed.gpr2_rd = 2;
    changed.gpr2_wdata = 0x2222;
    assert(digest(zero) != digest(changed));
    changed = zero;
    changed.gpr3_we = 1;
    changed.gpr3_rd = 3;
    changed.gpr3_wdata = 0x3333;
    assert(digest(zero) != digest(changed));
    changed = zero;
    changed.sp_we = 1;
    changed.sp_wdata = 0x4444;
    assert(digest(zero) != digest(changed));
    changed = zero;
    changed.nzcv_we = 1;
    changed.nzcv = 0xa;
    assert(digest(zero) != digest(changed));
    changed = zero;
    changed.mem_we = 1;
    changed.mem_addr = 0x1000;
    changed.mem_wdata = 0x5555;
    changed.mem_strb = 0xff;
    assert(digest(zero) != digest(changed));
    changed = zero;
    changed.mem2_we = 1;
    changed.mem2_addr = 0x2000;
    changed.mem2_wdata = 0x6666;
    changed.mem2_strb = 0x0f;
    assert(digest(zero) != digest(changed));
    changed = zero;
    changed.exc_valid = 1;
    changed.exc_code = 0x11;
    changed.exc_esr = 0x22;
    changed.exc_far = 0x7777;
    assert(digest(zero) != digest(changed));
    changed = zero;
    changed.mon_we = 1;
    changed.mon_valid = 1;
    changed.mon_addr = 0x3000;
    changed.mon_data = 0x8888;
    changed.mon_data2 = 0x9999;
    assert(digest(zero) != digest(changed));
    changed = zero;
    changed.vec_write_count = 1;
    changed.vec_rd[0] = 4;
    changed.vec_wdata_lo[0] = 0xaaaa;
    changed.vec_wdata_hi[0] = 0xbbbb;
    assert(digest(zero) != digest(changed));
    changed = zero;
    changed.fpcr_we = 1;
    changed.fpcr_wdata = 0x1234;
    assert(digest(zero) != digest(changed));
    changed = zero;
    changed.fpsr_we = 1;
    changed.fpsr_wdata = 0x5678;
    assert(digest(zero) != digest(changed));
}

template <typename Mutator>
static void expect_digest_change(const CommitPacket &base, Mutator mutate) {
    CommitPacket changed = base;
    mutate(changed);
    assert(digest(base) != digest(changed));
}

static void expect_architecture_fields_and_active_payload_sensitive() {
    const CommitPacket base = baseline();

    // Every assertion below starts from the same base packet.  This prevents
    // an earlier mutation from masking which active field is being tested.
    expect_digest_change(base, [](CommitPacket &p) { p.seq++; });
    expect_digest_change(base, [](CommitPacket &p) { p.pc++; });
    expect_digest_change(base, [](CommitPacket &p) { p.next_pc++; });
    expect_digest_change(base, [](CommitPacket &p) { p.insn ^= 1; });

    expect_digest_change(base, [](CommitPacket &p) { p.gpr_we = 1; });
    CommitPacket gpr1 = base;
    gpr1.gpr_we = 1;
    gpr1.gpr_rd = 1;
    gpr1.gpr_wdata = 1;
    expect_digest_change(gpr1, [](CommitPacket &p) { p.gpr_rd++; });
    expect_digest_change(gpr1, [](CommitPacket &p) { p.gpr_wdata++; });

    expect_digest_change(base, [](CommitPacket &p) { p.gpr2_we = 1; });
    CommitPacket gpr2 = base;
    gpr2.gpr2_we = 1;
    gpr2.gpr2_rd = 2;
    gpr2.gpr2_wdata = 2;
    expect_digest_change(gpr2, [](CommitPacket &p) { p.gpr2_rd++; });
    expect_digest_change(gpr2, [](CommitPacket &p) { p.gpr2_wdata++; });

    expect_digest_change(base, [](CommitPacket &p) { p.gpr3_we = 1; });
    CommitPacket gpr3 = base;
    gpr3.gpr3_we = 1;
    gpr3.gpr3_rd = 3;
    gpr3.gpr3_wdata = 3;
    expect_digest_change(gpr3, [](CommitPacket &p) { p.gpr3_rd++; });
    expect_digest_change(gpr3, [](CommitPacket &p) { p.gpr3_wdata++; });

    expect_digest_change(base, [](CommitPacket &p) { p.sp_we = 1; });
    CommitPacket sp = base;
    sp.sp_we = 1;
    sp.sp_wdata = 1;
    expect_digest_change(sp, [](CommitPacket &p) { p.sp_wdata++; });

    expect_digest_change(base, [](CommitPacket &p) { p.nzcv_we = 1; });
    CommitPacket nzcv = base;
    nzcv.nzcv_we = 1;
    nzcv.nzcv = 1;
    expect_digest_change(nzcv, [](CommitPacket &p) { p.nzcv++; });

    expect_digest_change(base, [](CommitPacket &p) { p.mem_we = 1; });
    CommitPacket mem1 = base;
    mem1.mem_we = 1;
    mem1.mem_addr = 1;
    mem1.mem_wdata = 2;
    mem1.mem_strb = 3;
    expect_digest_change(mem1, [](CommitPacket &p) { p.mem_addr++; });
    expect_digest_change(mem1, [](CommitPacket &p) { p.mem_wdata++; });
    expect_digest_change(mem1, [](CommitPacket &p) { p.mem_strb++; });

    expect_digest_change(base, [](CommitPacket &p) { p.mem2_we = 1; });
    CommitPacket mem2 = base;
    mem2.mem2_we = 1;
    mem2.mem2_addr = 1;
    mem2.mem2_wdata = 2;
    mem2.mem2_strb = 3;
    expect_digest_change(mem2, [](CommitPacket &p) { p.mem2_addr++; });
    expect_digest_change(mem2, [](CommitPacket &p) { p.mem2_wdata++; });
    expect_digest_change(mem2, [](CommitPacket &p) { p.mem2_strb++; });

    expect_digest_change(base, [](CommitPacket &p) { p.exc_valid = 1; });
    CommitPacket exception = base;
    exception.exc_valid = 1;
    exception.exc_code = 1;
    exception.exc_esr = 2;
    exception.exc_far = 3;
    expect_digest_change(exception, [](CommitPacket &p) { p.exc_code++; });
    expect_digest_change(exception, [](CommitPacket &p) { p.exc_esr++; });
    expect_digest_change(exception, [](CommitPacket &p) { p.exc_far++; });

    expect_digest_change(base, [](CommitPacket &p) { p.mon_we = 1; });
    CommitPacket monitor = base;
    monitor.mon_we = 1;
    monitor.mon_valid = 1;
    monitor.mon_addr = 1;
    monitor.mon_data = 2;
    monitor.mon_data2 = 3;
    expect_digest_change(monitor, [](CommitPacket &p) { p.mon_valid = 0; });
    expect_digest_change(monitor, [](CommitPacket &p) { p.mon_addr++; });
    expect_digest_change(monitor, [](CommitPacket &p) { p.mon_data++; });
    expect_digest_change(monitor, [](CommitPacket &p) { p.mon_data2++; });

    expect_digest_change(base, [](CommitPacket &p) { p.vec_write_count = 1; });
    expect_digest_change(base, [](CommitPacket &p) { p.vec_write_count = 2; });
    CommitPacket vector = base;
    vector.vec_write_count = 4;
    for (uint8_t i = 0; i < 4; ++i) {
        vector.vec_rd[i] = static_cast<uint8_t>(i + 1);
        vector.vec_wdata_lo[i] = static_cast<uint64_t>(i + 2);
        vector.vec_wdata_hi[i] = static_cast<uint64_t>(i + 3);
        expect_digest_change(vector, [i](CommitPacket &p) {
            p.vec_rd[i]++;
        });
        expect_digest_change(vector, [i](CommitPacket &p) {
            p.vec_wdata_lo[i]++;
        });
        expect_digest_change(vector, [i](CommitPacket &p) {
            p.vec_wdata_hi[i]++;
        });
    }

    expect_digest_change(base, [](CommitPacket &p) { p.fpcr_we = 1; });
    CommitPacket fpcr = base;
    fpcr.fpcr_we = 1;
    fpcr.fpcr_wdata = 1;
    expect_digest_change(fpcr, [](CommitPacket &p) { p.fpcr_wdata++; });

    expect_digest_change(base, [](CommitPacket &p) { p.fpsr_we = 1; });
    CommitPacket fpsr = base;
    fpsr.fpsr_we = 1;
    fpsr.fpsr_wdata = 1;
    expect_digest_change(fpsr, [](CommitPacket &p) { p.fpsr_wdata++; });
}

static void expect_vector_tail_inactive() {
    CommitPacket base = baseline();
    base.vec_write_count = 1;
    base.vec_rd[0] = 1;
    base.vec_wdata_lo[0] = 2;
    base.vec_wdata_hi[0] = 3;
    for (uint8_t i = 1; i < 4; ++i) {
        CommitPacket changed = base;
        changed.vec_rd[i] = static_cast<uint8_t>(i + 10);
        changed.vec_wdata_lo[i] = static_cast<uint64_t>(i + 20);
        changed.vec_wdata_hi[i] = static_cast<uint64_t>(i + 30);
        assert(digest(base) == digest(changed));
    }
}

static void expect_vector_count_guard() {
    CommitPacket p = baseline();
    p.vec_write_count = 4;
    p.vec_rd[3] = 31;
    bool valid = false;
    (void)digest(p, &valid);
    assert(valid);

    p.vec_write_count = 5;
    const uint64_t invalid_digest = digest(p, &valid);
    assert(!valid);
    assert(invalid_digest != digest(baseline()));
}

static void expect_golden_and_deterministic() {
    CommitPacket p = baseline();
    p.gpr_we = 1;
    p.gpr_rd = 5;
    p.gpr_wdata = 0x0102030405060708ULL;
    p.sp_we = 1;
    p.sp_wdata = 0x1112131415161718ULL;
    p.nzcv_we = 1;
    p.nzcv = 0xa;
    p.mem_we = 1;
    p.mem_addr = 0x2122232425262728ULL;
    p.mem_wdata = 0x3132333435363738ULL;
    p.mem_strb = 0x5a;
    p.mon_we = 1;
    p.mon_valid = 1;
    p.mon_addr = 0x4142434445464748ULL;
    p.mon_data = 0x5152535455565758ULL;
    p.mon_data2 = 0x6162636465666768ULL;
    p.vec_write_count = 2;
    p.vec_rd[0] = 6;
    p.vec_wdata_lo[0] = 0x7172737475767778ULL;
    p.vec_wdata_hi[0] = 0x8182838485868788ULL;
    p.vec_rd[1] = 7;
    p.vec_wdata_lo[1] = 0x9192939495969798ULL;
    p.vec_wdata_hi[1] = 0xa1a2a3a4a5a6a7a8ULL;
    p.fpcr_we = 1;
    p.fpcr_wdata = 0xb1b2b3b4U;
    p.fpsr_we = 1;
    p.fpsr_wdata = 0xc1c2c3c4U;

    const uint64_t first = digest(p);
    const uint64_t second = digest(p);
    assert(first == second);
    // Filled from the production helper and kept as a stable cross-host
    // golden for field order, widths, and little-endian byte feeding.
    constexpr uint64_t kGolden = 0x8b782b3f31381149ULL;
    if (first != kGolden) {
        std::fprintf(stderr, "golden digest mismatch: got %016llx\n",
                     static_cast<unsigned long long>(first));
        assert(false);
    }
}

int main() {
    expect_equal_when_inactive();
    expect_architecture_fields_and_active_payload_sensitive();
    expect_vector_tail_inactive();
    expect_vector_count_guard();
    expect_golden_and_deterministic();
    std::puts("PASS: commit digest v2 helper fixtures");
    return 0;
}
