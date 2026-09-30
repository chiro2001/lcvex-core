"""M1-A Cocotb 复现：commit_fire valid/ready 背压语义。

与 tb/sv/lcvex_commit_backpressure_tb.sv 等价的独立复现路径：
中途拉低 commit_ready，验证不丢不重、顺序保持、释放后连续提交。
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge

BASE = 0x44000000

_RESTORE_PORTS = (
    "difftest_restore_sys_valid", "difftest_restore_fp_valid",
    "difftest_restore_fpcr", "difftest_restore_fpsr",
    "difftest_restore_pc",
    "difftest_restore_sp_el0", "difftest_restore_sp_el1",
    "difftest_restore_nzcv", "difftest_restore_el",
    "difftest_restore_sp_sel", "difftest_restore_daif",
    "difftest_restore_pan", "difftest_restore_dit",
    "difftest_restore_elr_el1", "difftest_restore_spsr_el1",
    "difftest_restore_vbar_el1", "difftest_restore_sctlr_el1",
    "difftest_restore_tcr_el1", "difftest_restore_ttbr0_el1",
    "difftest_restore_ttbr1_el1", "difftest_restore_mair_el1",
    "difftest_restore_esr_el1", "difftest_restore_far_el1",
    "difftest_restore_par_el1", "difftest_restore_cpacr_el1",
    "difftest_restore_mdscr_el1", "difftest_restore_pmuserenr_el0",
    "difftest_restore_cntkctl_el1",
    "difftest_restore_tpidr_el0", "difftest_restore_tpidrro_el0",
    "difftest_restore_tpidr_el1", "difftest_restore_pir_el1",
    "difftest_restore_pire0_el1", "difftest_restore_zcr_el1",
    "difftest_restore_smcr_el1", "difftest_restore_csselr_el1",
    "difftest_restore_tcr2_el1", "difftest_restore_contextidr_el1", "difftest_restore_excl_valid",
    "difftest_restore_excl_addr", "difftest_restore_excl_data",
    "difftest_restore_excl_data_hi",
    "difftest_restore_cntpct", "difftest_restore_cntp_cval",
    "difftest_restore_cntp_ctl", "difftest_restore_cntv_cval",
    "difftest_restore_cntv_ctl",
)


def _clear_restore_ports(dut):
    for port in _RESTORE_PORTS:
        getattr(dut, port).value = 0
    for port in ("difftest_restore_fp_v_lo", "difftest_restore_fp_v_hi"):
        vector = getattr(dut, port)
        for i in range(32):
            vector[i].value = 0


def _read_packet(dut):
    return {
        "pc": int(dut.commit_pc.value),
        "rd": int(dut.commit_gpr_rd.value),
        "wdata": int(dut.commit_gpr_wdata.value),
        "we": bool(dut.commit_gpr_we.value),
    }


@cocotb.test()
async def test_backpressure_hold(dut):
    dut.rst_n.value = 0
    dut.commit_ready.value = 1
    dut.difftest_wait_release.value = 0
    dut.difftest_wait_cntvct_valid.value = 0
    dut.difftest_wait_cntvct.value = 0
    _clear_restore_ports(dut)
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await ClockCycles(dut.clk, 2)

    # 8 条 movz xN,#(N+1) + b . 自循环
    words = [0xD2800000 | ((i + 1) << 5) | i for i in range(8)] + [0x14000000]
    dut.prog_we.value = 1
    for i, w in enumerate(words):
        dut.prog_addr.value = BASE + 4 * i
        dut.prog_strb.value = 0x0F
        dut.prog_wdata.value = w
        await RisingEdge(dut.clk)
    dut.prog_we.value = 0
    dut.rst_n.value = 1

    packets = []
    consec = max_consec = 0
    while len(packets) < 3:
        await RisingEdge(dut.clk)
        if bool(dut.commit_valid.value):
            packets.append(_read_packet(dut))
            consec += 1
            max_consec = max(max_consec, consec)
        else:
            consec = 0

    # 施加背压：commit_ready=0 保持 7 周期，期间不得出现提交
    dut.commit_ready.value = 0
    for _ in range(7):
        await RisingEdge(dut.clk)
        assert not bool(dut.commit_valid.value), \
            "commit_ready=0 期间出现提交（pc=%#x）" % int(dut.commit_pc.value)
    dut.commit_ready.value = 1

    while len(packets) < 8:
        await RisingEdge(dut.clk)
        if bool(dut.commit_valid.value):
            packets.append(_read_packet(dut))
            consec += 1
            max_consec = max(max_consec, consec)
        else:
            consec = 0

    assert len(packets) == 8, f"提交数 {len(packets)} != 8"
    for i, p in enumerate(packets):
        assert p["pc"] == BASE + 4 * i, \
            f"第 {i} 条提交 pc={p['pc']:#x} 期望 {BASE + 4 * i:#x}"
        assert p["rd"] == i and p["wdata"] == i + 1, \
            f"第 {i} 条 x{p['rd']}=0x{p['wdata']:x} 期望 x{i}={i + 1}"
        assert p["we"], f"第 {i} 条缺少 GPR 写使能"

    # 释放后应观察到至少一次连续提交（排队条目排空）
    assert max_consec >= 2, f"未观察到连续提交（max_consec={max_consec}）"
    dut._log.info("PASS: 背压不丢不重、顺序正确、连续提交 %d 条", max_consec)


async def _wait_commit_pc(dut, expected_pc, max_cycles=160):
    for _ in range(max_cycles):
        await RisingEdge(dut.clk)
        packet_valid = bool(dut.commit_valid.value)
        if packet_valid and int(dut.commit_pc.value) == expected_pc:
            return
    raise AssertionError(f"未观察到 system commit pc={expected_pc:#x}")


async def _wait_decode_pc(dut, expected_pc, max_cycles=160):
    for _ in range(max_cycles):
        await RisingEdge(dut.clk)
        assert not bool(dut.commit_valid.value), \
            "system commit 背压期间产生了未消费提交"
        if (bool(dut.dbg_dec_valid.value) and
                int(dut.dbg_dec_pc.value) == expected_pc):
            return
    raise AssertionError(f"背压期间未观察到 ID pc={expected_pc:#x}")


@cocotb.test()
async def test_system_commit_backpressure(dut):
    """ID-level MSR/trap commit must not change state while ready is low."""
    dut.rst_n.value = 0
    dut.commit_ready.value = 1
    dut.difftest_wait_release.value = 0
    dut.difftest_wait_cntvct_valid.value = 0
    dut.difftest_wait_cntvct.value = 0
    _clear_restore_ports(dut)
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await ClockCycles(dut.clk, 2)

    words = [
        0xD2A00600,  # movz x0,#0x30,lsl#16
        0xD5181040,  # msr cpacr_el1,x0
        0xD2A0F901,  # movz x1,#0x07c8,lsl#16
        0xD51B4401,  # msr fpcr,x1
        0xD53B4402,  # mrs x2,fpcr
        0x14000000,  # b .
    ]
    dut.prog_we.value = 1
    for i, word in enumerate(words):
        dut.prog_addr.value = BASE + 4 * i
        dut.prog_strb.value = 0x0F
        dut.prog_wdata.value = word
        await RisingEdge(dut.clk)
    dut.prog_we.value = 0
    # Establish ready=0 before either ID-level system instruction can fire.
    dut.commit_ready.value = 0
    dut.rst_n.value = 1

    await _wait_decode_pc(dut, BASE + 4)
    for _ in range(8):
        await RisingEdge(dut.clk)
        assert not bool(dut.commit_valid.value), \
            "CPACR MSR 在 commit_ready=0 期间产生了未消费提交"
        assert int(dut.fp_cpacr_el1_state.value) == 0
        assert int(dut.fpcr_state.value) == 0

    dut.commit_ready.value = 1
    await _wait_commit_pc(dut, BASE)
    await _wait_commit_pc(dut, BASE + 4)
    assert int(dut.fp_cpacr_el1_state.value) == 0x00300000

    dut.commit_ready.value = 0
    await _wait_decode_pc(dut, BASE + 12)
    for _ in range(8):
        await RisingEdge(dut.clk)
        assert not bool(dut.commit_valid.value), \
            "FPCR MSR 在 commit_ready=0 期间产生了未消费提交"
        assert int(dut.fpcr_state.value) == 0

    dut.commit_ready.value = 1
    await _wait_commit_pc(dut, BASE + 12)
    assert bool(dut.commit_fpcr_we.value)
    assert int(dut.commit_fpcr_wdata.value) == 0x07C80000
    assert int(dut.fpcr_state.value) == 0x07C80000
    dut._log.info("PASS: system MSR commit 与 commit_ready 原子绑定")
