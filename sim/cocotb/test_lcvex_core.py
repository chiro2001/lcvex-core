"""RTL 核心 ↔ QEMU 差分测试（P2 / 随机回归）。

需要 QEMU_TRACE 环境变量指向 lcvex-qemu-trace v1 文件：
  make difftest-rtl
程序镜像由 PROGRAM_BIN 指定（默认 build/difftest/p2.bin），
从文件读出指令字并写入 SRAM。
流程：复位期间把 P2 测试程序写入 SRAM → 释放复位 → 收集提交包 →
用提交包更新参考状态并与 QEMU 逐指令比较。
"""

import os
import sys
from pathlib import Path

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge

_DIFFTEST = Path(__file__).resolve().parents[1] / "difftest"
sys.path.insert(0, str(_DIFFTEST))

from qemu_trace import parse_trace  # noqa: E402
from state_model import A64State  # noqa: E402
from test_program import BASE  # noqa: E402

MASK64 = (1 << 64) - 1

# 验证专用 checkpoint 恢复口在普通 Cocotb 路径不可悬空；锁步协调器
# 才会在 QEMU sidecar 恢复边界驱动它。
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
        "pc": int(dut.commit_pc.value) & MASK64,
        "next_pc": int(dut.commit_next_pc.value) & MASK64,
        "insn": int(dut.commit_insn.value),
        "gpr_we": bool(dut.commit_gpr_we.value),
        "gpr_rd": int(dut.commit_gpr_rd.value),
        "gpr_wdata": int(dut.commit_gpr_wdata.value) & MASK64,
        "gpr2_we": bool(dut.commit_gpr2_we.value),
        "gpr2_rd": int(dut.commit_gpr2_rd.value),
        "gpr2_wdata": int(dut.commit_gpr2_wdata.value) & MASK64,
        "gpr3_we": bool(dut.commit_gpr3_we.value),
        "gpr3_rd": int(dut.commit_gpr3_rd.value),
        "gpr3_wdata": int(dut.commit_gpr3_wdata.value) & MASK64,
        "sp_we": bool(dut.commit_sp_we.value),
        "sp_wdata": int(dut.commit_sp_wdata.value) & MASK64,
        "nzcv_we": bool(dut.commit_nzcv_we.value),
        "nzcv": int(dut.commit_nzcv.value),
        "mem_we": bool(dut.commit_mem_we.value),
        "mem_addr": int(dut.commit_mem_addr.value) & MASK64,
        "mem_wdata": int(dut.commit_mem_wdata.value) & MASK64,
        "mem_strb": int(dut.commit_mem_strb.value),
        "mem2_we": bool(dut.commit_mem2_we.value),
        "mem2_addr": int(dut.commit_mem2_addr.value) & MASK64,
        "mem2_wdata": int(dut.commit_mem2_wdata.value) & MASK64,
        "mem2_strb": int(dut.commit_mem2_strb.value),
    }


def _qemu_stores(rec):
    stores = []
    for i in range(int(rec.get("stores", 0))):
        stores.append((
            int(rec[f"s{i}_addr"], 16),
            int(rec[f"s{i}_data"], 16),
            int(rec[f"s{i}_size"]),
        ))
    return stores


def _compare(pkt, rec, state, idx):
    errors = []
    label = f"insn[{idx}] pc=0x{pkt['pc']:016x} insn=0x{pkt['insn']:08x}"

    if pkt["pc"] != int(rec["pc"], 16):
        errors.append(f"{label}: pc RTL=0x{pkt['pc']:016x} "
                      f"QEMU=0x{int(rec['pc'], 16):016x}")
    if pkt["next_pc"] != int(rec["next_pc"], 16):
        errors.append(f"{label}: next_pc RTL=0x{pkt['next_pc']:016x} "
                      f"QEMU=0x{int(rec['next_pc'], 16):016x}")

    # 用 RTL 提交包更新参考状态
    if pkt["gpr_we"] and pkt["gpr_rd"] != 31:
        state.x[pkt["gpr_rd"]] = pkt["gpr_wdata"]
    if pkt["gpr2_we"] and pkt["gpr2_rd"] != 31:
        state.x[pkt["gpr2_rd"]] = pkt["gpr2_wdata"]
    if pkt["gpr3_we"] and pkt["gpr3_rd"] != 31:
        state.x[pkt["gpr3_rd"]] = pkt["gpr3_wdata"]
    if pkt["sp_we"]:
        state.sp = pkt["sp_wdata"]
    if pkt["nzcv_we"]:
        state.nzcv = pkt["nzcv"]

    for r in range(31):
        want = int(rec[f"x{r}"], 16)
        if state.x[r] != want:
            errors.append(f"{label}: x{r} RTL=0x{state.x[r]:016x} "
                          f"QEMU=0x{want:016x}")
    for name, val in (("sp", state.sp), ("nzcv", state.nzcv)):
        want = int(rec[name], 16)
        if val != want:
            errors.append(f"{label}: {name} RTL=0x{val:x} QEMU=0x{want:x}")

    rtl_stores = []
    if pkt["mem_we"]:
        size = bin(pkt["mem_strb"]).count("1")
        rtl_stores.append((pkt["mem_addr"], pkt["mem_wdata"], size))
    if pkt["mem2_we"]:
        size = bin(pkt["mem2_strb"]).count("1")
        rtl_stores.append((pkt["mem2_addr"], pkt["mem2_wdata"], size))
    qemu_stores = _qemu_stores(rec)
    if rtl_stores != qemu_stores:
        errors.append(f"{label}: 内存写 RTL={rtl_stores} QEMU={qemu_stores}")
    return errors


def _read_words(path):
    with open(path, "rb") as f:
        data = f.read()
    assert len(data) % 4 == 0, f"镜像长度不是 4 的倍数：{path}"
    return [int.from_bytes(data[i:i + 4], "little")
            for i in range(0, len(data), 4)]


@cocotb.test()
async def test_p2_difftest(dut):
    trace_path = os.environ.get("QEMU_TRACE")
    assert trace_path, "缺少 QEMU_TRACE 环境变量（make difftest-rtl）"

    records = parse_trace(trace_path)
    init = records[0]
    commits = [r for r in records[1:] if r["tag"] == "commit"]
    assert init["tag"] == "init", "trace 首行应为 init"

    program_bin = os.environ.get("PROGRAM_BIN",
                                 str(_DIFFTEST / ".." / ".." / "build" /
                                     "difftest" / "p2.bin"))
    words = _read_words(program_bin)
    assert len(commits) >= len(words), \
        f"QEMU trace 提交数 {len(commits)} < 程序指令数 {len(words)}"

    # 复位期间加载程序
    dut.rst_n.value = 0
    dut.commit_ready.value = 1   # M1：差分路径提交消费者恒就绪
    dut.difftest_wait_release.value = 0
    dut.difftest_wait_cntvct_valid.value = 0
    dut.difftest_wait_cntvct.value = 0
    _clear_restore_ports(dut)
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await ClockCycles(dut.clk, 2)
    dut.prog_we.value = 1
    for i, word in enumerate(words):
        dut.prog_addr.value = BASE + 4 * i
        dut.prog_strb.value = 0x0F
        dut.prog_wdata.value = word
        await RisingEdge(dut.clk)
    dut.prog_we.value = 0
    dut.rst_n.value = 1

    # 运行并收集提交
    packets = []
    # 多周期乘除（64 周期）需要更大预算；乘除结果前递到后续指令
    max_cycles = 96 * len(words) + 4096
    for _ in range(max_cycles):
        await RisingEdge(dut.clk)
        if bool(dut.commit_valid.value):
            packets.append(_read_packet(dut))
            if len(packets) >= len(words):
                break
    assert len(packets) == len(words), \
        f"RTL 提交数 {len(packets)} != 程序指令数 {len(words)}"

    state = A64State(
        pc=int(init["pc"], 16),
        x=[int(init[f"x{i}"], 16) for i in range(31)],
        sp=int(init["sp"], 16),
        nzcv=int(init["nzcv"], 16),
    )

    errors = []
    for i, (pkt, rec) in enumerate(zip(packets, commits)):
        errors.extend(_compare(pkt, rec, state, i))
    if errors:
        for e in errors:
            cocotb.log.error(e)
        raise AssertionError(f"RTL 与 QEMU 差分不一致：{len(errors)} 处")
    cocotb.log.info(f"PASS: {len(packets)} 条指令与 QEMU 完全一致")
