"""T-20260905-004 standalone mul/div request-capture tests.

The wrapper exposes the request pins as top-level signals.  Each request is
deliberately followed by live-input changes; only the captured transaction may
affect the result.
"""

import cocotb
from cocotb.triggers import RisingEdge, Timer


MASK64 = (1 << 64) - 1


async def settle():
    await Timer(1, unit="ns")


async def reset_dut(dut):
    dut.start.value = 0
    dut.kill.value = 0
    dut.op.value = 0
    dut.is_32.value = 0
    dut.a.value = 0
    dut.b.value = 0
    dut.acc.value = 0
    dut.rst_n.value = 0
    for _ in range(2):
        await RisingEdge(dut.clk)
        await settle()
    assert int(dut.busy.value) == 0
    assert int(dut.done.value) == 0
    assert int(dut.result.value) == 0
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)
    await settle()


async def check_case(dut, op, is_32, a, b, acc, expected, name):
    dut.op.value = op
    dut.is_32.value = is_32
    dut.a.value = a
    dut.b.value = b
    dut.acc.value = acc
    dut.kill.value = 0
    dut.start.value = 1
    await RisingEdge(dut.clk)
    await settle()
    assert int(dut.busy.value) == 1, f"{name}: capture did not assert busy"

    # The request is already captured.  These values must not leak into active
    # state, including the SDIV sign and 32-bit-width decisions.
    dut.start.value = 0
    dut.op.value = 0xF
    dut.is_32.value = not is_32
    dut.a.value = 0xDEAD_BEEF_DEAD_BEEF
    dut.b.value = 0x0123_4567_89AB_CDEF
    dut.acc.value = MASK64

    for _ in range(140):
        await RisingEdge(dut.clk)
        await settle()
        if int(dut.done.value):
            got = int(dut.result.value) & MASK64
            assert got == expected, (
                f"{name}: got 0x{got:016x}, expected 0x{expected:016x}"
            )
            break
    else:
        raise AssertionError(f"{name}: timeout waiting for done")

    await RisingEdge(dut.clk)
    await settle()
    assert int(dut.busy.value) == 0, f"{name}: busy held after done"
    assert int(dut.done.value) == 0, f"{name}: done held after done"
    assert int(dut.result.value) == 0, f"{name}: result held after done"


async def check_kill(dut, active, name):
    dut.op.value = 0
    dut.is_32.value = 0
    dut.a.value = 0x1234_5678_9ABC_DEF0
    dut.b.value = 3
    dut.acc.value = 0
    dut.kill.value = 0
    dut.start.value = 1
    await RisingEdge(dut.clk)
    await settle()
    dut.start.value = 0
    assert int(dut.busy.value) == 1, f"{name}: pending request not busy"
    if active:
        await RisingEdge(dut.clk)
        await settle()
        assert int(dut.busy.value) == 1, f"{name}: active request not busy"
    dut.kill.value = 1
    await RisingEdge(dut.clk)
    await settle()
    dut.kill.value = 0
    assert int(dut.busy.value) == 0, f"{name}: kill left busy"
    assert int(dut.done.value) == 0, f"{name}: kill left done"
    assert int(dut.result.value) == 0, f"{name}: kill left result"
    await RisingEdge(dut.clk)
    await settle()
    assert int(dut.busy.value) == 0, f"{name}: killed request resurrected"


@cocotb.test()
async def test_muldiv_request_capture(dut):
    await reset_dut(dut)
    cases = [
        (0, 0, 0x1234, 0x56, 0, 0x61D78, "MUL X"),
        (0, 1, 0xFFFF_FFFF_1234_5678, 5, 0, 0x0000_0000_5B05_B058, "MUL W"),
        (3, 0, 3, 4, 7, 19, "MADD X"),
        (4, 0, 3, 4, 7, MASK64 - 4, "MSUB X"),
        (5, 0, 0xFFFF_FFFE, 3, 5, MASK64, "SMADDL"),
        (6, 0, 0xFFFF_FFFE, 3, 5, 11, "SMSUBL"),
        (7, 0, 0xFFFF_FFFF, 2, 1, 0x1_FFFF_FFFF, "UMADDL"),
        (8, 0, 0xFFFF_FFFF, 2, 1, 0xFFFF_FFFE_0000_0003, "UMSUBL"),
        (9, 0, MASK64, 2, 0, 1, "UMULH X"),
        (10, 0, MASK64, 2, 0, MASK64, "SMULH X"),
        (1, 0, 256, 3, 0, 0x55, "UDIV X"),
        (1, 1, 0xFFFF_FFFF_0000_0100, 3, 0, 0x55, "UDIV W"),
        (2, 0, 0xFFFF_FFFF_FFFF_FF9C, 3, 0, MASK64 - 32, "SDIV X"),
        (2, 1, 0xFFFF_FFFF_FFFF_FF9C, 3, 0, 0xFFFF_FFDF, "SDIV W"),
        (1, 0, 0x1234, 0, 0, 0, "UDIV X div0"),
        (2, 0, 0xFFFF_FFFF_FFFF_FF9C, 0, 0, 0, "SDIV X div0"),
        (1, 1, 0xFFFF_FFFF_0000_0100, 0, 0, 0, "UDIV W div0"),
        (2, 1, 0xFFFF_FFFF_FFFF_FF9C, 0, 0, 0, "SDIV W div0"),
    ]
    for case in cases:
        await check_case(dut, *case)
    await check_kill(dut, False, "pending kill")
    await check_kill(dut, True, "active kill")
