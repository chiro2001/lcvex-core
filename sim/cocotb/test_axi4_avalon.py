"""B2-EMIF 双时钟 AXI4/Avalon 独立随机回归。

AXI 使用 B1 的 128-bit Full profile，Avalon BFM 使用 512-bit/64B word。
所有 seed、时钟比、校准和 reset 场景都在本文件中可重放；测试不依赖
CPU、Cache、SoC、filelist 或厂商 Quartus/IP。
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ReadOnly, RisingEdge, Timer, with_timeout


BASE = 0x40000000
INCR = 0b01
OKAY = 0b00
DECERR = 0b11
_clock_tasks = []


async def cpu_edges(dut, count=1):
    for _ in range(count):
        await RisingEdge(dut.cpu_clk)
        await ReadOnly()


async def drive_phase():
    """Move out of Cocotb's ReadOnly phase before changing a DUT input."""
    await Timer(1, unit="ps")


def start_clocks(dut, cpu_period_ns, emif_period_ns):
    global _clock_tasks
    for task in _clock_tasks:
        task.kill()
    _clock_tasks = [
        cocotb.start_soon(Clock(dut.cpu_clk, cpu_period_ns, unit="ns").start()),
        cocotb.start_soon(Clock(dut.emif_clk, emif_period_ns, unit="ns").start()),
    ]


async def wait_cpu_handshake(dut, ready_name):
    """Sample READY before the next rising edge, where the handshake occurs."""
    while True:
        # Advancing here (rather than stacking ReadOnly waits) also handles a
        # caller that just observed an EMIF edge in ReadOnly phase.
        await Timer(1, unit="ns")
        ready = int(dut[ready_name].value)
        await RisingEdge(dut.cpu_clk)
        await ReadOnly()
        if ready:
            return


def set_axi_defaults(dut):
    for name in (
        "awvalid", "awid", "awaddr", "awlen", "awsize", "awburst",
        "awlock", "awcache", "awprot", "awqos", "wvalid", "wdata",
        "wstrb", "wlast", "bready", "arvalid", "arid", "araddr",
        "arlen", "arsize", "arburst", "arlock", "arcache", "arprot",
        "arqos", "rready",
    ):
        dut[name].value = 0
    dut.awburst.value = INCR
    dut.arburst.value = INCR


async def reset_dut(dut, *, success=False):
    await drive_phase()
    dut.cpu_rst_n.value = 0
    dut.emif_rst_n.value = 0
    dut.cal_success.value = 0
    dut.cal_fail.value = 0
    dut.cfg_random_wait.value = 0
    dut.cfg_force_wait.value = 0
    dut.cfg_read_delay.value = 0
    dut.cfg_drop_readdatavalid.value = 0
    dut.cfg_preserve_read_pending.value = 0
    set_axi_defaults(dut)
    await Timer(1, unit="ns")
    await cpu_edges(dut, 3)
    await drive_phase()
    dut.cpu_rst_n.value = 1
    await cpu_edges(dut, 1)
    await drive_phase()
    dut.emif_rst_n.value = 1
    await cpu_edges(dut, 2)
    assert not int(dut.awready.value)
    assert not int(dut.arready.value)
    assert not int(dut.wready.value)
    if success:
        await drive_phase()
        dut.cal_success.value = 1
        await cpu_edges(dut, 4)
        assert int(dut.awready.value) and int(dut.arready.value)


async def send_aw(dut, addr, ident, length, size=4, burst=INCR):
    await drive_phase()
    dut.awaddr.value = addr
    dut.awid.value = ident
    dut.awlen.value = length
    dut.awsize.value = size
    dut.awburst.value = burst
    dut.awvalid.value = 1
    await wait_cpu_handshake(dut, "awready")
    await drive_phase()
    dut.awvalid.value = 0


async def send_w_beat(dut, data, strobe, last):
    await drive_phase()
    dut.wdata.value = data
    dut.wstrb.value = strobe
    dut.wlast.value = int(last)
    dut.wvalid.value = 1
    await wait_cpu_handshake(dut, "wready")
    await drive_phase()
    dut.wvalid.value = 0


async def get_b(dut, ident, *, hold=True):
    await drive_phase()
    dut.bready.value = 0
    while True:
        await RisingEdge(dut.cpu_clk)
        await ReadOnly()
        if int(dut.bvalid.value):
            saved = (int(dut.bid.value), int(dut.bresp.value))
            if hold:
                await cpu_edges(dut, 3)
                assert int(dut.bvalid.value)
                assert (int(dut.bid.value), int(dut.bresp.value)) == saved
                await drive_phase()
            await drive_phase()
            dut.bready.value = 1
            await RisingEdge(dut.cpu_clk)
            await ReadOnly()
            await drive_phase()
            dut.bready.value = 0
            assert saved[0] == ident
            return saved[1]


async def write(dut, *, addr, ident, beats, strobes, size=4, burst=INCR,
                aw_delay=0):
    length = len(beats) - 1
    w_task = cocotb.start_soon(
        _send_w_burst(dut, beats, strobes, length)
    )
    if aw_delay:
        await cpu_edges(dut, aw_delay)
    await send_aw(dut, addr, ident, length, size, burst)
    await w_task
    return await get_b(dut, ident)


async def _send_w_burst(dut, beats, strobes, length):
    for index, (data, strobe) in enumerate(zip(beats, strobes)):
        await send_w_beat(dut, data, strobe, index == length)


async def send_ar(dut, addr, ident, length, size=4, burst=INCR):
    await drive_phase()
    dut.araddr.value = addr
    dut.arid.value = ident
    dut.arlen.value = length
    dut.arsize.value = size
    dut.arburst.value = burst
    dut.arvalid.value = 1
    await wait_cpu_handshake(dut, "arready")
    await drive_phase()
    dut.arvalid.value = 0


async def read(dut, *, addr, ident, length, size=4, burst=INCR, hold=True):
    await send_ar(dut, addr, ident, length, size, burst)
    await drive_phase()
    dut.rready.value = 0
    result = []
    # First wait for a beat while RREADY is low. For subsequent beats sample
    # RVALID/RDATA before the consuming rising edge; the adapter may advance
    # its beat counter immediately after that edge and deassert RVALID on the
    # final beat.
    while True:
        await RisingEdge(dut.cpu_clk)
        await ReadOnly()
        if int(dut.rvalid.value):
            break

    first = True
    while True:
        saved = (
            int(dut.rid.value), int(dut.rdata.value),
            int(dut.rresp.value), int(dut.rlast.value),
        )
        if first and hold:
            await cpu_edges(dut, 3)
            assert int(dut.rvalid.value)
            assert (
                int(dut.rid.value), int(dut.rdata.value),
                int(dut.rresp.value), int(dut.rlast.value),
            ) == saved
        await drive_phase()
        dut.rready.value = 1
        await RisingEdge(dut.cpu_clk)
        await ReadOnly()
        result.append(saved)
        if saved[3]:
            await drive_phase()
            dut.rready.value = 0
            assert saved[0] == ident
            if saved[2] == DECERR:
                assert len(result) == 1
            else:
                assert len(result) == length + 1
            return result, saved[2]

        first = False
        while not int(dut.rvalid.value):
            await RisingEdge(dut.cpu_clk)
            await ReadOnly()


def line_beats(seed):
    return [
        int.from_bytes(bytes((seed + beat * 16 + n) & 0xFF
                             for n in range(16)), "little")
        for beat in range(4)
    ]


@cocotb.test()
async def test_line_width_mapping_and_random_clocking(dut):
    """4-beat aggregation, address units, byteenable and CDC pressure."""
    start_clocks(dut, 10, 6)
    await reset_dut(dut, success=True)
    await drive_phase()
    dut.cfg_random_wait.value = 1

    beats = line_beats(0x20)
    response = await with_timeout(
        write(dut, addr=BASE + 0x2000, ident=1, beats=beats,
              strobes=[0xFFFF] * 4), 10, "us"
    )
    assert response == OKAY
    assert int(dut.write_accept_count.value) == 1
    assert int(dut.read_accept_count.value) == 0
    assert int(dut.avalon_address.value) == 0x2000 >> 6
    result, response = await with_timeout(
        read(dut, addr=BASE + 0x2000, ident=1, length=3), 10, "us"
    )
    assert response == OKAY
    assert [item[1] for item in result] == beats
    assert int(dut.read_accept_count.value) == 1

    # B1 lane-form narrow write: bytes in WDATA lanes 2/3 and WSTRB[2:3]
    # must land at line bytes 2/3. Then exercise normalized low WSTRB too.
    lane_data = 0xEFBE << 16
    response = await write(
        dut, addr=BASE + 0x2202, ident=2, beats=[lane_data],
        strobes=[0x000C], size=1,
    )
    assert response == OKAY
    assert int(dut.avalon_byteenable.value) == 0xC
    result, response = await read(
        dut, addr=BASE + 0x2200, ident=2, length=0,
    )
    assert response == OKAY and ((result[0][1] >> 16) & 0xFFFF) == 0xEFBE

    normalized_data = 0x3412
    response = await write(
        dut, addr=BASE + 0x2303, ident=3, beats=[normalized_data],
        strobes=[0x0003], size=1,
    )
    assert response == OKAY
    assert int(dut.avalon_byteenable.value) == 0x18
    result, response = await read(
        dut, addr=BASE + 0x2300, ident=3, length=0,
    )
    assert response == OKAY and ((result[0][1] >> 24) & 0xFFFF) == 0x3412


@cocotb.test()
async def test_local_decerr_and_calibration_gate(dut):
    start_clocks(dut, 8, 14)
    await reset_dut(dut, success=True)

    before_w = int(dut.write_accept_count.value)
    response = await write(
        dut, addr=BASE + 0x3FF0, ident=4,
        beats=[0, 0], strobes=[0xFFFF, 0xFFFF],
    )
    assert response == DECERR
    assert int(dut.write_accept_count.value) == before_w
    _, response = await read(
        dut, addr=BASE + 0x3FF0, ident=4, length=1,
    )
    assert response == DECERR

    # A failure after an Avalon read has been accepted aborts the normal
    # transaction: its delayed readdatavalid is drained and cannot become R.
    dut.cfg_read_delay.value = 4
    await send_ar(dut, BASE + 0x2500, 5, 0)
    await drive_phase()
    dut.rready.value = 0
    before_r = int(dut.read_accept_count.value)
    while not (int(dut.avalon_read.value) and
               int(dut.avalon_waitrequest_n.value)):
        await RisingEdge(dut.emif_clk)
        await ReadOnly()
    await RisingEdge(dut.emif_clk)
    await ReadOnly()
    assert int(dut.read_accept_count.value) == before_r + 1
    await drive_phase()
    dut.cal_fail.value = 1
    await cpu_edges(dut, 8)
    assert int(dut.rvalid.value)
    aborted_read = (
        int(dut.rid.value), int(dut.rdata.value),
        int(dut.rresp.value), int(dut.rlast.value),
    )
    assert aborted_read[0] == 5
    assert aborted_read[1] == 0 and aborted_read[2] == DECERR and aborted_read[3]
    await cpu_edges(dut, 3)
    assert int(dut.rvalid.value)
    assert (
        int(dut.rid.value), int(dut.rdata.value),
        int(dut.rresp.value), int(dut.rlast.value),
    ) == aborted_read
    await drive_phase()
    dut.rready.value = 1
    await RisingEdge(dut.cpu_clk)
    await ReadOnly()
    await drive_phase()
    dut.rready.value = 0

    # A latched failure accepts a complete write only for local DECERR and
    # never asserts an Avalon command.
    await drive_phase()
    dut.cal_fail.value = 1
    await cpu_edges(dut, 3)
    assert not int(dut.avalon_read.value)
    assert not int(dut.avalon_write.value)
    before_w = int(dut.write_accept_count.value)
    response = await write(
        dut, addr=BASE + 0x2400, ident=5, beats=[0], strobes=[0xFFFF],
    )
    assert response == DECERR
    assert int(dut.write_accept_count.value) == before_w
    _, response = await read(
        dut, addr=BASE + 0x2400, ident=5, length=0,
    )
    assert response == DECERR


@cocotb.test()
async def test_reset_flush_and_readdatavalid(dut):
    start_clocks(dut, 10, 6)
    await reset_dut(dut, success=True)
    await drive_phase()
    dut.cfg_read_delay.value = 15
    await send_ar(dut, BASE + 0x2600, 6, 0)
    await drive_phase()
    dut.rready.value = 1
    while not (int(dut.avalon_read.value) and
               int(dut.avalon_waitrequest_n.value)):
        await RisingEdge(dut.emif_clk)
        await ReadOnly()

    # Assert both reset inputs asynchronously and release them at different
    # edges. The BFM is reset with the same epoch, so its pending response is
    # discarded along with both adapter FIFOs.
    await drive_phase()
    dut.cpu_rst_n.value = 0
    await Timer(1, unit="ns")
    await drive_phase()
    dut.emif_rst_n.value = 0
    await cpu_edges(dut, 3)
    await drive_phase()
    dut.cpu_rst_n.value = 1
    await cpu_edges(dut, 2)
    await drive_phase()
    dut.emif_rst_n.value = 1
    dut.cal_success.value = 1
    dut.arvalid.value = 0
    dut.rready.value = 0
    await cpu_edges(dut, 6)
    assert not int(dut.rvalid.value)

    await drive_phase()
    dut.cfg_read_delay.value = 2
    result, response = await read(
        dut, addr=BASE + 0x2600, ident=6, length=0,
    )
    assert response == OKAY and len(result) == 1
    assert int(dut.duplicate_response_count.value) == 0


@cocotb.test()
async def test_bounded_backend_timeout_and_late_response(dut):
    """Timeouts are DECERR and a late read cannot create a second response."""
    start_clocks(dut, 8, 14)
    await reset_dut(dut, success=True)

    before_w = int(dut.write_accept_count.value)
    await drive_phase()
    dut.cfg_force_wait.value = 1
    response = await with_timeout(
        write(dut, addr=BASE + 0x2700, ident=7,
              beats=[0], strobes=[0xFFFF]), 5, "us"
    )
    assert response == DECERR
    assert int(dut.write_accept_count.value) == before_w

    # Keep the accepted Avalon read pending but suppress its response until
    # after the adapter has timed out.  The pending response must be drained
    # and the following epoch must still complete normally.
    await drive_phase()
    dut.cfg_force_wait.value = 0
    dut.cfg_drop_readdatavalid.value = 1
    dut.cfg_read_delay.value = 0
    before_r = int(dut.read_accept_count.value)
    result, response = await with_timeout(
        read(dut, addr=BASE + 0x2800, ident=8, length=0), 5, "us"
    )
    assert response == DECERR and len(result) == 1
    assert int(dut.read_accept_count.value) == before_r + 1
    await drive_phase()
    dut.cfg_drop_readdatavalid.value = 0
    for _ in range(4):
        await RisingEdge(dut.emif_clk)
        await ReadOnly()
    result, response = await with_timeout(
        read(dut, addr=BASE + 0x2C00, ident=9, length=0), 5, "us"
    )
    assert response == OKAY and len(result) == 1
    assert result[0][0] == 9
    # Avalon word 0xB0 is deliberately different from the timed-out word
    # 0xA0. A stale response satisfying this new request would fail here.
    assert result[0][1] == line_beats(0xB0)[0]
    assert int(dut.read_accept_count.value) == before_r + 2
    assert int(dut.duplicate_response_count.value) == 0


@cocotb.test()
async def test_partial_write_channels_survive_emif_reset(dut):
    """AW-first and W-first collection pauses cleanly across EMIF reset."""
    start_clocks(dut, 10, 6)
    await reset_dut(dut, success=True)
    await drive_phase()
    # Preserve BFM counters across the EMIF-only reset; there is no pending
    # read in these cases, so this does not alter backend response behavior.
    dut.cfg_preserve_read_pending.value = 1
    before_w = int(dut.write_accept_count.value)

    # AW-first: the address is accepted, then EMIF reset pauses W collection.
    await send_aw(dut, BASE + 0x2E00, 12, 0)
    assert not int(dut.avalon_write.value)
    await drive_phase()
    dut.emif_rst_n.value = 0
    await cpu_edges(dut, 4)
    for _ in range(3):
        await RisingEdge(dut.emif_clk)
        await ReadOnly()
        assert not int(dut.avalon_write.value)
    assert not int(dut.wready.value)
    await drive_phase()
    dut.emif_rst_n.value = 1
    await cpu_edges(dut, 4)
    assert int(dut.wready.value)
    await send_w_beat(dut, 0x112233445566778899AABBCCDDEEFF00,
                      0xFFFF, True)
    response = await get_b(dut, 12)
    assert response == OKAY
    assert int(dut.write_accept_count.value) == before_w + 1

    # W-first: retain the buffered final beat while EMIF reset is asserted,
    # then accept the matching AW after release.
    await send_w_beat(dut, 0xFFEEDDCCBBAA99887766554433221100,
                      0xFFFF, True)
    assert not int(dut.avalon_write.value)
    await drive_phase()
    dut.emif_rst_n.value = 0
    await cpu_edges(dut, 4)
    for _ in range(3):
        await RisingEdge(dut.emif_clk)
        await ReadOnly()
        assert not int(dut.avalon_write.value)
    assert not int(dut.awready.value)
    await drive_phase()
    dut.emif_rst_n.value = 1
    await cpu_edges(dut, 4)
    assert int(dut.awready.value)
    await send_aw(dut, BASE + 0x3000, 13, 0)
    response = await get_b(dut, 13)
    assert response == OKAY
    assert int(dut.write_accept_count.value) == before_w + 2
    assert int(dut.read_accept_count.value) == 0
    assert int(dut.duplicate_response_count.value) == 0
    await drive_phase()
    dut.cfg_preserve_read_pending.value = 0


@cocotb.test()
async def test_emif_reset_while_avalon_command_stalled(dut):
    """SVA drops stall bookkeeping but keeps CPU DECERR/re-arm semantics."""
    start_clocks(dut, 10, 6)
    await reset_dut(dut, success=True)
    await drive_phase()
    dut.cfg_preserve_read_pending.value = 1
    dut.cfg_force_wait.value = 1
    dut.araddr.value = BASE + 0x2100
    dut.arid.value = 13
    dut.arlen.value = 0
    dut.arsize.value = 4
    dut.arburst.value = INCR
    dut.arvalid.value = 1
    dut.rready.value = 0
    await wait_cpu_handshake(dut, "arready")
    await drive_phase()
    dut.arvalid.value = 0
    while not (int(dut.avalon_read.value) and
               not int(dut.avalon_waitrequest_n.value)):
        await RisingEdge(dut.emif_clk)
        await ReadOnly()

    await drive_phase()
    dut.emif_rst_n.value = 0
    saved = None
    for _ in range(12):
        await RisingEdge(dut.cpu_clk)
        await ReadOnly()
        if int(dut.rvalid.value):
            saved = (
                int(dut.rid.value), int(dut.rdata.value),
                int(dut.rresp.value), int(dut.rlast.value),
            )
            break
    assert saved is not None
    assert saved[0] == 13 and saved[1] == 0
    assert saved[2] == DECERR and saved[3]
    for _ in range(3):
        await cpu_edges(dut, 1)
        assert (
            int(dut.rid.value), int(dut.rdata.value),
            int(dut.rresp.value), int(dut.rlast.value),
        ) == saved

    await drive_phase()
    dut.rready.value = 1
    for _ in range(4):
        await RisingEdge(dut.cpu_clk)
        await ReadOnly()
        if not int(dut.rvalid.value):
            break
    assert not int(dut.rvalid.value)
    await drive_phase()
    dut.rready.value = 0
    dut.emif_rst_n.value = 1
    dut.cfg_force_wait.value = 0
    await cpu_edges(dut, 4)

    result, response = await with_timeout(
        read(dut, addr=BASE + 0x2F00, ident=14, length=0), 5, "us"
    )
    assert response == OKAY and len(result) == 1
    assert result[0][0] == 14
    assert result[0][1] == line_beats(0xBC)[0]
    assert int(dut.read_accept_count.value) == 1
    assert int(dut.duplicate_response_count.value) == 0
    await drive_phase()
    dut.cfg_preserve_read_pending.value = 0


@cocotb.test()
async def test_emif_only_reset_abort_and_response_hold(dut):
    """An EMIF-only reset returns one held DECERR for an accepted read."""
    start_clocks(dut, 10, 6)
    await reset_dut(dut, success=True)
    await drive_phase()
    dut.cfg_preserve_read_pending.value = 1
    dut.cfg_read_delay.value = 8
    dut.araddr.value = BASE + 0x2900
    dut.arid.value = 10
    dut.arlen.value = 0
    dut.arsize.value = 4
    dut.arburst.value = INCR
    dut.arvalid.value = 1
    dut.rready.value = 0
    before_r = int(dut.read_accept_count.value)
    await wait_cpu_handshake(dut, "arready")
    await drive_phase()
    dut.arvalid.value = 0
    while not (int(dut.avalon_read.value) and
               int(dut.avalon_waitrequest_n.value)):
        await RisingEdge(dut.emif_clk)
        await ReadOnly()
    # Let the BFM observe one actual acceptance edge before asserting reset;
    # otherwise a same-delta reset could test a never-issued request.
    await RisingEdge(dut.emif_clk)
    await ReadOnly()
    assert int(dut.read_accept_count.value) == before_r + 1

    await drive_phase()
    dut.emif_rst_n.value = 0
    saved = None
    for _ in range(12):
        await RisingEdge(dut.cpu_clk)
        await ReadOnly()
        if int(dut.rvalid.value):
            saved = (
                int(dut.rid.value), int(dut.rdata.value),
                int(dut.rresp.value), int(dut.rlast.value),
            )
            break
    assert saved is not None
    assert saved[0] == 10 and saved[2] == DECERR and saved[3]
    assert saved[1] == 0

    for _ in range(3):
        await cpu_edges(dut, 1)
        assert int(dut.rvalid.value)
        assert (
            int(dut.rid.value), int(dut.rdata.value),
            int(dut.rresp.value), int(dut.rlast.value),
        ) == saved

    await drive_phase()
    dut.rready.value = 1
    for _ in range(4):
        await RisingEdge(dut.cpu_clk)
        await ReadOnly()
        if not int(dut.rvalid.value):
            break
    assert not int(dut.rvalid.value)
    await drive_phase()
    dut.rready.value = 0
    dut.emif_rst_n.value = 1
    late_seen = False
    for _ in range(16):
        await RisingEdge(dut.emif_clk)
        await ReadOnly()
        if int(dut.avalon_readdatavalid.value):
            late_seen = True
            # The BFM drives readdatavalid as a registered output; give the
            # adapter one following emif_clk edge to sample and retire it.
            await RisingEdge(dut.emif_clk)
            await ReadOnly()
            break
    assert late_seen
    # The poison level crosses back through a two-flop CPU synchronizer; wait
    # for that CDC release before launching the next epoch request.
    await cpu_edges(dut, 3)

    # The preserved backend response is now released and must be drained.
    # Re-arm with a different address/ID and verify the new line data and
    # exactly one additional Avalon acceptance.
    await RisingEdge(dut.cpu_clk)
    await ReadOnly()
    await drive_phase()
    dut.cfg_read_delay.value = 0
    result, response = await with_timeout(
        read(dut, addr=BASE + 0x2D00, ident=11, length=0), 5, "us"
    )
    assert response == OKAY and len(result) == 1
    assert result[0][0] == 11
    assert result[0][1] == line_beats(0xB4)[0]
    assert int(dut.read_accept_count.value) == 2
    assert int(dut.duplicate_response_count.value) == 0

    # Explicit reset is the epoch re-arm boundary after the preserved late
    # response has been drained.
    dut.cal_fail.value = 0
    dut.cfg_preserve_read_pending.value = 0
    dut.cpu_rst_n.value = 0
    dut.emif_rst_n.value = 0
    await cpu_edges(dut, 3)
    await drive_phase()
    dut.cpu_rst_n.value = 1
    dut.emif_rst_n.value = 1
    dut.cal_success.value = 1
    await cpu_edges(dut, 6)
