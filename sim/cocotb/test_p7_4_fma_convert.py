"""P7-4 FMA 与 FP/整数转换 pipeline 测试。

所有输入/期望均为 AArch64 raw bits；不使用 host float、epsilon 或宽松
NaN。覆盖 scalar FMA 四族、scalar 转换与 FCVT、GPR/V 写回、FPEN trap、
backpressure、sticky 与 unsupported UDEF。
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ReadOnly, RisingEdge, Timer


BASE = 0x44000000
MASK64 = (1 << 64) - 1
MASK128 = (1 << 128) - 1


def movz(rd, imm16, hw=0):
    return 0xD2800000 | (hw << 21) | (imm16 << 5) | rd


def fma_scalar(m, s, dbl, rd, rn, rm, ra):
    # scalar FMA: 00011111 esz M rm S ra rn rd
    return (0x1F000000 | ((1 if dbl else 0) << 22) | (m << 21) |
            ((rm & 31) << 16) | (s << 15) | ((ra & 31) << 10) |
            ((rn & 31) << 5) | (rd & 31))


def scvtf_fixed(sf, dbl, rd, rn, scale):
    # SCVTF W/X -> S/D fixed: op6=000010, field=32/64-scale
    field = (32 if not sf else 64) - scale
    insn = 0x1E000000 | ((1 if sf else 0) << 31) | ((1 if dbl else 0) << 22) \
        | (0b000010 << 16)
    if sf:
        insn |= ((field & 0x3F) << 10)
    else:
        insn |= (1 << 15) | ((field & 0x1F) << 10)
    return insn | ((rn & 31) << 5) | (rd & 31)


def fcvtzs_fixed(sf, dbl, rd, rn, scale):
    # FCVTZS S/D -> W/X：整数形式（scale=0）op6=111000，定点 op6=011000。
    op6 = 0b111000 if scale == 0 else 0b011000
    field = (32 if not sf else 64) - scale
    insn = 0x1E000000 | ((1 if sf else 0) << 31) | ((1 if dbl else 0) << 22) \
        | (op6 << 16)
    if sf:
        insn |= ((field & 0x3F) << 10)
    else:
        if scale != 0:
            insn |= (1 << 15) | ((field & 0x1F) << 10)
    return insn | ((rn & 31) << 5) | (rd & 31)


def fcvt(rd, rn, to_double):
    # FCVT S<->D: S->D 编码 bit22=0，D->S bit22=1。
    insn = 0x1E000000 | ((0 if to_double else 1) << 22) | (1 << 21)
    if to_double:
        insn |= (0b000101 << 15)
    else:
        insn |= (0b000100 << 15)
    insn |= (0b10000 << 10)
    return insn | ((rn & 31) << 5) | (rd & 31)


def neon_fma(rd, rn, rm, quad, double, neg):
    # FMLA 0x0e20cc00 / FMLS 0x0ea0cc00 three-same
    base = 0x0EA0CC00 if neg else 0x0E20CC00
    return (base | ((1 if quad else 0) << 30) |
            ((1 if double else 0) << 22) |
            ((rm & 31) << 16) | ((rn & 31) << 5) | (rd & 31))


def neon_conv(base, rd, rn, quad, double):
    return (base | ((1 if quad else 0) << 30) |
            ((1 if double else 0) << 22) |
            ((rn & 31) << 5) | (rd & 31))


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
async def test_p7_4_scalar_fma_and_convert(dut):
    """四 FMA 族、SCVTF/FCVTZS 与 GPR/V 写回、sticky IXC。"""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    words = [
        fma_scalar(0, 0, False, 3, 0, 1, 2),   # fmadd s3,s0,s1,s2
        fma_scalar(0, 1, True, 4, 16, 17, 18), # fmsub d4,d16,d17,d18
        fma_scalar(1, 0, False, 5, 0, 1, 2),   # fnmadd s5
        fma_scalar(1, 1, True, 6, 16, 17, 18), # fnmsub d6
        movz(8, 7),
        scvtf_fixed(False, False, 7, 8, 1),    # scvtf s7,w8,#1 -> 3.5
        fcvtzs_fixed(False, False, 9, 7, 0),   # fcvtzs w9,s7 -> 3 (IXC)
        fcvt(10, 7, True),                     # fcvt d10,s7 -> 3.5
        0x14000000,
    ]
    vectors = {
        0: 0x40000000,                            # S 2.0
        1: 0x40400000,                            # S 3.0
        2: 0x41200000,                            # S 10.0
        16: 0x4000000000000000,                   # D 2.0
        17: 0x4008000000000000,                   # D 3.0
        18: 0x4024000000000000,                   # D 10.0
    }
    await _load_words(dut, words)
    await _restore(dut, vectors=vectors)
    packets = await _collect(dut)

    _, v3 = _vector_packet(packets, 3)
    assert v3 == 0x41800000, hex(v3)                  # 2*3+10=16
    _, v4 = _vector_packet(packets, 4)
    assert v4 == 0x4010000000000000, hex(v4)          # 10-2*3=4
    _, v5 = _vector_packet(packets, 5)
    assert v5 == 0xC1800000, hex(v5)                  # -(2*3+10)
    _, v6 = _vector_packet(packets, 6)
    assert v6 == 0xC010000000000000, hex(v6)          # 2*3-10=-4
    _, v7 = _vector_packet(packets, 7)
    assert v7 == 0x40600000, hex(v7)                  # 3.5
    _, v10 = _vector_packet(packets, 10)
    assert v10 == 0x400C000000000000, hex(v10)        # 3.5 double
    conv = next(p for p in packets
                if p["gpr_we"] and p["gpr_rd"] == 9)
    assert conv["gpr_wdata"] == 3, conv
    assert conv["fpsr_we"] and conv["fpsr_wdata"] & 0x10  # IXC
    assert int(dut.fpsr_state.value) & 0x10


@cocotb.test()
async def test_p7_4_vector_fma_convert(dut):
    """2S FMLA/FMLS、4S SCVTF、2D FCVTZS 与 lane FPSR。"""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    words = [
        neon_fma(3, 0, 1, False, False, False),  # fmla v3.2s (Vd+=Vn*Vm)
        neon_fma(4, 0, 1, False, False, True),   # fmls v4.2s
        neon_conv(0x0E21D800, 2, 6, False, False),  # scvtf v2.2s
        neon_conv(0x0EA1B800, 5, 20, True, True),   # fcvtzs v5.2d
        0x14000000,
    ]
    vectors = {
        0: 0x4000000040000000,            # 整数 {2,2}
        1: 0x4040000040400000,            # 整数 {3,3}
        3: 0x4120000041200000,            # S addend {10,10}
        4: 0x4120000041200000,            # S addend {10,10}
        6: 0x0000000200000002,            # 整数 {2,2}
        20: 0xC0040000000000004004000000000000,  # D {2.5,-2.5}
    }
    await _load_words(dut, words)
    await _restore(dut, vectors=vectors)
    packets = await _collect(dut)

    _, v3 = _vector_packet(packets, 3)
    assert v3 == 0x4180000041800000, hex(v3)          # 10+2*3=16
    _, v4 = _vector_packet(packets, 4)
    assert v4 == 0x4080000040800000, hex(v4)          # 10-2*3=4
    _, v2 = _vector_packet(packets, 2)
    assert v2 == 0x4000000040000000, hex(v2)          # {2.0,2.0}
    _, v5 = _vector_packet(packets, 5)
    assert v5 == 0xFFFFFFFFFFFFFFFE0000000000000002, hex(v5)  # {2,-2}
    assert int(dut.fpsr_state.value) & 0x10  # IXC from scvtf/fcvtzs


@cocotb.test()
async def test_p7_4_operand_c_back_to_back_raw(dut):
    """连续 scalar/NEON FMA 必须从已寄存结果读取 operand_c。"""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    words = [
        fma_scalar(0, 0, False, 4, 0, 1, 2),  # S4 = 2*3 + 10 = 16
        fma_scalar(0, 0, False, 4, 0, 1, 4),  # S4 = 2*3 + 16 = 22
        neon_fma(3, 0, 1, False, False, False),  # V3 = {16,16}
        neon_fma(3, 0, 1, False, False, False),  # V3 = {22,22}
        0x14000000,
    ]
    vectors = {
        0: 0x4000000040000000,
        1: 0x4040000040400000,
        2: 0x41200000,
        3: 0x4120000041200000,
    }
    await _load_words(dut, words)
    await _restore(dut, vectors=vectors)
    packets = await _collect(dut, 900)

    scalar_second = next(p for p in packets if p["pc"] == BASE + 4)
    assert scalar_second["vec"] == [(4, 0x00000000000000000000000041B00000)]
    neon_second = next(p for p in packets if p["pc"] == BASE + 12)
    assert neon_second["vec"] == [(3, 0x000000000000000041B0000041B00000)]
    assert int(dut.fp_v_lo[3].value) == 0x41B0000041B00000
    assert int(dut.fp_v_hi[3].value) == 0


@cocotb.test()
async def test_p7_4_fpen_trap_no_effect(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await _load_words(dut, [fma_scalar(0, 0, False, 3, 0, 1, 2),
                            0x14000000])
    await _restore(dut, vectors={0: 0x40000000, 1: 0x40400000,
                                 2: 0x41200000}, cpacr=0)
    packets = await _collect(dut, 500)
    first = next(p for p in packets if p["pc"] == BASE)
    assert first["exc_valid"] and first["exc_code"] == 0x07
    assert first["exc_esr"] == 0x1FE00000
    assert not first["vec"] and not first["gpr_we"]
    assert int(dut.fp_v_lo[3].value) == 0
    assert int(dut.fp_v_hi[3].value) == 0


@cocotb.test()
async def test_p7_4_backpressure(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    words = [fma_scalar(0, 0, False, 3, 0, 1, 2), 0x14000000]
    vectors = {0: 0x40000000, 1: 0x40400000, 2: 0x41200000}
    await _load_words(dut, words)
    await _restore(dut, vectors=vectors, fpcr=0x00800000)  # RM
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
    assert got == 0x41800000, hex(got)
    assert int(dut.fpsr_state.value) == 0


@cocotb.test()
async def test_p7_4_unsupported_udef(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    # FP16 scalar FMA（esz=11）与向量 fixed 转换都必须在矩阵外 UDEF。
    cases = [
        0x1F800000,                      # FP16 FMADD 形式
        0x5F20D800,                      # SCVTF 向量定点形式（未接入）
    ]
    for insn in cases:
        await _load_words(dut, [insn, 0x14000000])
        await _restore(dut)
        packets = await _collect(dut, 500)
        first = next(p for p in packets if p["pc"] == BASE)
        assert first["exc_valid"] and first["exc_code"] == 0, f"{insn:08x}"
        assert not first["vec"] and not first["gpr_we"]
