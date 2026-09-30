"""B1 标量闭合：logical shifted-register ROR 定向核心测试。

覆盖：
- BASE-DP-018：AND/ORR/EOR/BIC/ORN/EON/ANDS/BICS 的 shift_type=3 (ROR)
- 32 位写零扩展
- XZR 源/目的语义
- ADD/SUB shifted-register shift_type=3 保留编码仍为 UDEF 负测
- 相邻 ADD/SUB 移位寄存器 XZR 与 ADD 立即数 SP 读/写低风险检查
"""

import sys
from pathlib import Path

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ReadOnly, RisingEdge, Timer

_DIFFTEST = Path(__file__).resolve().parents[1] / "difftest"
sys.path.insert(0, str(_DIFFTEST))

from a64 import Insn, assemble  # noqa: E402

BASE = 0x44000000
MASK64 = (1 << 64) - 1
MAX_CYCLES = 3000

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
    "difftest_restore_tcr2_el1", "difftest_restore_contextidr_el1", "difftest_restore_excl_valid",
    "difftest_restore_excl_addr", "difftest_restore_excl_data",
    "difftest_restore_excl_data_hi", "difftest_restore_cntpct",
    "difftest_restore_cntp_cval", "difftest_restore_cntp_ctl",
    "difftest_restore_cntv_cval", "difftest_restore_cntv_ctl",
)


def _clear_restore_ports(dut):
    for name in _RESTORE_PORTS:
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
    _clear_restore_ports(dut)
    await Timer(1, unit="ns")
    for i, word in enumerate(words):
        dut.prog_we.value = 1
        dut.prog_addr.value = BASE + 4 * i
        dut.prog_strb.value = 0x0F
        dut.prog_wdata.value = word
        await RisingEdge(dut.clk)
    dut.prog_we.value = 0
    dut.rst_n.value = 1


def _packet(dut):
    return {
        "pc": int(dut.commit_pc.value) & MASK64,
        "next_pc": int(dut.commit_next_pc.value) & MASK64,
        "insn": int(dut.commit_insn.value),
        "gpr_we": bool(dut.commit_gpr_we.value),
        "gpr_rd": int(dut.commit_gpr_rd.value),
        "gpr_wdata": int(dut.commit_gpr_wdata.value) & MASK64,
        "sp_we": bool(dut.commit_sp_we.value),
        "sp_wdata": int(dut.commit_sp_wdata.value) & MASK64,
        "nzcv_we": bool(dut.commit_nzcv_we.value),
        "nzcv": int(dut.commit_nzcv.value),
        "exc_valid": bool(dut.commit_exc_valid.value),
        "exc_code": int(dut.commit_exc_code.value),
    }


async def _collect(dut, stop_on_exc=False):
    packets = []
    for _ in range(MAX_CYCLES):
        await RisingEdge(dut.clk)
        await ReadOnly()
        if bool(dut.commit_valid.value):
            packets.append(_packet(dut))
            if stop_on_exc and packets[-1]["exc_valid"]:
                break
            if len(packets) >= 80:
                break
    return packets


def _by_pc(packets, pc):
    for pkt in packets:
        if pkt["pc"] == pc:
            return pkt
    raise AssertionError(f"未观察到 PC=0x{pc:08x}；已有 {len(packets)} 个提交")


@cocotb.test()
async def test_logical_ror_xzr_and_zero_ext(dut):
    """成功路径：所有逻辑 ROR 形式 + XZR/32 位零扩展 + 相邻 SP/移位 XZR。"""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())

    words = assemble([
        # x1 = 0x8000000000000001, x2 = all-ones
        Insn("movz", 1, 0x8000, 3),
        Insn("movk", 1, 0x0001),
        Insn("movn", 2, 0),
        # Logical shifted-register ROR positive forms
        Insn("orr",  4, 1, 1, 3, 1),     # x4 = x1 ROR #1
        Insn("and",  5, 1, 1, 3, 63),    # x5 = x1 AND (x1 ROR #63)
        Insn("eor",  6, 1, 1, 3, 8),     # x6 = x1 EOR (x1 ROR #8)
        Insn("bic",  7, 1, 2, 3, 1),     # x7 = x1 BIC (x2 ROR #1) = 0
        Insn("orn",  8, 1, 1, 3, 1),     # x8 = x1 ORN (x1 ROR #1)
        Insn("eon",  9, 1, 1, 3, 1),     # x9 = x1 EON (x1 ROR #1)
        Insn("ands", 10, 1, 1, 3, 8),    # flags update, nonzero
        Insn("bics", 11, 1, 2, 3, 1),    # flags update, zero
        # 32-bit logical ROR and zero-extension
        Insn("orr_w",  12, 1, 1, 3, 8),
        Insn("eor_w",  13, 1, 1, 3, 8),
        Insn("bic_w",  14, 1, 1, 3, 8),
        # XZR source/destination semantics in logical shifted register
        Insn("orr",  15, 31, 1, 3, 1),   # x15 = 0 | (x1 ROR #1)
        Insn("orr",  31, 1, 1, 3, 1),    # writes XZR -> no GPR write
        Insn("and",  16, 1, 31, 3, 1),   # x16 = x1 & 0 = 0
        # Adjacent low-risk checks: XZR in add/sub shifted register
        Insn("add_reg",  17, 31, 1, 0, 0),   # x17 = x1
        Insn("add_reg",  18, 1, 31, 0, 0),   # x18 = x1 + 0
        Insn("add_reg",  31, 1, 1, 0, 0),    # XZR destination -> no write
        # Adjacent SP semantics: ADD/SUB immediate
        Insn("add",  19, 31, 0x123),     # x19 = SP + 0x123 = 0x123
        Insn("add",  31, 31, 0x10),      # SP = SP + 0x10 -> write SP
        Insn("adds", 31, 31, 0),         # ADDS Rd=31 discards result
        Insn("raw", 0x14000000),         # b .
    ], BASE)

    await _load_words(dut, words)
    packets = await _collect(dut)

    def pkt(pc):
        return _by_pc(packets, pc)

    assert pkt(BASE + 0x0C)["gpr_wdata"] == 0xC000000000000001, "ORR ROR #1"
    assert pkt(BASE + 0x10)["gpr_wdata"] == 0x1, "AND with ROR #63"
    assert pkt(BASE + 0x14)["gpr_wdata"] == 0x8180000000000001, "EOR with ROR #8"
    assert pkt(BASE + 0x18)["gpr_wdata"] == 0x0, "BIC with ROR #1"
    assert pkt(BASE + 0x1C)["gpr_wdata"] == 0xBFFFFFFFFFFFFFFF, "ORN with ROR #1"
    assert pkt(BASE + 0x20)["gpr_wdata"] == 0xBFFFFFFFFFFFFFFE, "EON with ROR #1"
    assert pkt(BASE + 0x24)["nzcv"] == 0x0, "ANDS ROR flags"
    assert pkt(BASE + 0x28)["nzcv"] == 0x4, "BICS zero ROR flags"

    assert pkt(BASE + 0x2C)["gpr_wdata"] == 0x0000000001000001, \
        "ORR W ROR #8 高 32 位零扩展"
    assert pkt(BASE + 0x30)["gpr_wdata"] == 0x0000000001000001, \
        "EOR W ROR #8 高 32 位零扩展"
    assert pkt(BASE + 0x34)["gpr_wdata"] == 0x0000000000000001, \
        "BIC W ROR #8 保留低 32 位"

    assert pkt(BASE + 0x38)["gpr_wdata"] == 0xC000000000000000, "XZR source"
    assert not pkt(BASE + 0x3C)["gpr_we"], "XZR destination must not write"
    assert pkt(BASE + 0x40)["gpr_wdata"] == 0x0, "AND with XZR operand"

    assert pkt(BASE + 0x44)["gpr_wdata"] == 0x8000000000000001, \
        "ADD shifted-register XZR source"
    assert pkt(BASE + 0x48)["gpr_wdata"] == 0x8000000000000001, \
        "ADD shifted-register XZR operand"
    assert not pkt(BASE + 0x4C)["gpr_we"], "ADD shifted XZR dest no write"

    assert pkt(BASE + 0x50)["gpr_wdata"] == 0x123, "ADD immediate reads SP"
    assert pkt(BASE + 0x54)["sp_we"], "ADD immediate writes SP"
    assert pkt(BASE + 0x54)["sp_wdata"] == 0x10, "SP = 0 + 0x10"
    assert not pkt(BASE + 0x58)["gpr_we"], "ADDS with Rd=SP discards"

    cocotb.log.info("PASS: logical shifted-register ROR + XZR/SP/zero-extension")


@cocotb.test()
async def test_addsub_ror_stays_udef(dut):
    """负测：ADD/SUB shifted-register 的 shift_type=3 仍为保留编码 -> UDEF。"""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())

    words = assemble([
        Insn("movz", 1, 0x1234),
        # ADD shifted-register ROR #1: decode must reject as reserved
        Insn("add_reg", 20, 1, 1, 3, 1),
        Insn("raw", 0x14000000),
    ], BASE)

    await _load_words(dut, words)
    packets = await _collect(dut, stop_on_exc=True)

    assert len(packets) >= 2, "应看到 movz 后紧跟保留编码异常提交"
    exc = packets[-1]
    assert exc["exc_valid"], "保留 ADD/SUB ROR 未产生异常提交"
    assert exc["exc_code"] == 0, f"期望 EXC_UDEF=0x0，实际 0x{exc['exc_code']:x}"
    assert exc["pc"] == BASE + 4, "异常应由 ADD/SUB ROR 保留编码触发"
    assert not exc["gpr_we"], "UDEF 不应写 GPR"

    cocotb.log.info("PASS: ADD/SUB shifted-register ROR remains UDEF")
