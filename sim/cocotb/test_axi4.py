"""B1-AXI4 独立闭环 Cocotb 验证。

所有数据均按 raw little-endian byte lane 比较；BFM seed 由 Makefile 固定，
方便失败重放。测试只连接 lcvex_axi4_cocotb_tb，不依赖 SoC/core/filelist。
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ReadWrite, RisingEdge


DATA_WIDTH = 128
BYTE_LANES = 16
MAX_BURST_LEN = 16
AXI_INCR = 0b01
AXI_FIXED = 0b00
RESP_OKAY = 0b00
RESP_SLVERR = 0b10
RESP_DECERR = 0b11


async def tick(dut, count=1):
    for _ in range(count):
        await RisingEdge(dut.clk)
        # ReadWrite keeps the coroutine in a legal drive phase while allowing
        # all sequential RTL updates from this edge to settle.
        await ReadWrite()


def pack_beats(beats):
    value = 0
    for index, beat in enumerate(beats):
        value |= (beat & ((1 << DATA_WIDTH) - 1)) << (DATA_WIDTH * index)
    return value


def pack_strobes(strobes):
    value = 0
    for index, strobe in enumerate(strobes):
        value |= (strobe & ((1 << BYTE_LANES) - 1)) << (BYTE_LANES * index)
    return value


async def reset_dut(dut):
    dut.rst_n.value = 0
    dut.cfg_random_stall.value = 0
    dut.cfg_block_aw.value = 0
    dut.cfg_block_w.value = 0
    dut.cfg_block_ar.value = 0
    dut.cfg_write_error.value = 0
    dut.cfg_read_error.value = 0
    dut.req_valid.value = 0
    dut.req_write.value = 0
    dut.req_addr.value = 0
    dut.req_id.value = 0
    dut.req_len.value = 0
    dut.req_size.value = 0
    dut.req_burst.value = AXI_INCR
    dut.req_wdata.value = 0
    dut.req_wstrb.value = 0
    dut.rsp_ready.value = 1
    await tick(dut, 3)
    dut.rst_n.value = 1
    await tick(dut, 1)


async def send_command(dut, *, write, addr, ident, length, size, burst,
                       wdata=0, wstrb=0):
    dut.req_write.value = int(write)
    dut.req_addr.value = addr
    dut.req_id.value = ident
    dut.req_len.value = length
    dut.req_size.value = size
    dut.req_burst.value = burst
    dut.req_wdata.value = wdata
    dut.req_wstrb.value = wstrb
    dut.req_valid.value = 1
    while not int(dut.req_ready.value):
        await tick(dut)
    await tick(dut)
    dut.req_valid.value = 0


async def receive(dut, *, ident, expected_beats, write, hold_first=False):
    beats = []
    response = RESP_OKAY
    while True:
        while not int(dut.rsp_valid.value):
            await tick(dut)

        if hold_first and not beats:
            dut.rsp_ready.value = 0
            saved = (
                int(dut.rsp_id.value), int(dut.rsp_rdata.value),
                int(dut.rsp_resp.value), int(dut.rsp_last.value),
            )
            await tick(dut, 3)
            assert int(dut.rsp_valid.value), "response VALID 在 READY=0 时丢失"
            assert (
                int(dut.rsp_id.value), int(dut.rsp_rdata.value),
                int(dut.rsp_resp.value), int(dut.rsp_last.value)
            ) == saved, "response payload 在 READY=0 时改变"
            dut.rsp_ready.value = 1

        assert bool(dut.rsp_write.value) == write, "response 类型错误"
        assert int(dut.rsp_id.value) == ident, "response ID 不匹配"
        response = int(dut.rsp_resp.value)
        last = bool(dut.rsp_last.value)
        beats.append(int(dut.rsp_rdata.value))
        await tick(dut)
        if last:
            break

    assert len(beats) == expected_beats, (
        f"response beats={len(beats)} expected={expected_beats}"
    )
    return beats, response


async def write(dut, *, addr, ident, length, size, burst, beats, strobes,
                hold_response=False):
    await send_command(
        dut, write=True, addr=addr, ident=ident, length=length, size=size,
        burst=burst, wdata=pack_beats(beats), wstrb=pack_strobes(strobes)
    )
    return (await receive(
        dut, ident=ident, expected_beats=1, write=True,
        hold_first=hold_response
    ))[1]


async def read(dut, *, addr, ident, length, size, burst, expected_beats=None,
               hold_response=False):
    await send_command(
        dut, write=False, addr=addr, ident=ident, length=length, size=size,
        burst=burst
    )
    if expected_beats is None:
        expected_beats = length + 1
    return await receive(
        dut, ident=ident, expected_beats=expected_beats, write=False,
        hold_first=hold_response
    )


@cocotb.test()
async def test_canonical_line_random_backpressure(dut):
    await reset_dut(dut)
    dut.cfg_random_stall.value = 1

    beats = [
        int.from_bytes(bytes((0x20 + index + offset) & 0xFF
                             for offset in range(16)), "little")
        for index in range(4)
    ]
    strobes = [0xFFFF] * 4
    response = await write(
        dut, addr=0x1000, ident=1, length=3, size=4, burst=AXI_INCR,
        beats=beats, strobes=strobes, hold_response=True
    )
    assert response == RESP_OKAY, f"canonical write BRESP={response:#x}"
    read_beats, response = await read(
        dut, addr=0x1000, ident=1, length=3, size=4, burst=AXI_INCR,
        hold_response=True
    )
    assert response == RESP_OKAY, f"canonical read RRESP={response:#x}"
    assert read_beats == beats, "64B/4-beat canonical line raw bits 不一致"


@cocotb.test()
async def test_aw_w_independence_and_payload_hold(dut):
    await reset_dut(dut)
    dut.cfg_random_stall.value = 0
    beat = 0x0123456789ABCDEFFFEEDDCCBBAA9988

    # AW is held off while W is accepted first.
    dut.cfg_block_aw.value = 1
    await send_command(
        dut, write=True, addr=0x200, ident=2, length=0, size=4,
        burst=AXI_INCR, wdata=beat, wstrb=0xFFFF
    )
    while not (int(dut.dbg_wvalid.value) and int(dut.dbg_wready.value)):
        await tick(dut)
    assert int(dut.dbg_awvalid.value) and not int(dut.dbg_awready.value)
    await tick(dut)
    assert not int(dut.dbg_wvalid.value), "W beat 未在独立 READY 下完成"
    assert int(dut.dbg_awvalid.value), "AWVALID 未在 AWREADY 背压时保持"
    dut.cfg_block_aw.value = 0
    _, response = await receive(
        dut, ident=2, expected_beats=1, write=True
    )
    assert response == RESP_OKAY

    # W is now held while AW is accepted; payload must remain stable.
    dut.cfg_block_w.value = 1
    await send_command(
        dut, write=True, addr=0x220, ident=3, length=0, size=4,
        burst=AXI_INCR, wdata=beat ^ 0x55, wstrb=0x00FF
    )
    while not (int(dut.dbg_awvalid.value) and int(dut.dbg_awready.value)):
        await tick(dut)
    await tick(dut)
    assert int(dut.dbg_wvalid.value) and not int(dut.dbg_wready.value)
    saved = (int(dut.dbg_wdata.value), int(dut.dbg_wstrb.value),
             int(dut.dbg_wlast.value))
    await tick(dut, 3)
    assert (int(dut.dbg_wdata.value), int(dut.dbg_wstrb.value),
            int(dut.dbg_wlast.value)) == saved
    dut.cfg_block_w.value = 0
    _, response = await receive(
        dut, ident=3, expected_beats=1, write=True
    )
    assert response == RESP_OKAY


@cocotb.test()
async def test_narrow_error_boundary_and_reset_abort(dut):
    await reset_dut(dut)
    dut.cfg_random_stall.value = 1

    # Two bytes in lanes 2/3: WSTRB and narrow SIZE are both observable.
    narrow_data = 0xEF << 24 | 0xBE << 16
    response = await write(
        dut, addr=0x302, ident=4, length=0, size=1, burst=AXI_INCR,
        beats=[narrow_data], strobes=[0x000C]
    )
    assert response == RESP_OKAY
    full, response = await read(
        dut, addr=0x300, ident=4, length=0, size=4, burst=AXI_INCR
    )
    assert response == RESP_OKAY and (full[0] >> 16) & 0xFFFF == 0xEFBE

    dut.cfg_write_error.value = 1
    response = await write(
        dut, addr=0x340, ident=5, length=0, size=4, burst=AXI_INCR,
        beats=[0], strobes=[0xFFFF], hold_response=True
    )
    assert response == RESP_SLVERR
    dut.cfg_write_error.value = 0
    dut.cfg_read_error.value = 1
    _, response = await read(
        dut, addr=0x340, ident=5, length=0, size=4, burst=AXI_INCR,
        hold_response=True
    )
    assert response == RESP_SLVERR
    dut.cfg_read_error.value = 0

    # Invalid bursts are converted to one local DECERR response and never
    # assert an AXI address channel.
    response = await write(
        dut, addr=0x0FFC, ident=6, length=0, size=4, burst=AXI_INCR,
        beats=[0], strobes=[0xFFFF]
    )
    assert response == RESP_DECERR
    _, response = await read(
        dut, addr=0x0FF0, ident=6, length=3, size=4, burst=AXI_INCR,
        expected_beats=1
    )
    assert response == RESP_DECERR
    _, response = await read(
        dut, addr=0x400, ident=6, length=0, size=7, burst=AXI_INCR,
        expected_beats=1
    )
    assert response == RESP_DECERR
    _, response = await read(
        dut, addr=0x400, ident=6, length=0, size=4, burst=AXI_FIXED,
        expected_beats=1
    )
    assert response == RESP_DECERR

    # Reset while AW is blocked must discard W/AW state and any later B.
    dut.cfg_random_stall.value = 0
    dut.cfg_block_aw.value = 1
    await send_command(
        dut, write=True, addr=0x380, ident=7, length=0, size=4,
        burst=AXI_INCR, wdata=0xAA, wstrb=0xFFFF
    )
    while not (int(dut.dbg_wvalid.value) and int(dut.dbg_wready.value)):
        await tick(dut)
    await tick(dut)
    dut.rst_n.value = 0
    await tick(dut, 3)
    assert not int(dut.dbg_awvalid.value)
    assert not int(dut.dbg_wvalid.value)
    assert not int(dut.rsp_valid.value)
    dut.rst_n.value = 1
    dut.cfg_block_aw.value = 0
    await tick(dut, 1)
    response = await write(
        dut, addr=0x3C0, ident=8, length=0, size=4, burst=AXI_INCR,
        beats=[0x55], strobes=[0xFFFF]
    )
    assert response == RESP_OKAY
