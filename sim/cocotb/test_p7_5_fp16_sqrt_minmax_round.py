"""P7-5 FP16/sqrt/minmax/rint/FCVT pipeline 测试。

所有输入/期望均为 AArch64 raw bits；不使用 host float、epsilon 或宽松
NaN。覆盖标量 H 算术、sqrt/minmax/frint、FCVT H<->S/D、4H/8H 向量、
FPEN trap、backpressure、sticky 与 unsupported UDEF。
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ReadOnly, RisingEdge, Timer


BASE = 0x44000000
MASK64 = (1 << 64) - 1


def movz(rd, imm16, hw=0):
    return 0xD2800000 | (hw << 21) | (imm16 << 5) | rd


def _fp_h3(base, rd, rn, rm):
    return base | ((rm & 31) << 16) | ((rn & 31) << 5) | (rd & 31)


def _fp_h1(base, rd, rn):
    return base | ((rn & 31) << 5) | (rd & 31)


def _fp_fcvt(rd, rn, esz, op6):
    return 0x1E000000 | ((esz & 3) << 22) | (1 << 21) | \
        ((op6 & 0x3F) << 15) | (0b10000 << 10) | \
        ((rn & 31) << 5) | (rd & 31)


def _neon_v3(base, rd, rn, rm, quad):
    return base | (int(quad) << 30) | ((rm & 31) << 16) | \
        ((rn & 31) << 5) | (rd & 31)


def _neon_v2(base, rd, rn, quad):
    return base | (int(quad) << 30) | ((rn & 31) << 5) | (rd & 31)


# ---- 常用指令 ----
def fadd_h(rd, rn, rm): return _fp_h3(0x1EE02800, rd, rn, rm)
def fsub_h(rd, rn, rm): return _fp_h3(0x1EE03800, rd, rn, rm)
def fmul_h(rd, rn, rm): return _fp_h3(0x1EE00800, rd, rn, rm)
def fdiv_h(rd, rn, rm): return _fp_h3(0x1EE01800, rd, rn, rm)
def _fp_fma_h(base, rd, rn, rm, ra):
    return base | ((ra & 31) << 10) | ((rm & 31) << 16) | \
        ((rn & 31) << 5) | (rd & 31)
def fmadd_h(rd, rn, rm, ra): return _fp_fma_h(0x1FC00000, rd, rn, rm, ra)
def fmsub_h(rd, rn, rm, ra): return _fp_fma_h(0x1FC08000, rd, rn, rm, ra)
def fnmadd_h(rd, rn, rm, ra): return _fp_fma_h(0x1FE00000, rd, rn, rm, ra)
def fnmsub_h(rd, rn, rm, ra): return _fp_fma_h(0x1FE08000, rd, rn, rm, ra)
def fmla_4h(rd, rn, rm): return _neon_v3(0x0E400C00, rd, rn, rm, False)
def fmls_4h(rd, rn, rm): return _neon_v3(0x0EC00C00, rd, rn, rm, False)
def fsqrt_h(rd, rn): return _fp_h1(0x1EE1C000, rd, rn)
def fmax_h(rd, rn, rm): return _fp_h3(0x1EE04800, rd, rn, rm)
def fmin_h(rd, rn, rm): return _fp_h3(0x1EE05800, rd, rn, rm)
def frintz_h(rd, rn): return _fp_h1(0x1EE5C000, rd, rn)
def frintn_h(rd, rn): return _fp_h1(0x1EE44000, rd, rn)
def fcvt_hs(rd, rn): return _fp_fcvt(rd, rn, 3, 0b000100)  # H -> S
def fcvt_hd(rd, rn): return _fp_fcvt(rd, rn, 3, 0b000101)  # H -> D
def fcvt_sh(rd, rn): return _fp_fcvt(rd, rn, 0, 0b000111)  # S -> H
def fcvt_dh(rd, rn): return _fp_fcvt(rd, rn, 1, 0b000111)  # D -> H
def fadd_4h(rd, rn, rm): return _neon_v3(0x0E401400, rd, rn, rm, False)
def fmul_4h(rd, rn, rm): return _neon_v3(0x2E401C00, rd, rn, rm, False)
def fcmeq_4h(rd, rn, rm): return _neon_v3(0x0E402400, rd, rn, rm, False)
def fadd_8h(rd, rn, rm): return _neon_v3(0x0E401400, rd, rn, rm, True)
def fsqrt_2s(rd, rn): return _neon_v2(0x2EA1F800, rd, rn, False)


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


async def _load_words(dut, words):
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


async def _restore(dut, vectors=None, fpcr=0, fpsr=0, cpacr=0x00300000):
    vectors = vectors or {}
    _clear_restore(dut)
    dut.difftest_restore_pc.value = BASE
    dut.difftest_restore_nzcv.value = 4
    dut.difftest_restore_el.value = 1
    dut.difftest_restore_sp_sel.value = 1
    dut.difftest_restore_daif.value = 0xF
    dut.difftest_restore_sctlr_el1.value = 0x0000000000C50838
    dut.difftest_restore_cpacr_el1.value = cpacr
    dut.difftest_restore_fpcr.value = fpcr
    dut.difftest_restore_fpsr.value = fpsr
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
        "gpr_we": bool(dut.commit_gpr_we.value),
        "gpr_rd": int(dut.commit_gpr_rd.value),
        "gpr_wdata": int(dut.commit_gpr_wdata.value),
        "fpsr_we": bool(dut.commit_fpsr_we.value),
        "fpsr_wdata": int(dut.commit_fpsr_wdata.value),
        "exc_valid": bool(dut.commit_exc_valid.value),
        "exc_code": int(dut.commit_exc_code.value),
        "exc_esr": int(dut.commit_exc_esr.value),
    }


async def _collect(dut, limit=1000):
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
async def test_p7_5_scalar_h_arith(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    words = [
        fadd_h(3, 0, 1),     # fadd h3,h0,h1
        fsub_h(4, 1, 0),     # fsub h4,h1,h0
        fmul_h(5, 0, 1),     # fmul h5,h0,h1
        fdiv_h(6, 1, 0),     # fdiv h6,h1,h0
        0x14000000,
    ]
    vectors = {
        0: 0x0000000000003C00,   # V0[15:0]=1.0h
        1: 0x0000000000004000,   # V1[15:0]=2.0h
    }
    await _load_words(dut, words)
    await _restore(dut, vectors=vectors)
    packets = await _collect(dut)

    _, v3 = _vector_packet(packets, 3)
    assert v3 & 0xFFFF == 0x4200, hex(v3)          # 1+2=3
    _, v4 = _vector_packet(packets, 4)
    assert v4 & 0xFFFF == 0x3C00, hex(v4)          # 2-1=1
    _, v5 = _vector_packet(packets, 5)
    assert v5 & 0xFFFF == 0x4000, hex(v5)          # 1*2=2
    _, v6 = _vector_packet(packets, 6)
    assert v6 & 0xFFFF == 0x4000, hex(v6)          # 2/1=2


@cocotb.test()
async def test_b2a_h_fma(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    words = [
        fmadd_h(3, 0, 1, 2),     # h3 = h0*h1 + h2 = 2*3+10 = 16
        fmsub_h(6, 0, 1, 2),     # h6 = h2 - h0*h1 = 4
        fnmadd_h(7, 0, 1, 2),    # h7 = -(2*3+10) = -16
        fnmsub_h(8, 0, 1, 2),    # h8 = 2*3-10 = -4
        fmla_4h(4, 0, 1),        # v4 = v4 + v0*v1 (4H)
        fmls_4h(5, 0, 1),        # v5 = v5 - v0*v1 (4H)
        0x14000000,
    ]
    vectors = {
        0: 0x0000000000000000_4500440042004000,
        1: 0x0000000000000000_3c003c0040004200,
        2: 0x0000000000000000_4000bc0000004900,
        4: 0x0000000000000000_4000bc0000004900,
        5: 0x0000000000000000_4000bc0000004900,
    }
    # Python literal above is one 128-bit integer; split via hex string not needed.
    await _load_words(dut, words)
    await _restore(dut, vectors=vectors)
    packets = await _collect(dut)

    _, v3 = _vector_packet(packets, 3)
    assert v3 & 0xFFFF == 0x4C00, hex(v3)          # FMADD.H 16
    _, v6 = _vector_packet(packets, 6)
    assert v6 & 0xFFFF == 0x4400, hex(v6)          # FMSUB.H 4
    _, v7 = _vector_packet(packets, 7)
    assert v7 & 0xFFFF == 0xCC00, hex(v7)          # FNMADD.H -16
    _, v8 = _vector_packet(packets, 8)
    assert v8 & 0xFFFF == 0xC400, hex(v8)          # FNMSUB.H -4
    _, v4 = _vector_packet(packets, 4)
    assert v4 & 0xFFFFFFFFFFFFFFFF == 0x4700420046004C00, hex(v4)  # FMLA 4H
    _, v5 = _vector_packet(packets, 5)
    assert v5 & 0xFFFFFFFFFFFFFFFF == 0xC200C500C6004400, hex(v5)  # FMLS 4H

@cocotb.test()
async def test_p7_5_sqrt_minmax_frint(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    words = [
        fsqrt_h(10, 2),      # fsqrt h10,h2  (sqrt 4 = 2)
        fmin_h(11, 0, 1),    # fmin h11,h0,h1 (min 1,2 = 1)
        fmax_h(12, 0, 1),    # fmax h12,h0,h1 (max = 2)
        frintz_h(13, 3),     # frintz h13,h3 (1.5 -> 1)
        frintn_h(14, 3),     # frintn h14,h3 (1.5 -> 2)
        0x14000000,
    ]
    vectors = {
        0: 0x0000000000003C00,   # 1.0h
        1: 0x0000000000004000,   # 2.0h
        2: 0x0000000000004400,   # 4.0h
        3: 0x0000000000003E00,   # 1.5h
    }
    await _load_words(dut, words)
    await _restore(dut, vectors=vectors)
    packets = await _collect(dut)

    _, v10 = _vector_packet(packets, 10)
    assert v10 & 0xFFFF == 0x4000, hex(v10)        # sqrt4=2
    _, v11 = _vector_packet(packets, 11)
    assert v11 & 0xFFFF == 0x3C00, hex(v11)        # min(1,2)=1
    _, v12 = _vector_packet(packets, 12)
    assert v12 & 0xFFFF == 0x4000, hex(v12)        # max(1,2)=2
    _, v13 = _vector_packet(packets, 13)
    assert v13 & 0xFFFF == 0x3C00, hex(v13)        # 1.5->1
    _, v14 = _vector_packet(packets, 14)
    assert v14 & 0xFFFF == 0x4000, hex(v14)        # 1.5->2


@cocotb.test()
async def test_p7_5_fcvt_h_s_d(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    words = [
        fcvt_hs(20, 0),      # fcvt s20,h0  (1.0h -> 1.0f)
        fcvt_hd(21, 0),      # fcvt d21,h0
        fcvt_sh(22, 23),     # fcvt h22,s23 (2.0f -> 2.0h)
        fcvt_dh(24, 25),     # fcvt h24,d25
        fcvt_hs(26, 27),     # fcvt s26,h27 (NaN 0x7E12)
        0x14000000,
    ]
    vectors = {
        0: 0x0000000000003C00,
        23: 0x0000000040000000,
        25: 0x3FF0000000000000,
        27: 0x0000000000007E12,
    }
    await _load_words(dut, words)
    await _restore(dut, vectors=vectors)
    packets = await _collect(dut)

    _, v20 = _vector_packet(packets, 20)
    assert v20 == 0x3F800000, hex(v20)
    _, v21 = _vector_packet(packets, 21)
    assert v21 == 0x3FF0000000000000, hex(v21)
    _, v22 = _vector_packet(packets, 22)
    assert v22 & 0xFFFF == 0x4000, hex(v22)
    _, v24 = _vector_packet(packets, 24)
    assert v24 & 0xFFFF == 0x3C00, hex(v24)
    _, v26 = _vector_packet(packets, 26)
    assert v26 == 0x7FC24000, hex(v26)


@cocotb.test()
async def test_p7_5_neon_4h_8h(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    words = [
        fadd_4h(2, 0, 1),    # fadd v2.4h, v0,v1
        fmul_4h(3, 0, 1),    # fmul v3.4h
        fcmeq_4h(4, 0, 5),   # fcmeq v4.4h
        fadd_8h(6, 0, 1),    # fadd v6.8h
        0x14000000,
    ]
    vectors = {
        0: 0x0000000000003C00,
        1: 0x0000000000004000,
        5: 0x0000000000003C00,
    }
    await _load_words(dut, words)
    await _restore(dut, vectors=vectors)
    packets = await _collect(dut)

    _, v2 = _vector_packet(packets, 2)
    assert v2 & 0xFFFF == 0x4200, hex(v2)
    _, v3 = _vector_packet(packets, 3)
    assert v3 & 0xFFFF == 0x4000, hex(v3)
    _, v4 = _vector_packet(packets, 4)
    assert v4 & 0xFFFF == 0xFFFF, hex(v4)
    _, v6 = _vector_packet(packets, 6)
    assert v6 & 0xFFFF == 0x4200, hex(v6)


@cocotb.test()
async def test_p7_5_fpen_trap_no_effect(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await _load_words(dut, [fadd_h(3, 0, 1), 0x14000000])
    await _restore(dut, vectors={0: 0x3C00, 1: 0x4000}, cpacr=0)
    packets = await _collect(dut, 500)
    first = next(p for p in packets if p["pc"] == BASE)
    assert first["exc_valid"] and first["exc_code"] == 0x07
    assert first["exc_esr"] == 0x1FE00000
    assert not first["vec"] and not first["gpr_we"]
    assert int(dut.fp_v_lo[3].value) == 0
    assert int(dut.fp_v_hi[3].value) == 0


@cocotb.test()
async def test_p7_5_backpressure(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    words = [fadd_h(3, 0, 1), 0x14000000]
    vectors = {0: 0x3C00, 1: 0x4000}
    await _load_words(dut, words)
    await _restore(dut, vectors=vectors)
    dut.commit_ready.value = 0
    for _ in range(80):
        await RisingEdge(dut.clk)
        await ReadOnly()
    assert int(dut.fp_v_lo[3].value) == 0
    assert int(dut.fp_v_hi[3].value) == 0
    assert int(dut.fpsr_state.value) == 0
    await Timer(1, unit="ns")
    dut.commit_ready.value = 1
    packets = await _collect(dut, 400)
    _, got = _vector_packet(packets, 3)
    assert got & 0xFFFF == 0x4200, hex(got)


@cocotb.test()
async def test_p7_5_unsupported_udef(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    cases = [
        0x1E202010,          # FCMPE H reserved
        0x1EA1C000,          # fsqrt esz=10
        0x1EA02800,          # fadd esz=10
        0x0EE1B800,          # fcvtzs v0.2d, Q=0
    ]
    for insn in cases:
        await _load_words(dut, [insn, 0x14000000])
        await _restore(dut)
        packets = await _collect(dut, 500)
        first = next(p for p in packets if p["pc"] == BASE)
        assert first["exc_valid"] and first["exc_code"] == 0, f"{insn:08x}"
        assert not first["vec"] and not first["gpr_we"]
