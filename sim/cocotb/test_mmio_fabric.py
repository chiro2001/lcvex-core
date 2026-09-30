"""P6：C++ MMIO fabric 的 Cocotb 独立复现。

同 SV testbench 覆盖 PL031 ID、固定虚拟 RTC、LR/MR/ICR 及未建模设备 fault，
但通过 VPI 逐周期驱动，验证 Cocotb 构建也链接同一份 C++ model。
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge


async def access(dut, addr, *, we=False, strb=0x0F, wdata=0):
    dut.req_addr.value = addr
    dut.req_we.value = int(we)
    dut.req_strb.value = strb
    dut.req_wdata.value = wdata
    dut.req_valid.value = 1
    while not bool(dut.req_accept.value):
        await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    dut.req_valid.value = 0
    while not bool(dut.rsp_valid.value):
        await RisingEdge(dut.clk)
    result = (int(dut.rsp_rdata.value), bool(dut.rsp_fault.value),
              bool(dut.irq.value))
    await RisingEdge(dut.clk)
    return result


@cocotb.test()
async def test_pl031_cpp_fabric(dut):
    dut.rst_n.value = 0
    dut.retire_valid.value = 0
    dut.req_valid.value = 0
    dut.req_addr.value = 0
    dut.req_we.value = 0
    dut.req_strb.value = 0
    dut.req_wdata.value = 0
    dut.rsp_ready.value = 1
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await ClockCycles(dut.clk, 2)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)

    data, fault, _ = await access(dut, 0x09010FE0, strb=0xFF)
    assert not fault and data == 0x00000010_00000031, \
        f"PL031 PID0/1={data:#018x}"
    data, fault, _ = await access(dut, 0x09010000)
    assert not fault and data == 946684800, f"PL031 DR={data:#x}"

    _, fault, _ = await access(dut, 0x09010008, we=True, wdata=0x55AA)
    assert not fault
    data, fault, _ = await access(dut, 0x09010000)
    assert not fault and data == 0x55AA, f"LR 写后 DR={data:#x}"
    await access(dut, 0x09010010, we=True, wdata=1)
    await access(dut, 0x09010004, we=True, wdata=0x55AA)
    data, fault, irq = await access(dut, 0x09010014)
    assert not fault and data == 1 and irq, "同秒 MR 未置 RIS/IRQ"
    await access(dut, 0x0901001C, we=True, wdata=1)
    data, fault, irq = await access(dut, 0x09010018)
    assert not fault and data == 0 and not irq, "ICR 未清 MIS/IRQ"

    _, fault, _ = await access(dut, 0x09020000)
    assert fault, "未建模 fw_cfg 必须返回 fault"
    dut._log.info("PASS: Cocotb PL031 C++ fabric 验证通过")
