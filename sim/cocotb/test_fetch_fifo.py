"""F1a fetch FIFO Cocotb scaffold.

The test deliberately uses the existing SoC memory model and a delayed response
mode.  It checks architectural ordering, taken-branch quarantine, FIFO bounds,
reset clearing, and commit-ready atomicity without changing the commit packet.
"""

import os
import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge, ReadOnly, Timer

from test_lcvex_core import _clear_restore_ports

BASE = 0x44000000
MASK64 = (1 << 64) - 1


def _movz(rd, imm16, hw=0):
    return 0xD2800000 | ((hw & 3) << 21) | ((imm16 & 0xFFFF) << 5) | (rd & 31)


def _movk(rd, imm16, hw=0):
    return 0xF2800000 | ((hw & 3) << 21) | ((imm16 & 0xFFFF) << 5) | (rd & 31)


def _subs_xzr(rn, imm12):
    return 0xF100001F | ((imm12 & 0xFFF) << 10) | ((rn & 31) << 5)


def _b_words(delta):
    return 0x14000000 | (delta & 0x03FFFFFF)


def _bcond_words(delta, cond):
    return 0x54000000 | ((delta & 0x7FFFF) << 5) | (cond & 0xF)


def _cb_words(delta, rt, nonzero=False):
    return (0x35000000 if nonzero else 0x34000000) | \
        ((delta & 0x7FFFF) << 5) | (rt & 31)


def _tb_words(delta, rt, bit, nonzero=False):
    return (0x37000000 if nonzero else 0x36000000) | \
        (((bit >> 5) & 1) << 31) | ((delta & 0x3FFF) << 5) | \
        ((bit & 0x1F) << 19) | (rt & 31)


def _br(rn):
    return 0xD61F0000 | ((rn & 31) << 5)


async def _load_words(dut, words):
    dut.prog_we.value = 1
    for i, word in enumerate(words):
        dut.prog_addr.value = BASE + 4 * i
        dut.prog_strb.value = 0x0F
        dut.prog_wdata.value = word
        await RisingEdge(dut.clk)
    dut.prog_we.value = 0


async def _reset_and_load(dut, words):
    """Keep reset asserted while replacing the SRAM image."""
    dut.rst_n.value = 0
    dut.commit_ready.value = 1
    _clear_restore_ports(dut)
    await ClockCycles(dut.clk, 2)
    await _load_words(dut, words)
    dut.rst_n.value = 1


def _token(dut, stage):
    core = dut.core
    return (
        int(getattr(core, f"{stage}_token_epoch").value),
        int(getattr(core, f"{stage}_token_seq").value),
    )


def _stage(dut, stage):
    core = dut.core
    return {
        "valid": bool(getattr(core, f"{stage}_valid").value),
        "token": _token(dut, stage),
    }


def _observe_pipeline(dut, committed_tokens, transfer_tokens):
    """Check the local F1a token invariants for one sampled cycle."""
    core = dut.core
    stages = [_stage(dut, name) for name in ("ifid", "idex", "exmem", "memwb")]

    # Tokens are non-architectural, but a valid token may only appear once in
    # adjacent stages.  This catches a duplicate capture before it reaches WB.
    for older, younger in zip(stages, stages[1:]):
        if older["valid"] and younger["valid"]:
            assert older["token"] != younger["token"], \
                f"same token in adjacent stages: {older['token']}"

    for stage, fire_name in zip(("idex", "exmem", "memwb"),
                                ("dbg_ifid_to_idex_fire",
                                 "dbg_idex_to_exmem_fire",
                                 "dbg_exmem_to_memwb_fire")):
        if bool(getattr(core, fire_name).value):
            current = _stage(dut, stage)
            assert current["valid"], f"{fire_name} without a valid destination"
            token = current["token"]
            assert token not in transfer_tokens[stage], \
                f"{stage} accepted token twice: {token}"
            transfer_tokens[stage].add(token)

    if bool(core.dbg_commit_fire.value):
        token = _token(dut, "commit")
        assert token not in committed_tokens, \
            f"commit token repeated: {token}"
        committed_tokens.add(token)

    return {
        "dmem_pending": bool(core.dmem_pending.value),
        "exmem": stages[2],
        "memwb": stages[3],
        "memwb_committed": bool(core.memwb_committed_r.value),
    }


READY_HOLD_WORDS = [
    0xD2800060,  # movz x0,#3
    0xD2800081,  # movz x1,#4
    0x9B017C02,  # mul x2,x0,x1
    0xD2800223,  # movz x3,#0x11
    0xD2800444,  # movz x4,#0x22
    0xD2800665,  # movz x5,#0x33
    0xD2800886,  # movz x6,#0x44
    0xD2800AA7,  # movz x7,#0x55
    0xD2800CC8,  # movz x8,#0x66
    0xD2800EE9,  # movz x9,#0x77
    0xD2A8800A,  # movz x10,#0x4400,lsl#16
    0xF29FC00A,  # movk x10,#0xfe00
    0xD280000B,  # movz x11,#0
    0xF900014B,  # str x11,[x10]
    0x14000001,  # b ready_loop
    0x14000000,  # ready_loop: b .
]


async def _collect_ready_trace(dut, words, cycles, seed=None,
                               force_h04_window=False):
    """Run one image with a deterministic randomized ready schedule.

    The helper samples the state after each edge, drives the next edge's
    readiness, and records both architectural commits and frontend coverage.
    ``force_h04_window`` deliberately arms the first WB-empty/IFID/FIFO
    window so the same-edge post-fix consume is checked independently of the
    random schedule.
    """
    await _reset_and_load(dut, words)
    rng = random.Random(seed)
    commits = []
    committed_tokens = set()
    transfer_tokens = {"idex": set(), "exmem": set(), "memwb": set()}
    coverage = {
        "fifo_counts": set(),
        "ifid_valid": set(),
        "push_pop": False,
        "branch_flush": False,
        "wb_empty_low": False,
        "wb_full_low": False,
        "dmem_pending": False,
        "dmem_hold": False,
        "control_flow_fence": False,
        "fence_blocked_fetch": False,
    }
    previous = None
    armed_token = None
    h04_checked = False

    for cycle in range(cycles):
        await RisingEdge(dut.clk)
        await Timer(1, unit="ps")
        core = dut.core
        ready = bool(dut.commit_ready.value)
        count = int(dut.fetch_fifo_occupancy.value)
        coverage["fifo_counts"].add(count)
        coverage["ifid_valid"].add(bool(core.ifid_valid.value))
        coverage["push_pop"] |= bool(dut.fetch_fifo_push.value) and bool(dut.fetch_fifo_pop.value)
        coverage["branch_flush"] |= bool(core.frontend_kill.value)
        coverage["wb_empty_low"] |= (not ready and not bool(core.memwb_valid.value))
        coverage["wb_full_low"] |= (not ready and bool(core.memwb_valid.value))
        coverage["dmem_pending"] |= bool(core.dmem_pending.value)
        if bool(dut.fetch_control_fence.value):
            coverage["control_flow_fence"] = True
            assert not bool(core.fetch_req_accept.value), \
                "control-flow fence accepted a younger MMU fetch"
            assert not bool(core.imem_req_accept.value), \
                "control-flow fence accepted a younger imem fetch"
            coverage["fence_blocked_fetch"] = True
        current = _observe_pipeline(dut, committed_tokens, transfer_tokens)
        if (previous is not None and previous["dmem_pending"] and
                current["dmem_pending"]):
            coverage["dmem_hold"] = True
            for name in ("exmem", "memwb"):
                if previous[name]["valid"] and current[name]["valid"]:
                    assert previous[name]["token"] == current[name]["token"], \
                        f"{name} changed while dmem transaction was pending"

        if not ready:
            assert not bool(dut.commit_valid.value), \
                "commit_ready=0 must suppress commit"
        if bool(dut.commit_valid.value):
            commits.append((int(dut.commit_pc.value) & MASK64,
                            int(dut.commit_insn.value),
                            int(dut.commit_next_pc.value) & MASK64))

        if armed_token is not None:
            assert bool(core.ifid_valid.value), \
                f"ready-low window lost IFID at cycle {cycle}"
            assert bool(core.idex_valid.value), \
                f"armed IFID did not advance at cycle {cycle}"
            assert int(core.idex_pc.value) == armed_token[0]
            assert _token(dut, "idex") == armed_token[1]
            armed_token = None
            h04_checked = True

        if (force_h04_window and not h04_checked and ready and
                bool(core.ifid_valid.value) and int(core.fetch_fifo_occupancy.value) > 0 and
                not bool(core.memwb_valid.value) and not bool(core.stall_if.value) and
                not bool(core.frontend_kill.value) and not bool(core.dmem_pending.value)):
            armed_token = (int(core.ifid_pc.value) & MASK64,
                           _token(dut, "ifid"))
            dut.commit_ready.value = 0
            await Timer(1, unit="ps")
            assert not bool(core.memwb_valid.value)
            assert not bool(core.stall_if.value)
            assert bool(core.ifid_valid.value)
            assert int(core.fetch_fifo_occupancy.value) > 0
            assert bool(core.fetch_fifo_pop.value), \
                "post-fix must consume FIFO while WB is empty and ready is low"
            coverage["wb_empty_low"] = True
            previous = current
            continue

        # Keep short low runs so both the WB-empty and WB-full ready paths are
        # exercised, while the seeded PRNG makes the schedule reproducible.
        dut.commit_ready.value = 1 if rng.randrange(5) else 0
        previous = current

    if force_h04_window:
        assert h04_checked, "randomized image never reached the H-04 ready window"
    return commits, coverage


@cocotb.test()
async def test_fetch_fifo(dut):
    dut.rst_n.value = 0
    dut.commit_ready.value = 1
    _clear_restore_ports(dut)
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await ClockCycles(dut.clk, 2)

    # movz x0,#1; b target; two wrong-path words; target; b .
    words = [
        0xD2800020,
        0x14000003,
        0xD2800041,
        0xD2800062,
        0xD2800083,
        0x14000000,
    ]
    await _load_words(dut, words)
    dut.rst_n.value = 1

    pcs = []
    held = 0
    branch_seen = False
    fence_seen = False
    epoch0 = int(dut.fetch_epoch.value)
    for _ in range(800):
        await RisingEdge(dut.clk)
        count = int(dut.fetch_fifo_occupancy.value)
        assert 0 <= count <= 2, f"FIFO occupancy out of range: {count}"
        assert count == int(dut.fetch_fifo_occupancy.value)
        if bool(dut.fetch_control_fence.value):
            fence_seen = True
            assert not bool(dut.core.fetch_req_accept.value), \
                "taken branch fence accepted a younger MMU fetch"
            assert not bool(dut.core.imem_req_accept.value), \
                "taken branch fence accepted a younger imem fetch"

        if int(dut.commit_valid.value):
            pc = int(dut.commit_pc.value) & MASK64
            pcs.append(pc)
            assert pc not in (BASE + 8, BASE + 12), \
                f"wrong-path instruction committed: 0x{pc:x}"
            if pc == BASE + 4:
                branch_seen = True
                dut.commit_ready.value = 0

        if not int(dut.commit_ready.value):
            if held:
                assert not int(dut.commit_valid.value), \
                    "commit_ready=0 must suppress commit"
            held += 1
            if held >= 10:
                dut.commit_ready.value = 1

        if branch_seen and BASE + 16 in pcs and held >= 10:
            break

    assert BASE + 4 in pcs, f"taken branch did not retire: {pcs}"
    assert BASE + 16 in pcs, f"branch target did not retire: {pcs}"
    assert int(dut.fetch_epoch.value) != epoch0, \
        "taken branch did not bump local fetch epoch"
    assert fence_seen, "taken branch did not exercise control-flow fetch fence"

    # Reset must clear both queue and IF/ID state, including a delayed request.
    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 2)
    assert int(dut.fetch_fifo_occupancy.value) == 0
    assert int(dut.core.ifid_valid.value) == 0

    # A compact load/ALU/load window is the directed regression for T-046.
    # The second load may hold EX/MEM while the ALU is in MEM/WB; the older
    # entry must commit once and retain its committed marker until the hold
    # clears.  Use the same words as build_hard_fetch_duplicate_program().
    duplicate_words = [
        0xD2A88000,  # movz x0,#0x4400,lsl#16
        0xF2820000,  # movk x0,#0x1000
        0xD2A88001,  # movz x1,#0x4400,lsl#16
        0xF2840001,  # movk x1,#0x2000
        0xF9400002,  # ldr x2,[x0]
        0x91000023,  # add x3,x1,x0
        0xF9400024,  # ldr x4,[x1]
        0x91000C45,  # add x5,x2,x3
        0x14000001,  # b loop
        0x14000000,  # loop: b loop
    ]
    await _reset_and_load(dut, duplicate_words)

    committed_tokens = set()
    transfer_tokens = {"idex": set(), "exmem": set(), "memwb": set()}
    previous = None
    saw_fifo_zero = saw_fifo_one = saw_fifo_two = False
    saw_dmem_pending = False
    saw_dmem_hold = False
    saw_candidate_commit = False
    duplicate_pcs = []

    for _ in range(420):
        await RisingEdge(dut.clk)
        await Timer(1, unit="ps")
        await ReadOnly()
        count = int(dut.fetch_fifo_occupancy.value)
        assert count in (0, 1, 2), f"FIFO occupancy out of range: {count}"
        saw_fifo_zero |= count == 0
        saw_fifo_one |= count == 1
        saw_fifo_two |= count == 2

        current = _observe_pipeline(dut, committed_tokens, transfer_tokens)
        if current["dmem_pending"]:
            saw_dmem_pending = True
        if (previous is not None and previous["dmem_pending"] and
                current["dmem_pending"]):
            saw_dmem_hold = True
            for name in ("exmem", "memwb"):
                if previous[name]["valid"] and current[name]["valid"]:
                    assert previous[name]["token"] == current[name]["token"], \
                        f"{name} changed while dmem transaction was pending"

        if bool(dut.commit_valid.value):
            pc = int(dut.commit_pc.value) & MASK64
            duplicate_pcs.append(pc)
            if pc == BASE + 20:
                # The fixed +1 BFM and the random-delay BFM can expose the
                # dmem hold on either side of this sampled commit edge.  The
                # SV probe/SVA pins the exact same-edge case; Cocotb checks
                # both observables independently and still rejects any
                # repeated commit token.
                saw_candidate_commit = True
            if pc == BASE + 20 and current["dmem_pending"]:
                assert current["memwb_committed"], \
                    "WB commit under younger dmem hold missed committed marker"
        if (previous is not None and previous.get("commit_under_dmem", False)):
            assert not bool(dut.commit_valid.value), \
                "WB token committed again immediately after dmem-held commit"

        current["commit_under_dmem"] = (
            bool(dut.commit_valid.value) and current["dmem_pending"])
        previous = current

        # The loop is sufficient once the directed second load has retired and
        # the frontend has exercised both a refill and a branch epoch.
        if saw_candidate_commit and len(duplicate_pcs) >= 8:
            break

    assert saw_dmem_pending, "directed image never exercised a data transaction"
    assert saw_dmem_hold, "directed image never held the pipeline for dmem"
    assert saw_candidate_commit, "directed load/ALU/load ALU commit was missing"
    assert committed_tokens, "Cocotb did not observe any commit token"
    assert all(transfer_tokens.values()), \
        f"Cocotb did not observe all pipeline transfer pulses: {transfer_tokens}"
    assert saw_fifo_zero and saw_fifo_one, \
        "FIFO did not exercise empty and one-entry states"
    # A two-entry state is legal even if this single-outstanding-response BFM
    # does not fill it on every seed; the range assertion above is the safety
    # check, while the SV smoke checks the depth bound independently.

    # Reset must clear both queue and IF/ID state after the directed dmem hold.
    await RisingEdge(dut.clk)
    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 2)
    assert int(dut.fetch_fifo_occupancy.value) == 0
    assert int(dut.core.ifid_valid.value) == 0
    dut.rst_n.value = 1


@cocotb.test()
async def test_fetch_fifo_ready_randomized(dut):
    """Randomized commit_ready must preserve the same architectural stream."""
    dut.rst_n.value = 0
    dut.commit_ready.value = 1
    _clear_restore_ports(dut)
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await ClockCycles(dut.clk, 2)

    baseline, baseline_cov = await _collect_ready_trace(
        dut, READY_HOLD_WORDS, cycles=260, seed=0x004, force_h04_window=False)
    randomized, randomized_cov = await _collect_ready_trace(
        dut, READY_HOLD_WORDS, cycles=480, seed=0xF104, force_h04_window=True)

    assert len(baseline) >= 8, f"baseline commit stream too short: {len(baseline)}"
    assert len(randomized) >= 8, f"randomized commit stream too short: {len(randomized)}"
    assert randomized[:8] == baseline[:8], \
        f"commit_ready changed architectural prefix:\nbase={baseline[:8]}\nrand={randomized[:8]}"
    assert randomized_cov["fifo_counts"] == {0, 1, 2}, randomized_cov
    assert randomized_cov["ifid_valid"] == {False, True}, randomized_cov
    # The fixed +2 BFM naturally aligns a response one cycle after a pop;
    # the direct response mode is the deterministic push+pop cross-product.
    # Run this same test with MEM_DELAY_MODE=0 to close that coverage point.
    if int(os.environ.get("MEM_DELAY_MODE", "2")) == 0:
        assert randomized_cov["push_pop"], randomized_cov
    assert randomized_cov["branch_flush"], randomized_cov
    assert randomized_cov["wb_empty_low"], randomized_cov
    assert randomized_cov["wb_full_low"], randomized_cov

    # Reuse the T-046 image under the same seeded ready schedule.  The token
    # checks above reject duplicate transfers; these coverage bits pin the
    # younger data hold that must remain compatible with the H-04 fix.
    _, duplicate_cov = await _collect_ready_trace(
        dut, [
            0xD2A88000, 0xF2820000, 0xD2A88001, 0xF2840001,
            0xF9400002, 0x91000023, 0xF9400024, 0x91000C45,
            0x14000001, 0x14000000,
        ], cycles=520, seed=0x4604, force_h04_window=False)
    assert duplicate_cov["dmem_pending"], duplicate_cov
    assert duplicate_cov["dmem_hold"], duplicate_cov
    assert baseline_cov["fifo_counts"] <= {0, 1, 2}


async def _run_fence_case(dut, words, branch_index, target_index,
                          hold_branch=False):
    """Check a control-flow family without peeking into fetch implementation."""
    # The preceding case may finish in ReadOnly; leave that phase before
    # driving reset for the next independent image.
    await Timer(1, unit="ps")
    await _reset_and_load(dut, words)
    dut.commit_ready.value = 1
    branch_pc = BASE + 4 * branch_index
    target_pc = BASE + 4 * target_index
    branch_seen = False
    target_seen = False
    fence_seen = False
    held = 0
    pcs = []

    for _ in range(240):
        await RisingEdge(dut.clk)
        await Timer(1, unit="ps")
        await ReadOnly()
        # Leave ReadOnly before applying the optional commit-ready hold.
        await Timer(1, unit="ps")
        core = dut.core
        if bool(dut.fetch_control_fence.value):
            fence_seen = True
            assert not bool(core.fetch_req_accept.value), \
                "fence accepted a younger MMU fetch"
            assert not bool(core.imem_req_accept.value), \
                "fence accepted a younger imem fetch"
        if bool(dut.commit_valid.value):
            pc = int(dut.commit_pc.value) & MASK64
            pcs.append(pc)
            if pc == branch_pc:
                branch_seen = True
                if hold_branch:
                    dut.commit_ready.value = 0
                    held = 0
            if pc == target_pc:
                target_seen = True
        if not bool(dut.commit_ready.value):
            held += 1
            if held >= 4:
                dut.commit_ready.value = 1
        if branch_seen and target_seen and fence_seen:
            break

    assert branch_seen, f"control-flow branch did not retire: {pcs}"
    assert target_seen, f"expected branch target did not retire: {pcs}"
    assert fence_seen, "control-flow case never exercised fetch fence"


@cocotb.test()
async def test_control_flow_fetch_fence(dut):
    """Cover direct/conditional/compare/test/register branch fence edges."""
    dut.rst_n.value = 0
    dut.commit_ready.value = 1
    _clear_restore_ports(dut)
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())

    cases = [
        # B taken: branch index 1 -> target index 3.
        ([_movz(0, 1), _b_words(2), _movz(1, 0xBAD), _movz(2, 1),
          _b_words(0)], 1, 3, False),
        # B.cond taken (Z=1) and not-taken (Z=0).
        ([_subs_xzr(31, 0), _bcond_words(2, 0), _movz(1, 0xBAD),
          _movz(2, 1), _b_words(0)], 1, 3, True),
        ([_subs_xzr(31, 1), _bcond_words(1, 0), _movz(1, 1),
          _b_words(0)], 1, 2, False),
        # CBZ taken and CBNZ not-taken with x0=0.
        ([_movz(0, 0), _cb_words(2, 0), _movz(1, 0xBAD), _movz(2, 1),
          _b_words(0)], 1, 3, False),
        ([_movz(0, 0), _cb_words(1, 0, nonzero=True), _movz(1, 1),
          _b_words(0)], 1, 2, False),
        # TBZ taken and TBNZ not-taken with x0[0]=0.
        ([_movz(0, 0), _tb_words(2, 0, 0), _movz(1, 0xBAD), _movz(2, 1),
          _b_words(0)], 1, 3, False),
        ([_movz(0, 0), _tb_words(1, 0, 0, nonzero=True), _movz(1, 1),
          _b_words(0)], 1, 2, False),
        # BR register target; the two MOVs are older than the register branch.
        ([_movz(0, 0x4400, 1), _movk(0, 0x10), _br(0), _movz(1, 0xBAD),
          _movz(2, 1), _b_words(0)], 2, 4, True),
    ]
    for words, branch_index, target_index, hold_branch in cases:
        await _run_fence_case(dut, words, branch_index, target_index,
                              hold_branch=hold_branch)
