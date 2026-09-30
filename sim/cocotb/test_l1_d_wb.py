"""B4 D-L1/L2 独立 Cocotb 回归。

覆盖随机 partial store/替换、PTW 最新脏数据、逐级 DC/IC maintenance、
checkpoint drain、response backpressure 和 POC fault；不连接 core/SoC/QEMU。
"""

import os
import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ReadWrite, RisingEdge


LINE = 64
NO_MAINT = 0


async def tick(dut, count=1):
    for _ in range(count):
        await RisingEdge(dut.clk)
        await ReadWrite()


def word_for(data, addr):
    return sum(int(data[addr + lane]) << (8 * lane) for lane in range(8))


def make_word(pattern, offset=0):
    return sum(((pattern + offset + lane) & 0xFF) << (8 * lane)
               for lane in range(8))


async def init_line(dut, addr, pattern):
    for chunk in range(8):
        dut.init_we.value = 1
        dut.init_addr.value = addr + chunk * 8
        dut.init_strb.value = 0xFF
        dut.init_wdata.value = make_word(pattern, chunk * 8)
        await tick(dut)
    dut.init_we.value = 0


async def reset_dut(dut):
    dut.rst_n.value = 0
    dut.req_valid.value = 0
    dut.ptw_req_valid.value = 0
    dut.rsp_ready.value = 0
    dut.ptw_rsp_ready.value = 0
    dut.checkpoint_quiesce.value = 0
    dut.checkpoint_ack_ready.value = 0
    dut.fault_enable.value = 0
    dut.fault_addr.value = 0
    dut.fault_we_only.value = 0
    dut.init_we.value = 0
    await tick(dut, 3)
    assert not int(dut.rsp_valid.value)
    assert not int(dut.ptw_rsp_valid.value)
    dut.rst_n.value = 1
    await tick(dut)


async def access(dut, *, addr, write=False, strb=0, wdata=0,
                 maint=NO_MAINT, bypass=False, source=0, transaction=0):
    dut.req_addr.value = addr
    dut.req_we.value = int(write)
    dut.req_strb.value = strb
    dut.req_wdata.value = wdata
    dut.req_maint.value = maint
    dut.req_bypass.value = int(bypass)
    dut.req_source_id.value = source
    dut.req_transaction_id.value = transaction
    dut.req_valid.value = 1
    for _ in range(10000):
        if int(dut.req_ready.value):
            break
        await tick(dut)
    else:
        raise AssertionError("core request READY timeout")
    await tick(dut)
    dut.req_valid.value = 0
    for _ in range(10000):
        if int(dut.rsp_valid.value):
            break
        await tick(dut)
    else:
        raise AssertionError("core response VALID timeout")
    saved = (int(dut.rsp_rdata.value), int(dut.rsp_fault.value),
             int(dut.rsp_source_id.value), int(dut.rsp_transaction_id.value))
    dut.rsp_ready.value = 0
    await tick(dut, 2)
    assert int(dut.rsp_valid.value), "response VALID dropped under backpressure"
    assert saved == (int(dut.rsp_rdata.value), int(dut.rsp_fault.value),
                     int(dut.rsp_source_id.value),
                     int(dut.rsp_transaction_id.value))
    assert saved[2:] == (source, transaction)
    dut.rsp_ready.value = 1
    await tick(dut)
    dut.rsp_ready.value = 0
    return saved[0], bool(saved[1])


async def ptw_access(dut, addr):
    dut.ptw_req_addr.value = addr
    dut.ptw_req_valid.value = 1
    for _ in range(10000):
        if int(dut.ptw_req_ready.value):
            break
        await tick(dut)
    else:
        raise AssertionError("PTW READY timeout")
    await tick(dut)
    dut.ptw_req_valid.value = 0
    for _ in range(10000):
        if int(dut.ptw_rsp_valid.value):
            break
        await tick(dut)
    else:
        raise AssertionError("PTW response timeout")
    result = (int(dut.ptw_rsp_rdata.value), int(dut.ptw_rsp_fault.value))
    dut.ptw_rsp_ready.value = 1
    await tick(dut)
    dut.ptw_rsp_ready.value = 0
    return result


@cocotb.test()
async def test_l1_d_wb_coherence(dut):
    seed = int(os.getenv("SEED", "0x5601"), 0)
    random.seed(seed)
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset_dut(dut)

    model = bytearray(1 << 16)
    for addr, pattern in ((0x100, 0x10), (0x500, 0x50),
                          (0x900, 0x90), (0xD00, 0xD0)):
        for i in range(LINE):
            model[addr + i] = (pattern + i) & 0xFF
        await init_line(dut, addr, pattern)

    data, fault = await access(dut, addr=0x100, source=1, transaction=0x11)
    assert not fault and data == word_for(model, 0x100)

    # Partial stores remain in L1 until a replacement or maintenance drains.
    for n in range(20):
        offset = random.randrange(0, 56)
        strobe = random.randrange(1, 256)
        value = random.getrandbits(64)
        _, fault = await access(dut, addr=0x100 + offset, write=True,
                                strb=strobe, wdata=value,
                                source=2 + (n & 3), transaction=0x20 + n)
        assert not fault
        for lane in range(8):
            if strobe & (1 << lane):
                model[0x100 + offset + lane] = (value >> (8 * lane)) & 0xFF

    data, fault = await ptw_access(dut, 0x100)
    assert not fault and data == word_for(model, 0x100), "PTW saw stale RAM"

    # Same-set replacements exercise L1 WB into L2 and L2 refill traffic.
    for addr in (0x500, 0x900, 0xD00, 0x100, 0x500):
        data, fault = await access(dut, addr=addr, source=5,
                                   transaction=addr & 0xFF)
        assert not fault and data == word_for(model, addr)

    # DC clean and clean+invalidate are sequentially visible at both levels.
    value = 0x0123456789ABCDEF
    _, fault = await access(dut, addr=0x500, write=True, strb=0xFF,
                            wdata=value, source=6, transaction=0x66)
    assert not fault
    for lane in range(8):
        model[0x500 + lane] = (value >> (8 * lane)) & 0xFF
    _, fault = await access(dut, addr=0x500, maint=5, source=7, transaction=0x77)
    assert not fault
    _, fault = await access(dut, addr=0x500, maint=7, source=8, transaction=0x88)
    assert not fault
    data, fault = await access(dut, addr=0x500, source=9, transaction=0x99)
    assert not fault and data == word_for(model, 0x500)
    assert int(dut.probe_count.value) >= 2, "L2 did not issue D-L1 probes"

    # IC IVAU is ordered after the D path and must complete without fault.
    _, fault = await access(dut, addr=0x500, maint=1, source=10, transaction=0xA0)
    assert not fault

    # Successful checkpoint: L1 quiesce/drain precedes the L2 drain request.
    value = 0xAABBCCDDEEFF0011
    _, fault = await access(dut, addr=0x900, write=True, strb=0xFF,
                            wdata=value, source=11, transaction=0xB0)
    assert not fault
    for lane in range(8):
        model[0x900 + lane] = (value >> (8 * lane)) & 0xFF
    dut.checkpoint_quiesce.value = 1
    for _ in range(10000):
        if int(dut.checkpoint_ack_valid.value) or int(dut.checkpoint_fault.value):
            break
        await tick(dut)
    assert int(dut.checkpoint_ack_valid.value)
    assert not int(dut.checkpoint_fault.value)
    assert int(dut.drain_request_count.value) == 1
    assert int(dut.l1_drain_done.value)
    dut.checkpoint_ack_ready.value = 1
    await tick(dut)
    dut.checkpoint_ack_ready.value = 0
    dut.checkpoint_quiesce.value = 0
    await tick(dut, 2)

    # A POC fault suppresses the success ack.  No client stale response may
    # appear after the failed checkpoint epoch is released.
    _, fault = await access(dut, addr=0xD00, write=True, strb=1,
                            wdata=0x5A, source=12, transaction=0xC0)
    assert not fault
    dut.fault_enable.value = 1
    dut.fault_addr.value = 0xD00
    dut.fault_we_only.value = 1
    dut.checkpoint_quiesce.value = 1
    for _ in range(10000):
        if int(dut.checkpoint_fault.value) or int(dut.checkpoint_ack_valid.value):
            break
        await tick(dut)
    assert int(dut.checkpoint_fault.value)
    assert not int(dut.checkpoint_ack_valid.value)
    dut.checkpoint_quiesce.value = 0
    dut.fault_enable.value = 0
    await tick(dut, 2)
    assert not int(dut.rsp_valid.value)
    assert int(dut.accepted_count.value) == int(dut.response_count.value)
    assert int(dut.read_count.value) >= 32
    assert int(dut.write_count.value) >= 8
