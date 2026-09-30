#!/usr/bin/env python3
"""T-055 scalar COMMIT monitor-sidecar protocol fixture。

该 fixture 不启动 QEMU，也不伪造参考结果；它只用冻结的 wire ABI 构造并
解析四类最小 COMMIT，确保同一提交中的 IRQ、同步 DABT、STXR success/fail
和 WFI ASYNC 所需 monitor 字段不会在协议封装/解封装时丢失。真实 QEMU
行为由 ``run_p6_stxr_irq_mon_we.sh`` 覆盖。
"""

from __future__ import annotations

import struct
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO))
sys.path.insert(0, str(REPO / "sim" / "difftest"))
from a64 import Insn, assemble  # noqa: E402
from qemu.plugins.lcvex_protocol import (  # noqa: E402
    LCVEX_COMMIT,
    LCVEX_MSG_ASYNC,
    LCVEX_MSG_COMMIT,
    LCVEX_MSG_MAGIC,
    LCVEX_MSG_VERSION,
    MSG_HEADER,
    decode_message,
    encode_message,
    parse_commit,
)


BASE = 0x44000000
STXR_SUCCESS = 0x88077E86
STXR_FAIL = 0x88077E86


def build_stxr_sync_abort_image(path: str | Path) -> int:
    """Build the T-055 DABT image without extending ``test_program.py``.

    This helper deliberately lives in an IRQ-named, task-authorized fixture:
    it establishes a valid LDXR monitor on an EL1 read-only page, then executes
    STXR to the same address so both QEMU and RTL report an unretired
    permission DABT with ``mon_we=0``.
    """
    main = assemble([
        Insn("label", "main"),
        Insn("movz", 8, 0x4401, 1),
        Insn("msr_sys", "vbar_el1", 8),
        Insn("movz", 5, 0x4401, 1),
        Insn("msr_sys", "ttbr0_el1", 5),
        Insn("movz", 5, 0x100010),
        Insn("msr_sys", "tcr_el1", 5),
        Insn("movz", 5, 0xff),
        Insn("msr_sys", "mair_el1", 5),
        Insn("movz", 5, 0xc5, 1),
        Insn("movk", 5, 0x839),
        Insn("msr_sys", "sctlr_el1", 5),
        Insn("movz", 20, 0x4000, 1),
        Insn("movk", 20, 0x1000),
        Insn("ldxr", 5, 20),
        Insn("movz", 20, 0x4000, 1),
        Insn("movk", 20, 0x1000),
        Insn("movz", 6, 0xaa),
        Insn("stxr_w", 7, 6, 20),
        Insn("movz", 0, 0x55),
        Insn("b", "loop"),
        Insn("label", "loop"),
        Insn("b", "loop"),
    ], BASE)
    handler = assemble([
        Insn("mrs_sys", 9, "esr_el1"),
        Insn("mrs_sys", 10, "far_el1"),
        Insn("mrs_sys", 11, "elr_el1"),
        Insn("add", 11, 11, 4),
        Insn("msr_sys", "elr_el1", 11),
        Insn("eret"),
    ], 0x44010200)
    image = bytearray(0x82000)
    for index, word in enumerate(main):
        image[index * 4:index * 4 + 4] = struct.pack("<I", word)
    for index, word in enumerate(handler):
        offset = 0x10200 + index * 4
        image[offset:offset + 4] = struct.pack("<I", word)

    def put64(offset: int, value: int) -> None:
        image[offset:offset + 8] = struct.pack("<Q", value)

    put64(0x10000 + 0 * 8, 0x44011003)
    put64(0x11000 + 1 * 8, 0x44012003)
    put64(0x12000 + 0 * 8, 0x44013003)
    put64(0x12000 + 32 * 8, 0x44015003)
    put64(0x13000 + 0x01 * 8, 0x440814C3)
    put64(0x15000 + 0x00 * 8, 0x440004C3)
    put64(0x15000 + 0x10 * 8, 0x440104C3)
    put64(0x81000, 0x11)
    Path(path).write_bytes(image)
    return BASE


def commit_payload(*, pc: int, insn: int, next_pc: int, exc_code: int,
                   mon_we: int, gpr_wdata: int, store_count: int) -> bytes:
    """Construct one scalar COMMIT without hiding any monitor fields."""

    payload = bytearray(LCVEX_COMMIT.size)
    struct.pack_into("<QQI", payload, 0, pc, next_pc, insn)
    # x0..x30, SP, NZCV are all zero except the STXR result x7.
    struct.pack_into("<Q", payload, 20 + 7 * 8, gpr_wdata)
    struct.pack_into("<QI", payload, 268, 0, 0)
    # gpr_we, gpr_rd, sp_we, nzcv_we
    struct.pack_into("<BBBB", payload, 280, 1, 7, 0, 0)
    struct.pack_into("<QQI", payload, 284, gpr_wdata, 0, 0)
    struct.pack_into("<B", payload, 304, 1)
    struct.pack_into("<I", payload, 312, exc_code)
    # exc_far/exc_esr/pad2 stay zero.
    struct.pack_into("<BB", payload, 332, mon_we, 0)
    # STXR clears the monitor, so mon_valid/address/data/data2 remain zero.
    struct.pack_into("<I", payload, 364, store_count)
    if store_count:
        struct.pack_into("<QQB", payload, 368, 0x44083000, 0xAA, 0x0F)
    return bytes(payload)


def check_commit(datagram: bytes, *, msg_type: int, seq: int,
                 expected: dict[str, int]) -> None:
    decoded = decode_message(datagram, expected_type=msg_type,
                             expected_seq=seq)
    commit = parse_commit(decoded["payload"])
    for key, value in expected.items():
        actual = commit["exc_code"] if key == "exc_code" else commit[key]
        assert actual == value, f"{key}: got {actual!r}, expected {value!r}"


def main() -> int:
    # Success and failure both retire STXR and therefore clear the monitor even
    # when the same COMMIT carries the ordinary IRQ code 0x40.
    success = commit_payload(pc=0x44000070, insn=STXR_SUCCESS,
                             next_pc=0x44010280,
                             exc_code=0x40, mon_we=1, gpr_wdata=0,
                             store_count=1)
    check_commit(encode_message(LCVEX_MSG_COMMIT, 28, success),
                 msg_type=LCVEX_MSG_COMMIT, seq=28,
                 expected={"exc_code": 0x40, "mon_we": 1,
                           "mon_valid": 0, "mon_data2": 0,
                           "store_count": 1})

    failure = commit_payload(pc=0x44000064, insn=STXR_FAIL,
                             next_pc=0x44010200,
                             exc_code=0x40, mon_we=1, gpr_wdata=1,
                             store_count=0)
    check_commit(encode_message(LCVEX_MSG_COMMIT, 25, failure),
                 msg_type=LCVEX_MSG_COMMIT, seq=25,
                 expected={"exc_code": 0x40, "mon_we": 1,
                           "mon_valid": 0, "mon_data2": 0,
                           "store_count": 0})

    # A synchronous DABT means STXR did not retire: no monitor write and no
    # store are allowed.  This is intentionally a normal COMMIT, not ASYNC.
    dabt = commit_payload(pc=0x44000064, insn=STXR_FAIL,
                          next_pc=0x44010200,
                          exc_code=0x25, mon_we=0, gpr_wdata=0,
                          store_count=0)
    check_commit(encode_message(LCVEX_MSG_COMMIT, 17, dabt),
                 msg_type=LCVEX_MSG_COMMIT, seq=17,
                 expected={"exc_code": 0x25, "mon_we": 0,
                           "mon_data2": 0, "store_count": 0})

    # WFI wake-up is a standalone ASYNC packet and carries no monitor effect.
    wfi = bytearray(dabt)
    struct.pack_into("<QQ", wfi, 0, 0x44000050, 0x44010280)
    struct.pack_into("<I", wfi, 312, 0x40)
    check_commit(encode_message(LCVEX_MSG_ASYNC, 9, bytes(wfi)),
                 msg_type=LCVEX_MSG_ASYNC, seq=9,
                 expected={"exc_code": 0x40, "mon_we": 0,
                           "mon_data2": 0, "store_count": 0})

    # Keep the imported fixed ABI visible to static checks and catch accidental
    # payload truncation before any QEMU run.
    assert LCVEX_COMMIT.size == 560
    assert len(success) == LCVEX_COMMIT.size
    assert MSG_HEADER.size == 24
    assert LCVEX_MSG_MAGIC == 0x5446444C and LCVEX_MSG_VERSION == 1
    print("PASS: T-055 COMMIT/ASYNC monitor sidecar protocol fixture")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (AssertionError, ValueError, struct.error) as exc:
        print(f"FAIL: {exc}", file=sys.stderr)
        raise SystemExit(1)
