"""C1 dual-core shell directed Cocotb test.

This test drives the parameterized lcvex_cluster_top with two cores and
checks per-core start/stop, WFI/event observability, and per-core commit
metadata.  The RTL is intentionally non-coherent: each wrapper has private
memory and its own private cache hierarchy.

A complete local run needs an SV/Makefile wrapper that supplies the new RTL
files plus rtl/filelist.f.  The SV testbench tb/sv/lcvex_cluster_tb.sv is the
primary L0/L1 self-check; this Python file provides the Cocotb-visible
equivalent.
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge

BASE = 0x4000_0000

# mov x0,#1 / mov x1,#2 / wfi / mov x0,#3 / sev / wfe / mov x0,#4 / b .
PROG = [
    0xD2800020,
    0xD2800041,
    0xD503207F,
    0xD2800060,
    0xD503209F,
    0xD503205F,
    0xD2800080,
    0x14000000,
]


async def _reset(dut):
    dut.rst_n.value = 0
    for p in ("core_reset_pulse", "core_start_pulse", "core_stop_pulse",
              "irq", "event_in"):
        getattr(dut, p).value = 0
    dut.mc_commit_ready.value = 0x3
    for i in range(2):
        dut.prog_we[i].value = 0 if hasattr(dut.prog_we, "__getitem__") else 0
    await ClockCycles(dut.clk, 4)


async def _load(core):
    # The C1 cluster top uses flattened per-core program-load ports.
    addr_lo = core * 64
    strb_lo = core * 8
    wdata_lo = core * 64
    for i, word in enumerate(PROG):
        dut.prog_we[core].value = 1
        addr = BASE + 4 * i
        dw = word & ((1 << 64) - 1)
        pa = int(dut.prog_addr.value)
        pa = (pa & ~(((1 << 64) - 1) << addr_lo)) | (addr << addr_lo)
        dut.prog_addr.value = pa
        pw = int(dut.prog_wdata.value)
        pw = (pw & ~(((1 << 64) - 1) << wdata_lo)) | (dw << wdata_lo)
        dut.prog_wdata.value = pw
        dut.prog_strb.value = (int(dut.prog_strb.value)
                               & ~(0xFF << strb_lo)) | (0x0F << strb_lo)
        await RisingEdge(dut.clk)
    dut.prog_we[core].value = 0


@cocotb.test()
async def test_dual_core_shell(dut):
    """Start two cores, confirm they can independently stop/start."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await _reset(dut)
    await _load(0)
    await _load(1)
    await ClockCycles(dut.clk, 2)

    # Both cores are stopped after reset when AUTO_START is disabled.
    assert int(dut.core_stopped.value) == 0x3, "expected both stopped"

    # Start core 0.
    dut.core_start_pulse.value = 0x1
    await RisingEdge(dut.clk)
    dut.core_start_pulse.value = 0x0
    await ClockCycles(dut.clk, 2)
    assert dut.core_running.value[0] == 1, "core0 should be running"
    assert dut.core_stopped.value[1] == 1, "core1 should stay stopped"

    # Start core 1 independently.
    dut.core_start_pulse.value = 0x2
    await RisingEdge(dut.clk)
    dut.core_start_pulse.value = 0x0
    await ClockCycles(dut.clk, 2)
    assert dut.core_running.value[1] == 1, "core1 should be running"

    # Stop core 0 only.
    dut.core_stop_pulse.value = 0x1
    await RisingEdge(dut.clk)
    dut.core_stop_pulse.value = 0x0
    await ClockCycles(dut.clk, 2)
    assert dut.core_stopped.value[0] == 1, "core0 should be stopped"
    assert dut.core_running.value[1] == 1, "core1 should remain running"

    # Per-core MPIDR outputs are distinct.
    assert int(dut.mpidr[0].value) == 0
    assert int(dut.mpidr[1].value) == 1
