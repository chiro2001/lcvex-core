"""T-016 core-control probes.

The test deliberately stays at the real ``lcvex_soc_tb`` boundary.  It
checks the system-commit/FP-owner invariant, system instructions immediately
after an FP response, and FCVT integer forwarding into an immediately following
branch.  The held TX_DONE boundary is covered by the companion SV test and the
registered FP/data-MMU overlap regression.  All FP and GPR values are compared
as raw integer bits; no reference model or QEMU result is involved.
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ReadOnly, RisingEdge, Timer


BASE = 0x44000000
MASK64 = (1 << 64) - 1


def movz(rd, imm16, hw=0):
    return 0xD2800000 | ((hw & 3) << 21) | ((imm16 & 0xFFFF) << 5) | (rd & 31)


def cbnz_w(rt, from_index, target_index):
    imm19 = target_index - from_index
    return 0x35000000 | ((imm19 & 0x7FFFF) << 5) | (rt & 31)


_RESTORE_PORTS = (
    "difftest_restore_sys_valid", "difftest_restore_fp_valid",
    "difftest_restore_fpcr", "difftest_restore_fpsr",
    "difftest_restore_pc", "difftest_restore_sp_el0",
    "difftest_restore_sp_el1", "difftest_restore_nzcv",
    "difftest_restore_el", "difftest_restore_sp_sel",
    "difftest_restore_daif", "difftest_restore_pan",
    "difftest_restore_dit", "difftest_restore_ssbs",
    "difftest_restore_uao", "difftest_restore_tco",
    "difftest_restore_allint", "difftest_restore_elr_el1",
    "difftest_restore_spsr_el1", "difftest_restore_vbar_el1",
    "difftest_restore_sctlr_el1", "difftest_restore_tcr_el1",
    "difftest_restore_ttbr0_el1", "difftest_restore_ttbr1_el1",
    "difftest_restore_mair_el1", "difftest_restore_esr_el1",
    "difftest_restore_far_el1", "difftest_restore_par_el1",
    "difftest_restore_cpacr_el1", "difftest_restore_mdscr_el1",
    "difftest_restore_pmuserenr_el0", "difftest_restore_cntkctl_el1",
    "difftest_restore_tpidr_el0", "difftest_restore_tpidrro_el0",
    "difftest_restore_tpidr_el1", "difftest_restore_pir_el1",
    "difftest_restore_pire0_el1", "difftest_restore_zcr_el1",
    "difftest_restore_smcr_el1", "difftest_restore_csselr_el1",
    "difftest_restore_tcr2_el1", "difftest_restore_contextidr_el1",
    "difftest_restore_excl_valid", "difftest_restore_excl_addr",
    "difftest_restore_excl_data", "difftest_restore_excl_data_hi",
    "difftest_restore_cntpct", "difftest_restore_cntp_cval",
    "difftest_restore_cntp_ctl", "difftest_restore_cntv_cval",
    "difftest_restore_cntv_ctl",
)


def clear_restore(dut):
    for name in _RESTORE_PORTS:
        getattr(dut, name).value = 0
    for name in ("difftest_restore_fp_v_lo", "difftest_restore_fp_v_hi"):
        vector = getattr(dut, name)
        for index in range(32):
            vector[index].value = 0


async def load_words(dut, words):
    dut.rst_n.value = 0
    dut.commit_ready.value = 1
    dut.prog_we.value = 0
    clear_restore(dut)
    await Timer(1, unit="ns")
    for index, word in enumerate(words):
        dut.prog_we.value = 1
        dut.prog_addr.value = BASE + index * 4
        dut.prog_strb.value = 0x0F
        dut.prog_wdata.value = word
        await RisingEdge(dut.clk)
    dut.prog_we.value = 0


async def restore(dut, vectors=None, cpacr=0x00300000):
    vectors = vectors or {}
    clear_restore(dut)
    dut.difftest_restore_pc.value = BASE
    dut.difftest_restore_nzcv.value = 4
    dut.difftest_restore_el.value = 1
    dut.difftest_restore_sp_sel.value = 1
    dut.difftest_restore_daif.value = 0xF
    dut.difftest_restore_sctlr_el1.value = 0x0000000000C50838
    dut.difftest_restore_cpacr_el1.value = cpacr
    dut.difftest_restore_fpcr.value = 0
    dut.difftest_restore_fpsr.value = 0
    dut.difftest_restore_cntpct.value = 1
    for index, value in vectors.items():
        dut.difftest_restore_fp_v_lo[index].value = value & MASK64
        dut.difftest_restore_fp_v_hi[index].value = (value >> 64) & MASK64
    dut.difftest_restore_sys_valid.value = 1
    dut.difftest_restore_fp_valid.value = 1
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)
    await ReadOnly()
    await Timer(1, unit="ns")
    dut.difftest_restore_sys_valid.value = 0
    dut.difftest_restore_fp_valid.value = 0


def packet(dut):
    return {
        "pc": int(dut.commit_pc.value) & MASK64,
        "next_pc": int(dut.commit_next_pc.value) & MASK64,
        "insn": int(dut.commit_insn.value),
        "gpr_we": bool(dut.commit_gpr_we.value),
        "gpr_rd": int(dut.commit_gpr_rd.value),
        "gpr_wdata": int(dut.commit_gpr_wdata.value) & MASK64,
        "fpcr_we": bool(dut.commit_fpcr_we.value),
        "fpcr_wdata": int(dut.commit_fpcr_wdata.value),
        "exc_valid": bool(dut.commit_exc_valid.value),
        "exc_code": int(dut.commit_exc_code.value),
    }


def bval(signal):
    return bool(int(signal.value))


def check_owner_invariant(dut):
    core = dut.core
    # R19: a raw wrapper response must be accepted by the empty core-side
    # elastic slot independently of WB/fetch-fault backpressure.  Once the
    # slot is occupied, the core-facing valid/payload pair is the only held
    # response visible to this test.
    if bval(core.fp_exec_rsp_valid) and not bval(core.fp_rsp_hold_valid):
        assert bval(core.fp_exec_rsp_ready), (
            "raw FP response remained coupled to core-side backpressure"
        )
    if bval(core.fp_rsp_hold_valid):
        assert not bval(core.fp_exec_rsp_valid), (
            "FP response hold overlapped a second wrapper response"
        )
    if bval(core.sys_commit):
        active = (bval(core.fp_tx_active) or bval(core.fp_tx_candidate) or
                  bval(core.fp_tx_issued) or bval(core.fp_tx_busy) or
                  bval(core.fp_rsp_valid))
        assert not active, "sys_commit coexisted with an active FP owner/response"
        assert not bval(core.fp_tx_kill), "sys_commit still asserted fp_tx_kill"


def check_msr_fpcr(pkt, _core):
    assert pkt["fpcr_we"]
    assert pkt["fpcr_wdata"] == 0x07C80000


def check_eret(pkt, _core):
    assert not pkt["exc_valid"]


def check_udef(pkt, _core):
    assert pkt["exc_valid"] and pkt["exc_code"] == 0


def check_wfi(pkt, core):
    assert not pkt["exc_valid"] and bval(core.wfi_idle)


async def run_system_case(dut, words, system_index, system_insn, name,
                          check_packet):
    await load_words(dut, words)
    await restore(dut)
    core = dut.core
    fp_seen = False
    for _ in range(1600):
        await RisingEdge(dut.clk)
        await ReadOnly()
        check_owner_invariant(dut)
        if bval(dut.commit_valid):
            pkt = packet(dut)
            if pkt["pc"] == BASE + (system_index - 1) * 4:
                fp_seen = True
            if pkt["pc"] == BASE + system_index * 4:
                assert pkt["insn"] == system_insn, name
                check_packet(pkt, core)
                assert fp_seen, f"{name}: system commit overtook the FP response"
                await Timer(1, unit="ns")
                return
    raise AssertionError(f"{name}: system instruction did not commit")


async def fcvt_branch_case(dut, unsigned_convert):
    # 3.5 -> 3.  The CBNZ immediately following FCVT must see the raw GPR
    # response, skip the bad marker and commit the taken marker.
    fcvt = 0x1E3900E9 if unsigned_convert else 0x1E3800E9
    name = "FCVTZU" if unsigned_convert else "FCVTZS"
    words = [fcvt, cbnz_w(9, 1, 3), movz(12, 0xBAD),
             movz(12, 0xA56), 0x14000000]
    await load_words(dut, words)
    await restore(dut, vectors={7: 0x40600000})
    core = dut.core
    raw_seen = False
    fcvt_seen = False
    bad_seen = False
    target_seen = False

    for _ in range(1800):
        await RisingEdge(dut.clk)
        await ReadOnly()
        check_owner_invariant(dut)
        if bval(core.fp_rsp_valid) and int(core.fp_ex_int_result.value) == 3:
            raw_seen = True
        if bval(dut.commit_valid):
            pkt = packet(dut)
            if pkt["pc"] == BASE and pkt["gpr_we"]:
                assert pkt["gpr_rd"] == 9 and pkt["gpr_wdata"] == 3
                fcvt_seen = True
            elif pkt["pc"] == BASE + 8:
                bad_seen = True
            elif pkt["pc"] == BASE + 12:
                assert pkt["gpr_we"] and pkt["gpr_rd"] == 12
                assert pkt["gpr_wdata"] == 0xA56
                target_seen = True
                break
    await Timer(1, unit="ns")
    assert raw_seen, f"{name}: raw FCVT GPR response was not visible"
    assert fcvt_seen, f"{name}: FCVT GPR commit missing"
    assert not bad_seen, f"{name}: CBNZ used stale/zero GPR value"
    assert target_seen, f"{name}: CBNZ target was not committed"


@cocotb.test()
async def test_r18_core_syskill(dut):
    """Run the T-016 owner, system-boundary and FCVT forwarding probes."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())

    await run_system_case(
        dut, [movz(10, 0x07C8, 1), 0x1E202802, 0xD51B440A,
              0x14000000],
        2, 0xD51B440A, "MSR_FPCR",
        check_msr_fpcr,
    )
    await run_system_case(
        dut, [movz(11, 0x4400, 1), 0xD518402B,
              movz(10, 0x30, 1), 0xD518104A,
              0x1E202802, 0xD69F03E0, 0x14000000],
        5, 0xD69F03E0, "ERET",
        check_eret,
    )
    await run_system_case(
        dut, [0x1E202802, 0x00000000, 0x14000000],
        1, 0x00000000, "UDEF",
        check_udef,
    )
    await run_system_case(
        dut, [0x1E202802, 0xD503207F, 0x14000000],
        1, 0xD503207F, "WFI",
        check_wfi,
    )

    await fcvt_branch_case(dut, unsigned_convert=False)
    await fcvt_branch_case(dut, unsigned_convert=True)
