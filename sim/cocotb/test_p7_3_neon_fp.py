"""P7-3 Advanced SIMD FP pipeline tests。

所有输入/期望均为 AArch64 raw bits；测试不使用 host float、epsilon 或
宽松 NaN 比较。协议本任务只选 2S/4S/2D FADD/FSUB/FMUL/FCMEQ。
"""

import struct
import sys
from pathlib import Path

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ReadOnly, RisingEdge, Timer


_DIFFTEST = Path(__file__).resolve().parents[1] / "difftest"
sys.path.insert(0, str(_DIFFTEST))

from test_program import build_p5a_mmu_program  # noqa: E402


BASE = 0x44000000
MASK64 = (1 << 64) - 1
MASK128 = (1 << 128) - 1


def movz(rd, imm16, hw=0):
    return 0xD2800000 | (hw << 21) | (imm16 << 5) | rd


def neon_fp(base, rd, rn, rm, quad, double):
    return (base | ((1 if quad else 0) << 30) |
            ((1 if double else 0) << 22) |
            ((rm & 31) << 16) | ((rn & 31) << 5) | (rd & 31))


def _clear_restore(dut):
    ports = (
        "difftest_restore_sys_valid", "difftest_restore_fp_valid",
        "difftest_restore_fpcr", "difftest_restore_fpsr",
        "difftest_restore_pc", "difftest_restore_sp_el0",
        "difftest_restore_sp_el1", "difftest_restore_nzcv",
        "difftest_restore_el", "difftest_restore_sp_sel",
        "difftest_restore_daif", "difftest_restore_pan",
        "difftest_restore_dit", "difftest_restore_ssbs",
        "difftest_restore_uao", "difftest_restore_tco",
        "difftest_restore_allint", "difftest_restore_elr_el1",
        "difftest_restore_spsr_el1", "difftest_restore_vbar_el1",
        "difftest_restore_sctlr_el1", "difftest_restore_tcr_el1",
        "difftest_restore_ttbr0_el1", "difftest_restore_ttbr1_el1",
        "difftest_restore_mair_el1", "difftest_restore_esr_el1",
        "difftest_restore_far_el1", "difftest_restore_par_el1",
        "difftest_restore_cpacr_el1", "difftest_restore_mdscr_el1",
        "difftest_restore_pmuserenr_el0", "difftest_restore_cntkctl_el1",
        "difftest_restore_tpidr_el0", "difftest_restore_tpidrro_el0",
        "difftest_restore_tpidr_el1", "difftest_restore_pir_el1",
        "difftest_restore_pire0_el1", "difftest_restore_zcr_el1",
        "difftest_restore_smcr_el1", "difftest_restore_csselr_el1",
        "difftest_restore_tcr2_el1", "difftest_restore_contextidr_el1", "difftest_restore_excl_valid",
        "difftest_restore_excl_addr", "difftest_restore_excl_data",
        "difftest_restore_excl_data_hi", "difftest_restore_cntpct",
        "difftest_restore_cntp_cval", "difftest_restore_cntp_ctl",
        "difftest_restore_cntv_cval", "difftest_restore_cntv_ctl",
    )
    for name in ports:
        getattr(dut, name).value = 0
    for name in ("difftest_restore_fp_v_lo", "difftest_restore_fp_v_hi"):
        vec = getattr(dut, name)
        for i in range(32):
            vec[i].value = 0


async def _load_words(dut, words):
    await Timer(1, unit="ns")
    dut.rst_n.value = 0
    dut.commit_ready.value = 1
    dut.prog_we.value = 0
    _clear_restore(dut)
    await Timer(1, unit="ns")
    for i, word in enumerate(words):
        dut.prog_we.value = 1
        dut.prog_addr.value = BASE + 4 * i
        dut.prog_strb.value = 0x0F
        dut.prog_wdata.value = word
        await RisingEdge(dut.clk)
    dut.prog_we.value = 0


async def _load_image(dut, image, extra_writes=()):
    """Load a byte image and optional physical data words through the SRAM port.

    The P5a page tables are deliberately loaded as the complete image, rather
    than only writing the instruction prefix.  This keeps the MMU walk in this
    regression identical to the existing P5a directed programs.
    """
    await Timer(1, unit="ns")
    dut.rst_n.value = 0
    dut.commit_ready.value = 1
    dut.prog_we.value = 0
    _clear_restore(dut)
    await Timer(1, unit="ns")
    assert len(image) % 4 == 0
    for offset in range(0, len(image), 4):
        dut.prog_we.value = 1
        dut.prog_addr.value = BASE + offset
        dut.prog_strb.value = 0x0F
        dut.prog_wdata.value = int.from_bytes(image[offset:offset + 4],
                                              "little")
        await RisingEdge(dut.clk)
    for address, value in extra_writes:
        dut.prog_we.value = 1
        dut.prog_addr.value = address
        dut.prog_strb.value = 0xFF
        dut.prog_wdata.value = value
        await RisingEdge(dut.clk)
    dut.prog_we.value = 0


async def _restore_mmu_fp(dut, vectors):
    """Restore EL1h with the existing P5a 4KiB tables and FP enabled."""
    _clear_restore(dut)
    dut.difftest_restore_pc.value = BASE
    dut.difftest_restore_nzcv.value = 4
    dut.difftest_restore_el.value = 1
    dut.difftest_restore_sp_sel.value = 1
    dut.difftest_restore_daif.value = 0xF
    dut.difftest_restore_sctlr_el1.value = 0x0000000000C50839
    dut.difftest_restore_cpacr_el1.value = 0x00300000
    dut.difftest_restore_fpcr.value = 0
    dut.difftest_restore_fpsr.value = 0
    dut.difftest_restore_ttbr0_el1.value = 0x0000000044010000
    dut.difftest_restore_tcr_el1.value = 0x0000000000100010
    dut.difftest_restore_mair_el1.value = 0xFF
    dut.difftest_restore_cntpct.value = 1
    for index, value in vectors.items():
        dut.difftest_restore_fp_v_lo[index].value = value & MASK64
        dut.difftest_restore_fp_v_hi[index].value = (value >> 64) & MASK64
    dut.difftest_restore_sys_valid.value = 1
    dut.difftest_restore_fp_valid.value = 1
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)
    await ReadOnly()
    await Timer(1, unit="ns")
    dut.difftest_restore_sys_valid.value = 0
    dut.difftest_restore_fp_valid.value = 0


async def _restore(dut, vectors=None, fpcr=0, fpsr=0, cpacr=0x00300000):
    vectors = vectors or {}
    _clear_restore(dut)
    dut.difftest_restore_pc.value = BASE
    dut.difftest_restore_nzcv.value = 4
    dut.difftest_restore_el.value = 1
    dut.difftest_restore_sp_sel.value = 1
    dut.difftest_restore_daif.value = 0xF
    dut.difftest_restore_sctlr_el1.value = 0x0000000000C50838
    dut.difftest_restore_cpacr_el1.value = cpacr
    dut.difftest_restore_fpcr.value = fpcr
    dut.difftest_restore_fpsr.value = fpsr
    dut.difftest_restore_cntpct.value = 1
    for index, value in vectors.items():
        dut.difftest_restore_fp_v_lo[index].value = value & MASK64
        dut.difftest_restore_fp_v_hi[index].value = (value >> 64) & MASK64
    dut.difftest_restore_sys_valid.value = 1
    dut.difftest_restore_fp_valid.value = 1
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)
    await ReadOnly()
    await Timer(1, unit="ns")
    dut.difftest_restore_sys_valid.value = 0
    dut.difftest_restore_fp_valid.value = 0


def _packet(dut):
    count = int(dut.commit_vec_write_count.value)
    vectors = []
    for i in range(count):
        lo = int(getattr(dut, f"commit_vec_wdata{i}_lo").value)
        hi = int(getattr(dut, f"commit_vec_wdata{i}_hi").value)
        vectors.append((int(getattr(dut, f"commit_vec_rd{i}").value),
                        (hi << 64) | lo))
    return {
        "pc": int(dut.commit_pc.value),
        "insn": int(dut.commit_insn.value),
        "vec": vectors,
        "fpsr_we": bool(dut.commit_fpsr_we.value),
        "fpsr_wdata": int(dut.commit_fpsr_wdata.value),
        "exc_valid": bool(dut.commit_exc_valid.value),
        "exc_code": int(dut.commit_exc_code.value),
        "exc_esr": int(dut.commit_exc_esr.value),
    }


async def _collect(dut, limit=800):
    packets = []
    for _ in range(limit):
        await RisingEdge(dut.clk)
        await ReadOnly()
        if bool(dut.commit_valid.value):
            packets.append(_packet(dut))
    return packets


def _vector_packet(packets, rd):
    for packet in packets:
        for got_rd, value in packet["vec"]:
            if got_rd == rd:
                return packet, value
    raise AssertionError(f"没有观察到 V{rd} 写回")


def _fp_exec(dut):
    """Return the core-local FP transaction wrapper for control probes."""
    try:
        return dut.core.g_fp_simd_enabled.fp_exec
    except AttributeError as exc:
        raise AssertionError("Verilator handle for core FP transaction wrapper is missing") from exc


@cocotb.test()
async def test_p7_3_neon_fp_pipeline(dut):
    """2S/4S/2D arithmetic, FCMEQ, forwarding and sticky IOC。"""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    words = [
        neon_fp(0x0E20D400, 2, 0, 1, False, False),  # FADD V2.2S
        neon_fp(0x0EA0D400, 3, 0, 1, True, False),   # FSUB V3.4S
        neon_fp(0x2E20DC00, 6, 4, 5, True, True),    # FMUL V6.2D
        neon_fp(0x0E20E400, 7, 8, 9, True, False),   # FCMEQ V7.4S
        neon_fp(0x0E20D400, 10, 2, 2, True, False),  # forwarding from V2
        0x14000000,
    ]
    vectors = {
        0: 0x412000004100000040C0000040800000,
        1: 0x4080000040400000400000003F800000,
        4: 0xC0000000000000003FF8000000000000,
        5: 0x40100000000000004000000000000000,
        8: 0x7FA012347FC01234800000003F800000,
        9: 0x3F8000007FC01234000000003F800000,
    }
    await _load_words(dut, words)
    await _restore(dut, vectors=vectors)
    packets = await _collect(dut)

    expected = {
        2: 0x00000000000000004100000040A00000,
        3: 0x40C0000040A000004080000040400000,
        6: 0xC0200000000000004008000000000000,
        7: 0x0000000000000000FFFFFFFFFFFFFFFF,
        10: 0x00000000000000004180000041200000,
    }
    for rd, want in expected.items():
        _, got = _vector_packet(packets, rd)
        assert got == want, f"V{rd}: got {got:032x}, want {want:032x}"
    compare = next(p for p in packets if any(rd == 7 for rd, _ in p["vec"]))
    assert compare["fpsr_we"] and compare["fpsr_wdata"] & 1
    assert int(dut.fp_v_lo[10].value) == expected[10] & MASK64
    assert int(dut.fp_v_hi[10].value) == expected[10] >> 64


@cocotb.test()
async def test_p7_3_fpen_trap_no_effect(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await _load_words(dut, [neon_fp(0x0E20D400, 0, 0, 0, True, False),
                            0x14000000])
    await _restore(dut, vectors={0: 0x3F800000}, cpacr=0)
    packets = await _collect(dut, 500)
    first = next(p for p in packets if p["pc"] == BASE)
    assert first["exc_valid"] and first["exc_code"] == 0x07
    assert first["exc_esr"] == 0x1FE00000
    assert not first["vec"]
    # Restore supplied the pre-state 1.0; the trapped instruction must leave
    # that raw V state untouched.
    assert int(dut.fp_v_lo[0].value) == 0x3F800000
    assert int(dut.fp_v_hi[0].value) == 0


@cocotb.test()
async def test_p7_3_backpressure_and_fpcr_raw(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    # DN=1, so qNaN + 1.0 is deterministic default NaN in every active lane.
    words = [neon_fp(0x0E20D400, 2, 0, 1, True, False), 0x14000000]
    vectors = {
        0: 0x7FC012347FC012347FC012347FC01234,
        1: 0x3F8000003F8000003F8000003F800000,
    }
    await _load_words(dut, words)
    await _restore(dut, vectors=vectors, fpcr=0x02000000)
    dut.commit_ready.value = 0
    for _ in range(80):
        await RisingEdge(dut.clk)
        await ReadOnly()
    assert int(dut.fp_v_lo[2].value) == 0
    assert int(dut.fp_v_hi[2].value) == 0
    assert int(dut.fpsr_state.value) == 0
    await Timer(1, unit="ns")
    dut.commit_ready.value = 1
    packets = await _collect(dut, 400)
    _, got = _vector_packet(packets, 2)
    assert got == 0x7FC000007FC000007FC000007FC00000
    assert int(dut.fpsr_state.value) == 0
    # The final B . is a legal stream of distinct dynamic instructions with
    # the same architectural PC.  Under the released backpressure it must be
    # able to occupy/retire repeatedly without being mistaken for a duplicated
    # pipeline token merely because adjacent instances share their PC.
    loop_packets = [packet for packet in packets if packet["pc"] == BASE + 4]
    assert len(loop_packets) >= 2
    assert all(not packet["vec"] and not packet["exc_valid"]
               for packet in loop_packets)


@cocotb.test()
async def test_p7_3_fp_response_held_during_data_mmu_walk(dut):
    """An older FP response must survive a younger MMU data translation.

    This is intentionally a white-box handshake regression.  The older FP
    response is expected to become valid while the younger LDR has started a
    P5a page-table walk.  The response and its ID/EX token must remain stable
    until the data-side hold clears, then be consumed exactly once into
    EX/MEM and the architectural commit stream.
    """
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())

    # Reuse the canonical P5a image so all four levels of the page-table walk
    # are exercised.  Replace only its code prefix with the overlap sequence.
    repo_root = Path(__file__).resolve().parents[2]
    image_dir = repo_root / "build" / "agents" / "T-20260905-012" / "images"
    image_dir.mkdir(parents=True, exist_ok=True)
    image_path = image_dir / "fp_rsp_data_mmu_overlap.bin"
    build_p5a_mmu_program(image_path)
    image = bytearray(image_path.read_bytes())
    words = [
        movz(0, 0x4000, 1),                         # X0 = data VA 0x40000000
        movz(4, 1),                                 # older scalar
        0x9B047C85,                                 # older MUL X5,X4,X4
        # The older MUL keeps the following window full while the fetch FIFO
        # accumulates FMOV/LDR.  On the release edge FMOV enters ID/EX while
        # LDR is already in IF/ID.
        0x1E202802,                                 # older FADD S2,S0,S1
        0xF9400003,                                 # younger LDR X3,[X0]
        0x14000000,                                  # B .
    ]
    for index, word in enumerate(words):
        struct.pack_into("<I", image, index * 4, word)

    data_value = 0x1122334455667788
    await _load_image(dut, image, [(0x44080000, data_value)])
    vectors = {
        0: 0x3F8000003F8000003F8000003F800000,
        1: 0x3F8000003F8000003F8000003F800000,
    }
    await _restore_mmu_fp(dut, vectors)
    # The older MUL is only a fetch-window fence; architectural commit stays
    # ready so this regression isolates the data-translation hold.
    dut.commit_ready.value = 1

    core = dut.core
    held_payload = None
    held_token = None
    blocked_observations = 0
    data_issue_observations = 0
    consume_count = 0
    released = False
    exmem_captures = {}
    fp_commits = []
    load_commits = []

    # The longest P5a walk is short, but leave enough budget for the FP
    # wrapper, the load response, and a few self-loop retirements.
    for _ in range(1600):
        await RisingEdge(dut.clk)
        await ReadOnly()

        rsp_valid = bool(core.fp_rsp_valid.value)
        rsp_blocked = bool(core.fp_rsp_accept_blocked.value)
        rsp_ready = bool(core.fp_rsp_ready.value)
        fp_consume = bool(core.fp_consume.value)
        data_active = bool(core.data_trans_active.value)
        data_issue = bool(core.data_mmu_issue.value)
        second_needed = bool(core.atomic128_second_needed.value)

        # The new gating term is itself an invariant, and this test checks it
        # at every cycle rather than only at the observed overlap.
        if rsp_blocked:
            assert not rsp_ready, "data-side hold allowed FP response ready"
        if rsp_valid and (data_active or data_issue or second_needed):
            blocked_observations += 1
            assert rsp_blocked, "FP response overlapped an unblocked data hold"
            assert not rsp_ready and not fp_consume, (
                "FP response was consumed during data translation"
            )
            payload = int(core.fp_rsp.value)
            token = (int(core.idex_token_epoch.value),
                     int(core.idex_token_seq.value))
            if held_payload is None:
                held_payload = payload
                held_token = token
            else:
                assert payload == held_payload, (
                    "FP response payload changed while data translation held"
                )
                assert token == held_token, (
                    "FP ID/EX token changed while response was held"
                )
        if data_issue:
            data_issue_observations += 1

        if rsp_valid and rsp_ready and fp_consume:
            consume_count += 1

        if (blocked_observations and not data_active and not data_issue and
                not second_needed and not released):
            released = True
        if released and rsp_valid and rsp_ready and fp_consume:
            assert consume_count == 1, "FP response consumed more than once"

        if (bool(core.exmem_valid.value) and
                bool(core.exmem_fp_valid.value)):
            token = (int(core.exmem_token_epoch.value),
                     int(core.exmem_token_seq.value))
            if token not in exmem_captures:
                exmem_captures[token] = {
                    "rd": int(core.exmem_fp_rd.value),
                    "wdata": int(core.exmem_fp_wdata.value),
                }

        if bool(dut.commit_valid.value):
            packet = _packet(dut)
            if packet["pc"] == BASE + 12:
                fp_commits.append(packet)
            elif packet["pc"] == BASE + 16:
                load_commits.append({
                    "rd": int(dut.commit_gpr_rd.value),
                    "we": bool(dut.commit_gpr_we.value),
                    "wdata": int(dut.commit_gpr_wdata.value) & MASK64,
                    "exc": bool(dut.commit_exc_valid.value),
                })

        # Once both architectural effects have been observed, a few extra
        # cycles below still catch a duplicate vector commit or re-capture.
        if (released and consume_count == 1 and len(fp_commits) >= 1 and
                len(load_commits) >= 1):
            if _ >= 80:
                break

    assert data_issue_observations >= 1, "younger LDR never issued an MMU walk"
    assert blocked_observations >= 2, (
        "FP response/data-MMU overlap was not held for multiple cycles"
    )
    assert released, "data-MMU hold never reached an accepting boundary"
    assert consume_count == 1, f"FP response consume count={consume_count}"
    assert len(exmem_captures) == 1, (
        f"FP EX/MEM capture count={len(exmem_captures)}"
    )
    capture = next(iter(exmem_captures.values()))
    assert capture["rd"] == 2
    assert capture["wdata"] == 0x00000000000000000000000040000000
    assert len(fp_commits) == 1, f"FP commit count={len(fp_commits)}"
    assert fp_commits[0]["vec"] == [
        (2, 0x00000000000000000000000040000000)
    ]
    assert len(load_commits) == 1, f"younger MMU LDR commit count={len(load_commits)}"
    assert load_commits[0] == {
        "rd": 3,
        "we": True,
        "wdata": data_value,
        "exc": False,
    }
    dut._log.info(
        "PASS: T-012 FP response/data-MMU hold; blocked_cycles=%d "
        "data_issues=%d consume=%d exmem_captures=%d fp_commits=%d "
        "load_commits=%d",
        blocked_observations, data_issue_observations, consume_count,
        len(exmem_captures), len(fp_commits), len(load_commits))


@cocotb.test()
async def test_p7_3_consecutive_fmla_after_accumulator_cut(dut):
    """验证 accumulator 切点后连续 FMLA/FADD 的架构结果与 V RAW。"""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    # FMLA uses Vd as operand_c: 1.0 + 2.0 * 3.0 = 7.0.  The following
    # FADD consumes that result, making the consecutive-request check also
    # cover the architectural V dependency and the captured FMA addend.
    words = [
        movz(10, 1),  # older instruction held in MEM/WB under backpressure
        movz(11, 2),  # second older instruction occupies EX/MEM as well
        neon_fp(0x0E20CC00, 2, 0, 1, False, False),  # FMLA V2.2S
        neon_fp(0x0E20D400, 3, 2, 2, False, False),  # FADD V3.2S
        0x14000000,
    ]
    vectors = {
        0: 0x4000000040000000,
        1: 0x4040000040400000,
        2: 0x3F8000003F800000,
    }
    expected_v2 = 0x40E0000040E00000
    expected_v3 = 0x4160000041600000
    await _load_words(dut, words)
    await _restore(dut, vectors=vectors)

    dut.commit_ready.value = 1
    packets = await _collect(dut, 1200)
    _, got_v2 = _vector_packet(packets, 2)
    _, got_v3 = _vector_packet(packets, 3)
    assert got_v2 == expected_v2, f"FMLA operand_c mismatch: got {got_v2:032x}"
    assert got_v3 == expected_v3, f"consecutive FADD mismatch: got {got_v3:032x}"


@cocotb.test()
async def test_p7_3_unsupported_udef(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    # FCMGE and scalar-looking D.2 are deliberately outside the frozen matrix.
    cases = [
        neon_fp(0x2E20E400, 0, 0, 1, True, False),  # FCMGE V0.4S
        neon_fp(0x0E20D400, 0, 0, 1, False, True),   # invalid D.2 shape
    ]
    for insn in cases:
        await _load_words(dut, [insn, 0x14000000])
        await _restore(dut)
        packets = await _collect(dut, 500)
        first = next(p for p in packets if p["pc"] == BASE)
        assert first["exc_valid"] and first["exc_code"] == 0, f"{insn:08x}"
        assert not first["vec"]
