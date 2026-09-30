"""lcvex_regfile 单元测试：XZR 语义与写回。"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge


@cocotb.test()
async def test_xzr_read(dut):
    """编号 31 读恒为 0。"""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    dut.rs1.value = 31
    dut.rs2.value = 31
    dut.rd.value = 0
    dut.we.value = 0
    dut.wdata.value = 0
    await RisingEdge(dut.clk)
    assert int(dut.rs1_data.value) == 0, "XZR 读必须为 0"
    assert int(dut.rs2_data.value) == 0, "XZR 读必须为 0"


@cocotb.test()
async def test_write_and_readback(dut):
    """写入 x5 后能读回。"""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    dut.rd.value = 5
    dut.we.value = 1
    dut.wdata.value = 0x123456789ABCDEF0
    await RisingEdge(dut.clk)
    dut.we.value = 0
    dut.rs1.value = 5
    await RisingEdge(dut.clk)
    assert int(dut.rs1_data.value) == 0x123456789ABCDEF0, "x5 写回读回"


@cocotb.test()
async def test_write_xzr_discarded(dut):
    """写 rd=31 丢弃，不破坏已有寄存器。"""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    dut.rd.value = 7
    dut.we.value = 1
    dut.wdata.value = 0x77
    await RisingEdge(dut.clk)
    dut.rd.value = 31
    dut.wdata.value = 0xDEADBEEF
    await RisingEdge(dut.clk)
    dut.we.value = 0
    dut.rs1.value = 7
    await RisingEdge(dut.clk)
    assert int(dut.rs1_data.value) == 0x77, "写 XZR 必须丢弃"
