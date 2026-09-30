"""P7-2 Advanced SIMD/Q integer pipeline tests.

所有期望值都是 raw 128-bit 位模式；测试不使用 host SIMD/float 或 epsilon。
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ReadOnly, RisingEdge, Timer


BASE = 0x44000000
DATA = BASE + 0x1000
MASK64 = (1 << 64) - 1
MASK128 = (1 << 128) - 1


def movz(rd, imm16, hw=0):
    return 0xD2800000 | (hw << 21) | (imm16 << 5) | rd


def movk(rd, imm16, hw=0):
    return 0xF2800000 | (hw << 21) | (imm16 << 5) | rd


def three_same(base, rd, rn, rm, size=0):
    return base | ((size & 3) << 22) | ((rm & 31) << 16) | \
        ((rn & 31) << 5) | (rd & 31)


def fp3(base, rd, rn, rm):
    return base | ((rm & 31) << 16) | ((rn & 31) << 5) | (rd & 31)


def movi(rd, imm8, cmode=0xE):
    assert cmode in (0x0, 0x8, 0xE)
    assert 0 <= imm8 < 0x100
    base = {0x0: 0x4F000400, 0x8: 0x4F008400,
            0xE: 0x4F00E400}[cmode]
    return base | (((imm8 >> 5) & 7) << 16) | \
        ((imm8 & 0x1F) << 5) | (rd & 31)


def imm_shift(base, rd, rn, size, amount, right=True):
    width = 8 << size
    encoded = (2 * width - amount) if right else (width + amount)
    assert 0 < amount <= (width if right else width - 1)
    assert width <= encoded < 2 * width
    return base | (((encoded >> 3) & 0xF) << 19) | \
        ((encoded & 7) << 16) | ((rn & 31) << 5) | (rd & 31)


def qmem(load, rt, rn, imm12=0):
    assert 0 <= imm12 < 0x1000
    return (0x3DC00000 if load else 0x3D800000) | \
        (imm12 << 10) | ((rn & 31) << 5) | (rt & 31)


def dup_scalar(rd, src, size):
    """DUP Vd.<T>, Wn/Xn; size 0=B 1=H 2=S 3=D."""
    imm5 = 1 << size
    return 0x4E000C00 | (imm5 << 16) | ((src & 31) << 5) | (rd & 31)


def dup_element(rd, rn, size, index):
    """DUP Vd.<T>, Vn.<T>[index]."""
    imm5 = (index << (size + 1)) | (1 << size)
    return 0x4E000400 | (imm5 << 16) | ((rn & 31) << 5) | (rd & 31)


def ld1r(rt, rn, size, quad=1):
    """LD1R {Vt.<T>}, [Xn]; quad=0 writes 64-bit form."""
    base = 0x4D40C000 if quad else 0x0D40C000
    return base | (size << 10) | ((rn & 31) << 5) | (rt & 31)


def fp_mem(base, rt, rn, imm12=0):
    """P7-1 scalar S/D memory encoding, used only for cross-unit hazards."""
    return base | (imm12 << 10) | ((rn & 31) << 5) | (rt & 31)


def _clear_restore(dut):
    ports = (
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
    for name in ports:
        getattr(dut, name).value = 0
    for name in ("difftest_restore_fp_v_lo", "difftest_restore_fp_v_hi"):
        vec = getattr(dut, name)
        for i in range(32):
            vec[i].value = 0


async def _load_words(dut, words, data_words=()):
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
    for address, value in data_words:
        dut.prog_we.value = 1
        dut.prog_addr.value = address
        dut.prog_strb.value = 0xFF
        dut.prog_wdata.value = value
        await RisingEdge(dut.clk)
    dut.prog_we.value = 0


async def _restore(dut, vectors=None, cpacr=0x00300000):
    vectors = vectors or {}
    _clear_restore(dut)
    dut.difftest_restore_pc.value = BASE
    dut.difftest_restore_nzcv.value = 4
    dut.difftest_restore_el.value = 1
    dut.difftest_restore_sp_sel.value = 1
    dut.difftest_restore_daif.value = 0xF
    dut.difftest_restore_sctlr_el1.value = 0x0000000000C50838
    dut.difftest_restore_cpacr_el1.value = cpacr
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


def _packet(dut):
    count = int(dut.commit_vec_write_count.value)
    vectors = []
    for i in range(count):
        lo = int(getattr(dut, f"commit_vec_wdata{i}_lo").value)
        hi = int(getattr(dut, f"commit_vec_wdata{i}_hi").value)
        vectors.append((int(getattr(dut, f"commit_vec_rd{i}").value),
                        (hi << 64) | lo))
    return {
        "pc": int(dut.commit_pc.value),
        "insn": int(dut.commit_insn.value),
        "vec": vectors,
        "mem_we": bool(dut.commit_mem_we.value),
        "mem_addr": int(dut.commit_mem_addr.value) & MASK64,
        "mem_wdata": int(dut.commit_mem_wdata.value) & MASK64,
        "mem_strb": int(dut.commit_mem_strb.value),
        "mem2_we": bool(dut.commit_mem2_we.value),
        "mem2_addr": int(dut.commit_mem2_addr.value) & MASK64,
        "mem2_wdata": int(dut.commit_mem2_wdata.value) & MASK64,
        "mem2_strb": int(dut.commit_mem2_strb.value),
        "exc_valid": bool(dut.commit_exc_valid.value),
        "exc_code": int(dut.commit_exc_code.value),
        "exc_esr": int(dut.commit_exc_esr.value),
    }


async def _collect(dut, limit=2000):
    packets = []
    for _ in range(limit):
        await RisingEdge(dut.clk)
        await ReadOnly()
        if bool(dut.commit_valid.value):
            packets.append(_packet(dut))
    return packets


def _vector_packet(packets, rd):
    for packet in packets:
        for got_rd, value in packet["vec"]:
            if got_rd == rd:
                return packet, value
    raise AssertionError(f"没有观察到 V{rd} 写回")


@cocotb.test()
async def test_p7_2_neon_pipeline(dut):
    """覆盖 Q move/bitwise/add-sub/compare/shift、1V 和 Q memory。"""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    words = [
        movi(0, 0x11),                       # V0 = 16 x 0x11
        movi(1, 0x22),                       # V1 = 16 x 0x22
        three_same(0x4EA01C00, 2, 0, 1),     # ORR V2,V0,V1
        three_same(0x4E201C00, 3, 0, 1),     # AND V3,V0,V1
        three_same(0x6E201C00, 4, 0, 1),     # EOR V4,V0,V1
        three_same(0x4E601C00, 5, 0, 1),     # BIC V5,V0,V1
        three_same(0x4EE01C00, 6, 0, 1),     # ORN V6,V0,V1
        three_same(0x4E208400, 7, 0, 1, 0),  # ADD .16B
        three_same(0x4E208400, 8, 0, 1, 1),  # ADD .8H
        three_same(0x6E208400, 9, 2, 1, 2),  # SUB .4S
        three_same(0x6E208C00, 10, 0, 0, 0), # CMEQ .16B
        three_same(0x4E203400, 11, 2, 1, 3), # CMGT .2D
        imm_shift(0x4F005400, 12, 8, 1, 3, right=False),
        imm_shift(0x4F200400, 13, 9, 2, 2),
        imm_shift(0x6F600400, 14, 8, 3, 4),
        imm_shift(0x4F001400, 15, 7, 0, 1),  # SSRA V15,V7,#1
        imm_shift(0x6F001400, 16, 8, 1, 2),  # USRA V16,V8,#2
        movz(10, 0x4400, 1),
        movk(10, 0x1000),
        qmem(False, 16, 10),                 # STR Q16,[X10]
        qmem(True, 17, 10),                  # LDR Q17,[X10]
        three_same(0x4EA01C00, 18, 17, 17),  # load-use forwarding
        0x14000000,
    ]
    await _load_words(dut, words)
    await _restore(dut)
    packets = await _collect(dut, 1500)

    expected = {
        0: int("11111111111111111111111111111111", 16),
        1: int("22222222222222222222222222222222", 16),
        2: int("33333333333333333333333333333333", 16),
        3: int("00000000000000000000000000000000", 16),
        4: int("33333333333333333333333333333333", 16),
        5: int("11111111111111111111111111111111", 16),
        6: int("DDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDD", 16),
        7: int("33333333333333333333333333333333", 16),
        8: int("33333333333333333333333333333333", 16),
        9: int("11111111111111111111111111111111", 16),
        10: MASK128,
        11: MASK128,
        12: int("99989998999899989998999899989998", 16),
        13: int("04444444044444440444444404444444", 16),
        14: int("03333333333333330333333333333333", 16),
        15: int("19191919191919191919191919191919", 16),
        16: int("0CCC0CCC0CCC0CCC0CCC0CCC0CCC0CCC", 16),
        17: int("0CCC0CCC0CCC0CCC0CCC0CCC0CCC0CCC", 16),
        18: int("0CCC0CCC0CCC0CCC0CCC0CCC0CCC0CCC", 16),
    }
    for rd, want in expected.items():
        _, got = _vector_packet(packets, rd)
        assert got == want, f"V{rd}: got {got:032x}, want {want:032x}"

    store = next(p for p in packets if p["mem_we"] and p["mem_addr"] == DATA)
    assert store["mem_strb"] == 0xFF
    assert store["mem_wdata"] == expected[16] & MASK64
    assert store["mem2_we"] and store["mem2_addr"] == DATA + 8
    assert store["mem2_strb"] == 0xFF
    assert store["mem2_wdata"] == (expected[16] >> 64) & MASK64
    assert int(dut.fp_v_lo[17].value) == expected[17] & MASK64
    assert int(dut.fp_v_hi[17].value) == (expected[17] >> 64) & MASK64
    dut._log.info("PASS: P7-2 Q integer pipeline and two-segment memory")


@cocotb.test()
async def test_p7_2_dup_replicate(dut):
    """DUP scalar/element fills all lanes; Q=0 keeps upper 64 zero."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    words = [
        movz(1, 0xA5AB),
        dup_scalar(0, 1, 0),             # V0.16B = 16 x 0xAB
        dup_scalar(7, 1, 0),             # V7.16B = 16 x 0xAB
        dup_element(6, 7, 0, 3),         # V6.16B = 16 x V7.b[3] = 0xAB
        dup_scalar(2, 1, 1),             # V2.8H  = 8 x 0xA5AB
        dup_scalar(3, 1, 2),             # V3.4S  = 4 x 0x0000A5AB
        dup_scalar(4, 1, 3),             # V4.2D  = 2 x 0x000000000000A5AB
        0x14000000,
    ]
    await _load_words(dut, words)
    await _restore(dut)
    packets = await _collect(dut, 900)
    for rd, want in {
        0: int("AB" * 16, 16),
        2: int("A5AB" * 8, 16),
        3: int("0000A5AB" * 4, 16),
        4: 0x000000000000A5AB000000000000A5AB,
        6: int("AB" * 16, 16),
        7: int("AB" * 16, 16),
    }.items():
        _, got = _vector_packet(packets, rd)
        assert got == want, f"V{rd}: got {got:032x}, want {want:032x}"
    dut._log.info("PASS: B2c DUP scalar/element replicate")


@cocotb.test()
async def test_p7_2_ld1r_replicate(dut):
    """LD1R loads one element and replicates it across all lanes."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    words = [
        movz(10, 0x4400, 1), movk(10, 0x1000),
        ld1r(0, 10, 0, quad=1),    # V0.16B = 16 x byte at DATA
        ld1r(1, 10, 1, quad=1),    # V1.8H  = 8 x halfword at DATA
        ld1r(2, 10, 2, quad=1),    # V2.4S  = 4 x word at DATA
        ld1r(3, 10, 3, quad=1),    # V3.2D  = 2 x doubleword at DATA
        ld1r(4, 10, 0, quad=0),    # V4.8B  = 8 x byte, upper 64 zero
        0x14000000,
    ]
    data_words = [
        (DATA, 0x1122334455667788),
    ]
    await _load_words(dut, words, data_words)
    await _restore(dut)
    packets = await _collect(dut, 1400)
    expects = {
        0: int("88" * 16, 16),
        1: int("77887788778877887788778877887788", 16),
        2: int("55667788556677885566778855667788", 16),
        3: 0x11223344556677881122334455667788,
        4: int("88" * 8, 16),  # only low 64
    }
    for rd, want in expects.items():
        _, got = _vector_packet(packets, rd)
        assert got == want, f"V{rd}: got {got:032x}, want {want:032x}"
    assert int(dut.fp_v_lo[4].value) == expects[4] & MASK64
    assert int(dut.fp_v_hi[4].value) == 0
    dut._log.info("PASS: B2c LD1R load-replicate memory")


@cocotb.test()
async def test_p7_2_fpen_trap_no_effect(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await _load_words(dut, [movi(0, 0xAA), 0x14000000])
    await _restore(dut, cpacr=0)
    packets = await _collect(dut, 500)
    first = next(p for p in packets if p["pc"] == BASE)
    assert first["exc_valid"] and first["exc_code"] == 0x07
    assert first["exc_esr"] == 0x1FE00000
    assert not first["vec"]
    assert int(dut.fp_v_lo[0].value) == 0
    assert int(dut.fp_v_hi[0].value) == 0
    dut._log.info("PASS: NEON FPEN trap has no V side effect")


@cocotb.test()
async def test_p7_2_q_fault_no_effect(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    # X10 = an unaligned address outside the 16B natural access contract.
    words = [movz(10, 0x4400, 1), movk(10, 0x1001),
             qmem(True, 0, 10), 0x14000000]
    await _load_words(dut, words)
    await _restore(dut)
    packets = await _collect(dut, 700)
    fault = next(p for p in packets if p["pc"] == BASE + 8)
    assert fault["exc_valid"] and fault["exc_code"] in (0x24, 0x25)
    assert fault["exc_esr"] & 0x3F == 0x21
    assert not fault["vec"]
    assert int(dut.fp_v_lo[0].value) == 0
    assert int(dut.fp_v_hi[0].value) == 0
    dut._log.info("PASS: unaligned Q load faults before either 8B request")


@cocotb.test()
async def test_p7_2_q_store_fault_esr_and_atomicity(dut):
    """STR Q fault reports WnR=1 and emits no first/second store."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())

    async def run_fault(words, expected_fsc):
        await _load_words(dut, words)
        await _restore(dut)
        packets = await _collect(dut, 700)
        fault = next(p for p in packets if p["pc"] == BASE + 8)
        assert fault["exc_valid"] and fault["exc_code"] in (0x24, 0x25)
        assert (fault["exc_esr"] & 0x40) != 0, f"STR Q WnR=0: {fault}"
        assert (fault["exc_esr"] & 0x3F) == expected_fsc
        assert not fault["mem_we"] and not fault["mem2_we"]
        assert not fault["vec"]

    # Natural 16B alignment violation: the complete Q transaction is
    # rejected before either internal 8B request.
    await run_fault([
        movz(10, 0x4400, 1), movk(10, 0x1001),
        qmem(False, 0, 10), 0x14000000,
    ], 0x21)

    # Address is in the SRAM window but the final 8B half would cross its top;
    # full-window precheck must reject the store before accepting half one.
    await run_fault([
        movz(10, 0x4800, 1), movk(10, 0x0000),
        qmem(False, 0, 10), 0x14000000,
    ], 0x10)
    dut._log.info("PASS: STR Q alignment/range ESR WnR and no half-store")


@cocotb.test()
async def test_p7_2_cross_unit_v_hazards(dut):
    """Load-produced V state must forward across scalar FP and NEON units."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    words = [
        movz(10, 0x4400, 1), movk(10, 0x1000),
        fp_mem(0xBD400000, 0, 10, 0),       # LDR S0 -> NEON V1
        three_same(0x4EA01C00, 1, 0, 0),   # ORR V1.16B,V0.16B,V0.16B
        fp_mem(0xFD400000, 2, 10, 1),       # LDR D2 -> NEON V3
        three_same(0x4EA01C00, 3, 2, 2),   # ORR V3.16B,V2.16B,V2.16B
        qmem(True, 4, 10, 1),               # LDR Q4 -> scalar FMOV D5
        fp3(0x1E604000, 5, 4, 0),          # FMOV D5,D4
        fp_mem(0xFD000000, 5, 10, 3),       # STR D5,[X10,#24]
        0x14000000,
    ]
    data_words = [
        (DATA, 0x0000000011223344),
        (DATA + 8, 0x5566778899AABBCC),
        (DATA + 16, 0x0123456789ABCDEF),
        (DATA + 24, 0),
    ]
    await _load_words(dut, words, data_words)
    await _restore(dut)
    packets = await _collect(dut, 1600)

    _, s_value = _vector_packet(packets, 1)
    assert s_value == 0x0000000011223344
    _, d_value = _vector_packet(packets, 3)
    assert d_value == 0x000000005566778899AABBCC
    _, q_value = _vector_packet(packets, 4)
    assert q_value == 0x0123456789ABCDEF
    _, fmov_value = _vector_packet(packets, 5)
    assert fmov_value == 0x000000000123456789ABCDEF
    stores = [p for p in packets if p["mem_we"]]
    d_store = next(p for p in stores if p["mem_addr"] == DATA + 24)
    assert d_store["mem_strb"] == 0xFF
    assert d_store["mem_wdata"] == 0x0123456789ABCDEF
    dut._log.info("PASS: LDR S/D->NEON and LDR Q->scalar FP/STR D hazards")


@cocotb.test()
async def test_p7_2_unsupported_udef(dut):
    """未选的饱和/窄化/加宽/跨 lane/结构化/FP 族必须保持 UDEF。"""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    cases = [
        (0x4E220C20, "SQADD"),
        (0x0E224020, "ADDHN"),
        (0x0E220020, "SADDL"),
        (0x0E221C20, "Q=0 D-register AND"),
        (0x0E228420, "Q=0 D-register ADD"),
        (0x5EE28420, "scalar Advanced SIMD ADD D"),
        (0x4E020020, "TBL"),
        (0x4C407140, "LD1 structured"),
        (0x4C40A140, "LD1 structured pair"),
        (0xAD400540, "LDP Q pair"),
        (0xAD000540, "STP Q pair"),
        (0x4E071DAC, "INS lane insert"),
        (0x6E22E420, "FCMGE vector FP (P7-3 unselected)"),
        (0x4E22BC20, "ADDP across lane"),
        (0x4F000400 | (7 << 16) | (1 << 5), "invalid immh=0 shift"),
    ]
    for insn, name in cases:
        await _load_words(dut, [insn, 0x14000000])
        await _restore(dut)
        packets = await _collect(dut, 500)
        first = next(p for p in packets if p["pc"] == BASE)
        assert first["exc_valid"] and first["exc_code"] == 0, name
        assert not first["vec"] and not first["mem_we"] and not first["mem2_we"], name
    dut._log.info("PASS: P7-2 unsupported Advanced SIMD families are UDEF")


@cocotb.test()
async def test_p7_2_backpressure_atomic(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await _load_words(dut, [movi(0, 0x5A), 0x14000000])
    await _restore(dut)
    dut.commit_ready.value = 0
    for _ in range(100):
        await RisingEdge(dut.clk)
        await ReadOnly()
    assert int(dut.fp_v_lo[0].value) == 0
    assert int(dut.fp_v_hi[0].value) == 0
    await Timer(1, unit="ns")
    dut.commit_ready.value = 1
    packets = await _collect(dut, 500)
    _, value = _vector_packet(packets, 0)
    assert value == int("5A" * 16, 16)
    assert int(dut.fp_v_lo[0].value) == int("5A" * 8, 16)
    dut._log.info("PASS: Q effect is commit-ready atomic")


@cocotb.test()
async def test_p7_2_q_load_backpressure(dut):
    """A Q load cannot update V until its single commit is accepted."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    q_value = 0x99AABBCCDDEEFF000102030405060708
    words = [
        movz(10, 0x4400, 1), movk(10, 0x1000),
        qmem(True, 0, 10),
        0x14000000,
    ]
    data_words = [
        (DATA, q_value & MASK64),
        (DATA + 8, (q_value >> 64) & MASK64),
    ]
    await _load_words(dut, words, data_words)
    await _restore(dut)
    dut.commit_ready.value = 0
    for _ in range(140):
        await RisingEdge(dut.clk)
        await ReadOnly()
    assert int(dut.fp_v_lo[0].value) == 0
    assert int(dut.fp_v_hi[0].value) == 0
    await Timer(1, unit="ns")
    dut.commit_ready.value = 1
    packets = await _collect(dut, 700)
    _, got = _vector_packet(packets, 0)
    assert got == q_value
    assert int(dut.fp_v_lo[0].value) == q_value & MASK64
    assert int(dut.fp_v_hi[0].value) == (q_value >> 64) & MASK64
    dut._log.info("PASS: Q load V update is commit-ready atomic")
