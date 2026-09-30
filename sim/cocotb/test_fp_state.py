"""P7-0 standalone FP state/FPEN/trap directed tests.

The wrapper flattens only the V array at the Cocotb boundary. All comparisons
remain raw-bit comparisons; this test does not execute FP/NEON instructions.
"""

import cocotb
from cocotb.triggers import RisingEdge, Timer


FPCR_MASK = 0x07C80000
FPSR_MASK = 0xF800009F
CPACR_FPEN_MASK = 0x00300000
FP_ACCESS_EC = 0x00000007
FP_ACCESS_ESR = 0x1FE00000
V_MASK = (1 << 128) - 1


async def settle(dut, ns=1):
    await Timer(ns, unit="ns")


async def reset_dut(dut):
    dut.current_el.value = 1
    dut.fp_access_valid.value = 0
    dut.sys_commit_valid.value = 0
    dut.sys_fpcr_we.value = 0
    dut.sys_fpsr_we.value = 0
    dut.sys_cpacr_we.value = 0
    dut.commit_valid.value = 0
    dut.commit_vec_write_count.value = 0
    dut.commit_fpcr_we.value = 0
    dut.commit_fpsr_we.value = 0
    dut.difftest_restore_fp_valid.value = 0
    dut.difftest_restore_sys_valid.value = 0
    dut.difftest_restore_v_flat.value = 0
    await settle(dut, 1)
    dut.rst_n.value = 0
    await RisingEdge(dut.clk)
    await settle(dut)
    dut.rst_n.value = 1
    await settle(dut)


def set_v_flat(dut, values):
    flat = 0
    for index, value in enumerate(values):
        flat |= (value & V_MASK) << (128 * index)
    dut.difftest_restore_v_flat.value = flat


def get_v(dut, index):
    flat = int(dut.v_state_flat.value)
    return (flat >> (128 * index)) & V_MASK


async def write_cpacr(dut, fpen, template=0xA5A55A5A00001234):
    expected = (template & ~CPACR_FPEN_MASK) | (fpen << 20)
    dut.current_el.value = 1
    dut.sys_cpacr_wdata.value = expected
    dut.sys_cpacr_we.value = 1
    dut.sys_commit_valid.value = 1
    await settle(dut)
    assert int(dut.sys_cpacr_write_accept.value) == 1
    await RisingEdge(dut.clk)
    await settle(dut)
    dut.sys_commit_valid.value = 0
    dut.sys_cpacr_we.value = 0
    assert int(dut.cpacr_el1_state.value) == expected
    return expected


async def check_access(dut, el, allowed):
    dut.current_el.value = el
    dut.fp_access_valid.value = 1
    await settle(dut)
    assert int(dut.fp_access_allowed.value) == int(allowed)
    assert int(dut.fp_trap_valid.value) == int(not allowed)
    assert int(dut.fp_trap_code.value) == (FP_ACCESS_EC if not allowed else 0)
    assert int(dut.fp_trap_esr.value) == (FP_ACCESS_ESR if not allowed else 0)
    dut.fp_access_valid.value = 0
    await settle(dut)


@cocotb.test()
async def test_reset_cpacr_and_fpen_matrix(dut):
    await reset_dut(dut)

    assert int(dut.fpcr_state.value) == 0
    assert int(dut.fpsr_state.value) == 0
    assert int(dut.cpacr_el1_state.value) == 0
    assert int(dut.v_state_flat.value) == 0

    for fpen in range(4):
        await write_cpacr(dut, fpen)
        await check_access(dut, 0, fpen == 3)
        await check_access(dut, 1, fpen in (1, 3))

    # CPACR is EL1-only and a denied write must preserve non-FPEN bits.
    before = int(dut.cpacr_el1_state.value)
    dut.current_el.value = 0
    dut.sys_cpacr_wdata.value = (1 << 64) - 1
    dut.sys_cpacr_we.value = 1
    dut.sys_commit_valid.value = 1
    await settle(dut)
    assert int(dut.sys_cpacr_write_accept.value) == 0
    assert int(dut.sys_cpacr_write_blocked.value) == 1
    await RisingEdge(dut.clk)
    await settle(dut)
    dut.sys_commit_valid.value = 0
    dut.sys_cpacr_we.value = 0
    assert int(dut.cpacr_el1_state.value) == before


@cocotb.test()
async def test_masks_and_commit_effect_limits(dut):
    await reset_dut(dut)
    await write_cpacr(dut, 3)
    dut.current_el.value = 1
    dut.fp_access_valid.value = 1

    dut.sys_commit_valid.value = 1
    dut.sys_fpcr_we.value = 1
    dut.sys_fpcr_wdata.value = (1 << 32) - 1
    await settle(dut)
    assert int(dut.sys_fpcr_write_accept.value) == 1
    await RisingEdge(dut.clk)
    await settle(dut)
    dut.sys_commit_valid.value = 0
    dut.sys_fpcr_we.value = 0
    assert int(dut.fpcr_state.value) == FPCR_MASK
    assert int(dut.fpcr_read_data.value) == FPCR_MASK

    dut.sys_commit_valid.value = 1
    dut.sys_fpsr_we.value = 1
    dut.sys_fpsr_wdata.value = (1 << 32) - 1
    await settle(dut)
    assert int(dut.sys_fpsr_write_accept.value) == 1
    await RisingEdge(dut.clk)
    await settle(dut)
    dut.sys_commit_valid.value = 0
    dut.sys_fpsr_we.value = 0
    dut.fp_access_valid.value = 0
    assert int(dut.fpsr_state.value) == FPSR_MASK
    assert int(dut.fpsr_read_data.value) == FPSR_MASK

    # A single raw V write and both control-state effects share one commit edge.
    dut.fp_access_valid.value = 1
    dut.commit_valid.value = 1
    dut.commit_vec_write_count.value = 1
    dut.commit_vec_rd0.value = 7
    dut.commit_vec_wdata0.value = 0x0123456789ABCDEFFEDCBA9876543210
    dut.commit_fpcr_we.value = 1
    dut.commit_fpcr_wdata.value = (1 << 32) - 1
    dut.commit_fpsr_we.value = 1
    dut.commit_fpsr_wdata.value = (1 << 32) - 1
    await settle(dut)
    assert int(dut.commit_effect_valid.value) == 1
    assert int(dut.commit_effect_error.value) == 0
    assert int(dut.commit_effect_vec_write_count.value) == 1
    assert int(dut.commit_effect_vec_rd0.value) == 7
    assert int(dut.commit_effect_vec_wdata0.value) == 0x0123456789ABCDEFFEDCBA9876543210
    await RisingEdge(dut.clk)
    await settle(dut)
    dut.commit_valid.value = 0
    dut.commit_vec_write_count.value = 0
    dut.commit_fpcr_we.value = 0
    dut.commit_fpsr_we.value = 0
    dut.fp_access_valid.value = 0
    assert get_v(dut, 7) == 0x0123456789ABCDEFFEDCBA9876543210
    assert int(dut.fpcr_state.value) == FPCR_MASK
    assert int(dut.fpsr_state.value) == FPSR_MASK

    # Four slots are reserved; over-limit and duplicate effects are rejected.
    dut.fp_access_valid.value = 1
    dut.commit_valid.value = 1
    dut.commit_vec_write_count.value = 4
    for signal, rd, data in (
        ("commit_vec_rd0", 1, 1),
        ("commit_vec_rd1", 2, 2),
        ("commit_vec_rd2", 4, 4),
        ("commit_vec_rd3", 8, 8),
    ):
        getattr(dut, signal).value = rd
        getattr(dut, signal.replace("rd", "wdata")).value = data
    await settle(dut)
    assert int(dut.commit_effect_valid.value) == 1
    assert int(dut.commit_effect_error.value) == 0
    await RisingEdge(dut.clk)
    await settle(dut)
    dut.commit_valid.value = 0
    dut.commit_vec_write_count.value = 0
    dut.fp_access_valid.value = 0
    assert [get_v(dut, i) for i in (1, 2, 4, 8)] == [1, 2, 4, 8]

    dut.fp_access_valid.value = 1
    dut.commit_valid.value = 1
    dut.commit_vec_write_count.value = 5
    dut.commit_vec_rd0.value = 9
    dut.commit_vec_wdata0.value = 0x99
    await settle(dut)
    assert int(dut.commit_effect_valid.value) == 0
    assert int(dut.commit_effect_error.value) == 1
    await RisingEdge(dut.clk)
    await settle(dut)
    dut.commit_valid.value = 0
    dut.commit_vec_write_count.value = 0
    dut.fp_access_valid.value = 0
    assert get_v(dut, 9) == 0

    dut.fp_access_valid.value = 1
    dut.commit_valid.value = 1
    dut.commit_vec_write_count.value = 2
    dut.commit_vec_rd0.value = 10
    dut.commit_vec_rd1.value = 10
    dut.commit_vec_wdata0.value = 0xAA
    dut.commit_vec_wdata1.value = 0xBB
    await settle(dut)
    assert int(dut.commit_effect_valid.value) == 0
    assert int(dut.commit_effect_error.value) == 1
    await RisingEdge(dut.clk)
    await settle(dut)
    dut.commit_valid.value = 0
    dut.commit_vec_write_count.value = 0
    dut.fp_access_valid.value = 0
    assert get_v(dut, 10) == 0

    # No FP effect keeps an old scalar commit valid even when FPEN is closed.
    await write_cpacr(dut, 0)
    dut.current_el.value = 0
    dut.commit_valid.value = 1
    await settle(dut)
    assert int(dut.commit_effect_valid.value) == 0
    assert int(dut.commit_effect_error.value) == 0
    await RisingEdge(dut.clk)
    await settle(dut)
    dut.commit_valid.value = 0


@cocotb.test()
async def test_trap_no_side_effect_and_same_edge_restore(dut):
    await reset_dut(dut)
    await write_cpacr(dut, 0)
    dut.current_el.value = 0
    dut.fp_access_valid.value = 1
    dut.commit_valid.value = 1
    dut.commit_vec_write_count.value = 1
    dut.commit_vec_rd0.value = 3
    dut.commit_vec_wdata0.value = 0xDEADBEEF
    await settle(dut)
    assert int(dut.fp_trap_valid.value) == 1
    assert int(dut.fp_trap_code.value) == FP_ACCESS_EC
    assert int(dut.fp_trap_esr.value) == FP_ACCESS_ESR
    assert int(dut.commit_effect_valid.value) == 0
    assert int(dut.commit_effect_error.value) == 1
    await RisingEdge(dut.clk)
    await settle(dut)
    dut.commit_valid.value = 0
    dut.commit_vec_write_count.value = 0
    dut.fp_access_valid.value = 0
    assert get_v(dut, 3) == 0

    restore_values = [
        ((0x1000000000000000 + i) << 64) | (0x2000000000000000 + i)
        for i in range(32)
    ]
    set_v_flat(dut, restore_values)
    dut.difftest_restore_fpcr.value = (1 << 32) - 1
    dut.difftest_restore_fpsr.value = (1 << 32) - 1
    restore_cpacr = 0x5AA5135700C0FFEE
    dut.difftest_restore_cpacr_el1.value = restore_cpacr
    dut.difftest_restore_fp_valid.value = 1
    dut.difftest_restore_sys_valid.value = 1
    # A conflicting commit must not win over the restore boundary.
    dut.commit_valid.value = 1
    dut.commit_vec_write_count.value = 1
    dut.commit_vec_rd0.value = 31
    dut.commit_vec_wdata0.value = (1 << 128) - 1
    dut.fp_access_valid.value = 1
    await settle(dut)
    assert int(dut.commit_effect_valid.value) == 0
    assert int(dut.commit_effect_error.value) == 0
    await RisingEdge(dut.clk)
    await settle(dut)
    dut.difftest_restore_fp_valid.value = 0
    dut.difftest_restore_sys_valid.value = 0
    dut.commit_valid.value = 0
    dut.commit_vec_write_count.value = 0
    dut.fp_access_valid.value = 0

    assert int(dut.fpcr_state.value) == FPCR_MASK
    assert int(dut.fpsr_state.value) == FPSR_MASK
    assert int(dut.cpacr_el1_state.value) == restore_cpacr
    assert [get_v(dut, i) for i in range(32)] == restore_values
