"""B3-L2-WB 的独立 Cocotb smoke/协议测试。

测试只连接扁平化 L2 endpoint、独立字节 BFM 和 probe-free wrapper，验证
write-allocate、dirty victim writeback、响应保持、fault retry 与 ID 回传。
完整 probe/maintenance/global-scan 场景由独立 SV TB 覆盖。
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ReadWrite, RisingEdge


LINE_BYTES = 64
NO_MAINT = 0


async def tick(dut, count=1):
    for _ in range(count):
        await RisingEdge(dut.clk)
        await ReadWrite()


def word_for(pattern, offset=0):
    value = 0
    for lane in range(8):
        value |= ((pattern + offset + lane) & 0xFF) << (lane * 8)
    return value


async def init_line(dut, addr, pattern):
    for chunk in range(8):
        dut.init_we.value = 1
        dut.init_addr.value = addr + chunk * 8
        dut.init_strb.value = 0xFF
        dut.init_wdata.value = word_for(pattern, chunk * 8)
        await tick(dut)
    dut.init_we.value = 0


async def reset_dut(dut):
    dut.rst_n.value = 0
    dut.req_valid.value = 0
    dut.rsp_ready.value = 0
    dut.fault_enable.value = 0
    dut.fault_addr.value = 0
    dut.fault_we_only.value = 0
    dut.init_we.value = 0
    await tick(dut, 3)
    assert not int(dut.rsp_valid.value), "reset 不得产生 stale response"
    dut.rst_n.value = 1
    await tick(dut)


async def access(dut, *, addr, write=False, strb=0, wdata=0,
                 bypass=False, source=0, transaction=0):
    dut.req_addr.value = addr
    dut.req_we.value = int(write)
    dut.req_strb.value = strb
    dut.req_wdata.value = wdata
    dut.req_maint.value = NO_MAINT
    dut.req_bypass.value = int(bypass)
    dut.req_source_id.value = source
    dut.req_transaction_id.value = transaction
    dut.req_valid.value = 1

    for _ in range(10000):
        if int(dut.req_ready.value):
            break
        await tick(dut)
    else:
        raise AssertionError("request READY timeout")
    await tick(dut)
    dut.req_valid.value = 0

    for _ in range(10000):
        if int(dut.rsp_valid.value):
            break
        await tick(dut)
    else:
        raise AssertionError("response VALID timeout")

    saved = (
        int(dut.rsp_rdata.value), int(dut.rsp_fault.value),
        int(dut.rsp_source_id.value), int(dut.rsp_transaction_id.value),
    )
    await tick(dut, 2)
    assert int(dut.rsp_valid.value), "response VALID 在 READY=0 时丢失"
    assert saved == (
        int(dut.rsp_rdata.value), int(dut.rsp_fault.value),
        int(dut.rsp_source_id.value), int(dut.rsp_transaction_id.value),
    ), "response payload/ID 在 READY=0 时改变"
    assert saved[2] == source and saved[3] == transaction, "response ID mismatch"
    dut.rsp_ready.value = 1
    await tick(dut)
    dut.rsp_ready.value = 0
    return saved[0], bool(saved[1])


@cocotb.test()
async def test_write_allocate_writeback_and_fault_retry(dut):
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset_dut(dut)

    # 0x100/0x500/0x900 map to one 2-way set (SETS=4).
    await init_line(dut, 0x100, 0x10)
    await init_line(dut, 0x500, 0x20)
    await init_line(dut, 0x900, 0x30)
    await init_line(dut, 0x140, 0x40)
    await init_line(dut, 0x540, 0x50)
    await init_line(dut, 0x940, 0x60)

    data, fault = await access(
        dut, addr=0x100, source=1, transaction=0x11
    )
    assert not fault and data == word_for(0x10)
    _, fault = await access(
        dut, addr=0x104, write=True, strb=0x0F,
        wdata=0x8877665544332211, source=2, transaction=0x22
    )
    assert not fault
    await access(dut, addr=0x500, source=3, transaction=0x33)

    # 0x100 is dirty LRU; eviction must write all 8 beats before refill.
    await access(dut, addr=0x900, source=4, transaction=0x44)
    data, fault = await access(
        dut, addr=0x100, bypass=True, source=5, transaction=0x55
    )
    assert not fault and data == 0x44332211_13121110, "dirty victim lost"
    assert int(dut.write_count.value) >= 8, "writeback beat not observed"

    # A second dirty victim proves that a writeback fault preserves metadata;
    # retry must repeat the writeback and complete the refill.
    await access(dut, addr=0x140, source=6, transaction=0x66)
    await access(
        dut, addr=0x144, write=True, strb=0x03,
        wdata=0x000000000000BBAA, source=7, transaction=0x77
    )
    await access(dut, addr=0x540, source=8, transaction=0x88)
    dut.fault_enable.value = 1
    dut.fault_addr.value = 0x140
    dut.fault_we_only.value = 1
    _, fault = await access(dut, addr=0x940, source=9, transaction=0x99)
    assert fault, "writeback fault must reach core"
    dut.fault_enable.value = 0
    data, fault = await access(dut, addr=0x940, source=10, transaction=0xAA)
    assert not fault and data == word_for(0x60)
    data, fault = await access(
        dut, addr=0x140, bypass=True, source=11, transaction=0xBB
    )
    assert not fault and data == 0x4746BBAA43424140, "fault retry lost victim"
    assert int(dut.accepted_count.value) == int(dut.response_count.value)
