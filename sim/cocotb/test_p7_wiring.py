"""P7-0 SoC wiring smoke.

只验证 FPCR/FPSR 状态访问、FPEN access trap、commit effect 和 checkpoint
restore 同沿边界；不执行或伪造任何 FP/NEON 算术结果。
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ReadOnly, RisingEdge, Timer


BASE = 0x44000000
FPCR_MASK = 0x07C80000
FPSR_MASK = 0xF800009F

_RESTORE_SCALARS = (
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
    "difftest_restore_tcr2_el1", "difftest_restore_contextidr_el1", "difftest_restore_excl_valid",
    "difftest_restore_excl_addr", "difftest_restore_excl_data",
    "difftest_restore_excl_data_hi", "difftest_restore_cntpct",
    "difftest_restore_cntp_cval", "difftest_restore_cntp_ctl",
    "difftest_restore_cntv_cval", "difftest_restore_cntv_ctl",
)


def _clear_restore_ports(dut):
    for name in _RESTORE_SCALARS:
        getattr(dut, name).value = 0
    # RTL exposes V restore as two unpacked 64-bit arrays so C++ can consume
    # them without depending on Verilator's VlWide representation.
    for name in ("difftest_restore_fp_v_lo", "difftest_restore_fp_v_hi"):
        vector = getattr(dut, name)
        for i in range(32):
            vector[i].value = 0
    dut.difftest_restore_cntpct.value = 1


async def _load_words(dut, words):
    dut.rst_n.value = 0
    dut.commit_ready.value = 1
    dut.prog_we.value = 0
    _clear_restore_ports(dut)
    await Timer(1, unit="ns")
    for i, word in enumerate(words):
        dut.prog_we.value = 1
        dut.prog_addr.value = BASE + 4 * i
        dut.prog_strb.value = 0x0F
        dut.prog_wdata.value = word
        await RisingEdge(dut.clk)
    dut.prog_we.value = 0


async def _restore(dut, cpacr, fpcr, fpsr, vectors):
    _clear_restore_ports(dut)
    dut.difftest_restore_pc.value = BASE
    dut.difftest_restore_sp_el1.value = 0
    dut.difftest_restore_nzcv.value = 4
    dut.difftest_restore_el.value = 1
    dut.difftest_restore_sp_sel.value = 1
    dut.difftest_restore_daif.value = 0xF
    dut.difftest_restore_sctlr_el1.value = 0x0000000000C50838
    dut.difftest_restore_cpacr_el1.value = cpacr
    dut.difftest_restore_fpcr.value = fpcr
    dut.difftest_restore_fpsr.value = fpsr
    for i, value in enumerate(vectors):
        dut.difftest_restore_fp_v_lo[i].value = value & ((1 << 64) - 1)
        dut.difftest_restore_fp_v_hi[i].value = value >> 64
    dut.difftest_restore_sys_valid.value = 1
    dut.difftest_restore_fp_valid.value = 1
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)
    await ReadOnly()
    await Timer(1, unit="ns")
    dut.difftest_restore_sys_valid.value = 0
    dut.difftest_restore_fp_valid.value = 0


def _commit(dut):
    return {
        "pc": int(dut.commit_pc.value),
        "insn": int(dut.commit_insn.value),
        "gpr_we": bool(dut.commit_gpr_we.value),
        "gpr_rd": int(dut.commit_gpr_rd.value),
        "gpr_wdata": int(dut.commit_gpr_wdata.value),
        "exc_valid": bool(dut.commit_exc_valid.value),
        "exc_code": int(dut.commit_exc_code.value),
        "fpcr_we": bool(dut.commit_fpcr_we.value),
        "fpcr_wdata": int(dut.commit_fpcr_wdata.value),
        "fpsr_we": bool(dut.commit_fpsr_we.value),
        "fpsr_wdata": int(dut.commit_fpsr_wdata.value),
    }


async def _collect(dut, pcs, max_cycles=1200):
    found = {}
    for _ in range(max_cycles):
        await RisingEdge(dut.clk)
        await ReadOnly()
        if bool(dut.commit_valid.value):
            packet = _commit(dut)
            if packet["pc"] in pcs:
                found[packet["pc"]] = packet
            if len(found) == len(pcs):
                return found
    raise AssertionError(f"未观察到全部提交：found={sorted(found)}")


@cocotb.test()
async def test_p7_state_wiring(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())

    # CPACR.FPEN=11 放行；仅使用 system-state accesses，非 FP 算术。
    words = [
        0xD2800020,       # movz x0, #1（scalar 回归）
        0xD2A00601,       # movz x1, #0x30, lsl #16
        0xD5181041,       # msr cpacr_el1, x1
        0xD53B4402,       # mrs x2, fpcr
        0xD2A0F903,       # movz x3, #0x07c8, lsl #16
        0xD51B4403,       # msr fpcr, x3
        0xD53B4404,       # mrs x4, fpcr
        0xD29FFFE5,       # movz x5, #0xffff
        0xD51B4425,       # msr fpsr, x5
        0xD53B4426,       # mrs x6, fpsr
        0x14000000,       # b .
    ]
    await _load_words(dut, words)
    await _restore(dut, 0x00300000, 0, 0, [0] * 32)
    pcs = {BASE + 4 * i for i in range(len(words))}
    commits = await _collect(dut, pcs)

    assert commits[BASE]["gpr_we"] and commits[BASE]["gpr_wdata"] == 1
    assert commits[BASE + 12]["gpr_rd"] == 2
    assert commits[BASE + 12]["gpr_wdata"] == 0
    assert commits[BASE + 20]["fpcr_we"]
    assert commits[BASE + 20]["fpcr_wdata"] == FPCR_MASK
    assert commits[BASE + 24]["gpr_rd"] == 4
    assert commits[BASE + 24]["gpr_wdata"] == FPCR_MASK
    assert commits[BASE + 32]["fpsr_we"]
    # x5 contains only 0xffff here; the implemented high FPSR bits therefore
    # remain zero while the low architectural mask is retained.
    assert commits[BASE + 32]["fpsr_wdata"] == 0x0000009F
    assert commits[BASE + 36]["gpr_rd"] == 6
    assert commits[BASE + 36]["gpr_wdata"] == 0x0000009F
    assert int(dut.fpcr_state.value) == FPCR_MASK
    assert int(dut.fpsr_state.value) == 0x0000009F
    assert int(dut.fp_cpacr_el1_state.value) == 0x00300000
    assert all(int(dut.fp_v_lo[i].value) == 0 and
               int(dut.fp_v_hi[i].value) == 0 for i in range(32))

    # FPEN=00 的 FPCR access 必须在 ID 级 trap，且保留已恢复的 raw state。
    await Timer(1, unit="ns")
    trap_fpcr = 0x12345678 & FPCR_MASK
    trap_fpsr = 0x87654321 & FPSR_MASK
    vectors = [((0x1000 + i) << 64) | (0x2000 + i) for i in range(32)]
    await _load_words(dut, [0xD53B4400, 0x14000000])
    await _restore(dut, 0, 0x12345678, 0x87654321, vectors)
    trap = (await _collect(dut, {BASE}))[BASE]
    assert trap["exc_valid"] and trap["exc_code"] == 0x07
    assert not trap["gpr_we"]
    assert not trap["fpcr_we"] and not trap["fpsr_we"]
    assert int(dut.fpcr_state.value) == trap_fpcr
    assert int(dut.fpsr_state.value) == trap_fpsr
    assert [int(dut.fp_v_hi[i].value) << 64 | int(dut.fp_v_lo[i].value)
            for i in range(32)] == vectors

    dut._log.info("PASS: P7-0 SoC FPCR/FPSR wiring, trap, restore and scalar boundary")
