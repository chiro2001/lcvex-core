"""P7-1 scalar FP pipeline test.

测试只使用 AArch64 raw instruction encodings 和 raw V/FPSR/NZCV 断言；
不把 host Python float 当作 RTL oracle。
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ReadOnly, RisingEdge, Timer


BASE = 0x44000000
MASK64 = (1 << 64) - 1


def fp3(base, rd, rn, rm):
    return base | (rm << 16) | (rn << 5) | rd


def fcmp(rn, rm):
    return 0x1E202000 | (rm << 16) | (rn << 5)


def movz(rd, imm16, hw=0):
    return 0xD2800000 | (hw << 21) | (imm16 << 5) | rd


def fp_mem(base, rt, rn, imm12=0):
    return base | (imm12 << 10) | (rn << 5) | rt


def _clear_restore(dut):
    scalar_ports = (
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
    for name in scalar_ports:
        getattr(dut, name).value = 0
    for name in ("difftest_restore_fp_v_lo", "difftest_restore_fp_v_hi"):
        vec = getattr(dut, name)
        for i in range(32):
            vec[i].value = 0


async def _load_words(dut, words):
    # A caller may invoke this helper immediately after ReadOnly while
    # iterating several negative cases; leave that phase before driving reset.
    await Timer(1, unit="ns")
    dut.rst_n.value = 0
    dut.commit_ready.value = 1
    dut.prog_we.value = 0
    _clear_restore(dut)
    await Timer(1, unit="ns")
    for i, word in enumerate(words):
        dut.prog_we.value = 1
        dut.prog_addr.value = BASE + 4 * i
        dut.prog_strb.value = 0x0F
        dut.prog_wdata.value = word
        await RisingEdge(dut.clk)
    dut.prog_we.value = 0


async def _restore_fp_enabled(dut):
    _clear_restore(dut)
    dut.difftest_restore_pc.value = BASE
    dut.difftest_restore_nzcv.value = 4
    dut.difftest_restore_el.value = 1
    dut.difftest_restore_sp_sel.value = 1
    dut.difftest_restore_daif.value = 0xF
    dut.difftest_restore_sctlr_el1.value = 0x0000000000C50838
    dut.difftest_restore_cpacr_el1.value = 0x00300000
    dut.difftest_restore_cntpct.value = 1
    dut.difftest_restore_sys_valid.value = 1
    dut.difftest_restore_fp_valid.value = 1
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)
    await ReadOnly()
    await Timer(1, unit="ns")
    dut.difftest_restore_sys_valid.value = 0
    dut.difftest_restore_fp_valid.value = 0


def _packet(dut):
    vec_count = int(dut.commit_vec_write_count.value)
    vectors = []
    for i in range(vec_count):
        lo = int(getattr(dut, f"commit_vec_wdata{i}_lo").value)
        hi = int(getattr(dut, f"commit_vec_wdata{i}_hi").value)
        vectors.append((int(getattr(dut, f"commit_vec_rd{i}").value),
                        (hi << 64) | lo))
    return {
        "pc": int(dut.commit_pc.value),
        "insn": int(dut.commit_insn.value),
        "gpr_we": bool(dut.commit_gpr_we.value),
        "gpr_rd": int(dut.commit_gpr_rd.value),
        "gpr_wdata": int(dut.commit_gpr_wdata.value) & MASK64,
        "nzcv_we": bool(dut.commit_nzcv_we.value),
        "nzcv": int(dut.commit_nzcv.value),
        "mem_we": bool(dut.commit_mem_we.value),
        "mem_addr": int(dut.commit_mem_addr.value) & MASK64,
        "mem_wdata": int(dut.commit_mem_wdata.value) & MASK64,
        "mem_strb": int(dut.commit_mem_strb.value),
        "vec": vectors,
        "fpcr_we": bool(dut.commit_fpcr_we.value),
        "fpsr_we": bool(dut.commit_fpsr_we.value),
        "fpsr_wdata": int(dut.commit_fpsr_wdata.value),
        "exc_valid": bool(dut.commit_exc_valid.value),
        "exc_code": int(dut.commit_exc_code.value),
    }


@cocotb.test()
async def test_p7_fp_scalar(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    data_addr = BASE + 0x1000
    words = [
        0x1E2E1000,                  # fmov s0, #1.0
        0x1E201001,                  # fmov s1, #2.0
        fp3(0x1E202800, 2, 0, 1),    # fadd s2, s0, s1
        fp3(0x1E203800, 3, 1, 0),    # fsub s3, s1, s0
        fp3(0x1E200800, 4, 0, 1),    # fmul s4, s0, s1
        fp3(0x1E201800, 5, 1, 0),    # fdiv s5, s1, s0
        fcmp(2, 1),                  # fcmp s2, s1 -> greater
        movz(10, 0x4400, 1),
        fp_mem(0xBD000000, 2, 10),    # str s2, [x10]
        fp_mem(0xBD400000, 6, 10),    # ldr s6, [x10]
        0x1E6E1008,                  # fmov d8, #1.0
        0x1E601009,                  # fmov d9, #2.0
        fp3(0x1E602800, 10, 8, 9),   # fadd d10, d8, d9
        0x14000000,                  # b .
    ]
    await _load_words(dut, words)
    await _restore_fp_enabled(dut)

    packets = []
    for _ in range(4000):
        await RisingEdge(dut.clk)
        await ReadOnly()
        if bool(dut.commit_valid.value):
            packets.append(_packet(dut))
            if len(packets) == len(words):
                break
    assert len(packets) == len(words), f"提交数量错误：{len(packets)}"

    expected_v = {
        0: 0x3F800000,
        1: 0x40000000,
        2: 0x40400000,
        3: 0x3F800000,
        4: 0x40000000,
        5: 0x40000000,
        6: 0x40400000,
        8: 0x3FF0000000000000,
        9: 0x4000000000000000,
        10: 0x4008000000000000,
    }
    for packet in packets:
        for rd, value in packet["vec"]:
            assert value == expected_v[rd], (
                f"pc=0x{packet['pc']:x}: V{rd}=0x{value:032x}, "
                f"want=0x{expected_v[rd]:032x}")

    cmp_packet = packets[6]
    assert cmp_packet["nzcv_we"] and cmp_packet["nzcv"] == 0b0010
    store_packet = packets[8]
    assert (store_packet["mem_we"] and store_packet["mem_addr"] == data_addr - 0x1000 and
            store_packet["mem_wdata"] == 0x40400000 and
            store_packet["mem_strb"] == 0x0F)
    assert packets[9]["vec"] == [(6, 0x40400000)]
    assert int(dut.fp_v_hi[2].value) == 0
    assert int(dut.fp_v_lo[2].value) == 0x40400000
    assert int(dut.fpsr_state.value) == 0
    dut._log.info("PASS: P7-1 scalar FP S/D pipeline, compare and scalar memory")


@cocotb.test()
async def test_p7_fp_access_trap(dut):
    # 第二个独立用例重新装载并保持 FPEN=00，检查 trap 没有 V effect。
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    words = [0x1E2E1000, 0x14000000]  # fmov s0,#1.0; b .
    await _load_words(dut, words)
    _clear_restore(dut)
    dut.difftest_restore_pc.value = BASE
    dut.difftest_restore_nzcv.value = 4
    dut.difftest_restore_el.value = 1
    dut.difftest_restore_sp_sel.value = 1
    dut.difftest_restore_daif.value = 0xF
    dut.difftest_restore_sctlr_el1.value = 0x0000000000C50838
    dut.difftest_restore_cpacr_el1.value = 0
    dut.difftest_restore_cntpct.value = 1
    dut.difftest_restore_sys_valid.value = 1
    dut.difftest_restore_fp_valid.value = 1
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)
    await ReadOnly()
    await Timer(1, unit="ns")
    dut.difftest_restore_sys_valid.value = 0
    dut.difftest_restore_fp_valid.value = 0

    first = None
    for _ in range(600):
        await RisingEdge(dut.clk)
        await ReadOnly()
        if bool(dut.commit_valid.value) and int(dut.commit_pc.value) == BASE:
            first = _packet(dut)
            break
    assert first is not None
    assert first["exc_valid"] and first["exc_code"] == 0x07
    assert not first["vec"] and not first["fpcr_we"] and not first["fpsr_we"]
    assert int(dut.fp_v_lo[0].value) == 0
    dut._log.info("PASS: FPEN trap has no V/FPSR side effect")


@cocotb.test()
async def test_p7_fp_scalar_fault_no_effect(dut):
    """An allowed FP load fault must not manufacture a V destination."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    words = [
        movz(10, 0x5000, 1),             # invalid non-MMIO address
        fp_mem(0xBD400000, 0, 10),       # ldr s0, [x10]
        0x14000000,
    ]
    await _load_words(dut, words)
    await _restore_fp_enabled(dut)

    fault = None
    for _ in range(1000):
        await RisingEdge(dut.clk)
        await ReadOnly()
        if bool(dut.commit_valid.value) and int(dut.commit_pc.value) == BASE + 4:
            fault = _packet(dut)
            break
    assert fault is not None
    assert fault["exc_valid"] and fault["exc_code"] in (0x24, 0x25)
    assert not fault["vec"] and not fault["fpcr_we"] and not fault["fpsr_we"]
    assert int(dut.fp_v_lo[0].value) == 0
    dut._log.info("PASS: faulting scalar FP load has no V side effect")


@cocotb.test()
async def test_p7_fp_scalar_backpressure(dut):
    """commit_ready=0 must hold the FP result and all FP state unchanged."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    words = [0x1E2E1000, 0x14000000]  # fmov s0,#1.0; b .
    await _load_words(dut, words)
    await _restore_fp_enabled(dut)

    dut.commit_ready.value = 0
    for _ in range(80):
        await RisingEdge(dut.clk)
        await ReadOnly()
    assert int(dut.fp_v_lo[0].value) == 0
    assert int(dut.fp_v_hi[0].value) == 0

    await Timer(1, unit="ns")
    dut.commit_ready.value = 1
    committed = None
    for _ in range(300):
        await RisingEdge(dut.clk)
        await ReadOnly()
        if bool(dut.commit_valid.value) and int(dut.commit_pc.value) == BASE:
            committed = _packet(dut)
            break
    assert committed is not None
    assert committed["vec"] == [(0, 0x3F800000)]
    assert int(dut.fp_v_lo[0].value) == 0x3F800000
    dut._log.info("PASS: FP result is commit_ready/backpressure atomic")


@cocotb.test()
async def test_p7_fp_unsupported_encoding(dut):
    """Unselected FP type/size encodings must take UDEF, not execute."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())

    async def first_commit(words):
        await _load_words(dut, words)
        await _restore_fp_enabled(dut)
        for _ in range(600):
            await RisingEdge(dut.clk)
            await ReadOnly()
            if bool(dut.commit_valid.value) and int(dut.commit_pc.value) == BASE:
                return _packet(dut)
        raise AssertionError(f"未观察到首条 UDEF：{words!r}")

    # P7-5 已实现标量 FADD.H（H 算术），故 FADD.H 不再列入 unsupported；
    # 其正向覆盖由 P7-5 lockstep/edge/rounding/sequence 承担。
    cases = [
        ("FCMPE", fp3(0x1E202000, 0, 0, 1) | 0x10),
        ("FADD.reserved-type=10", 0x1EA22820),
        ("STR.B", 0x3D000020),
        ("LDR.H", 0x7D400020),
    ]
    for name, insn in cases:
        packet = await first_commit([insn, 0x14000000])
        assert packet["exc_valid"] and packet["exc_code"] == 0, name
        assert not packet["vec"] and not packet["fpsr_we"], name
    dut._log.info("PASS: unsupported FCMPE/FP16-reserved/B/H encodings remain explicit UDEF")
