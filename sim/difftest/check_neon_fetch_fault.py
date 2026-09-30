#!/usr/bin/env python3
"""Narrow semantic guard for the P7-2 NEON page-end fetch-fault image.

The ordinary step coordinator intentionally prints only the architectural
commit summary.  That is sufficient for strict state comparison, but it
does not make the two 8-byte halves of a Q store auditable.  This guard keeps
the existing strict run as the source of truth for EC/PC and supplements it
with the read-only QEMU trace format for the memory tuples.

The guard has three deliberately small checks:

* the image has the exact CPACR/ISB/NEON/branch/page-table layout;
* the strict runner committed 20 records and its QEMU side log reports the
  page-end instruction-abort as EC=0x21 (an EC=0x07 early trap is rejected);
* a required-profile QEMU trace contains exactly one page-end STR Q commit
  with both expected 8-byte memory records.

It never changes RTL, QEMU, or reference data.  ``--self-test`` exercises
both the valid shape and deliberately old/EC=0x07 inputs without launching
QEMU, Verilator, or any board tooling.
"""

from __future__ import annotations

import argparse
import gzip
import re
import struct
import subprocess
import tempfile
from pathlib import Path


BASE = 0x44000000
PAGE_END_PC = BASE + 0x0FFC
FAULT_PC = BASE + 0x1000
HANDLER_PC = BASE + 0x10200
Q_DATA0 = BASE + 0x2000
Q_DATA1 = BASE + 0x2008
MAX_INSNS = 20
REPO_ROOT = Path(__file__).resolve().parents[2]

# Encodings are kept literal on purpose: a changed test-program layout must
# make this guard fail loudly instead of silently widening its semantics.
CPACR_MOVZ = 0xD2A00605       # movz x5, #0x30, lsl #16 => FPEN=0b11
CPACR_MSR = 0xD5181045        # msr cpacr_el1, x5
ISB_SY = 0xD5033FDF
NEON_MOVI = 0x4F05E4A0        # movi v0.16b, #0xa5
SCTLR_MOVZ = 0xD2A018A5       # movz x5, #0xc5, lsl #16
SCTLR_MOVK = 0xF2810725       # movk x5, #0x839
SCTLR_MSR = 0xD5181005        # msr sctlr_el1, x5
Q_STORE = 0x3D800140          # str q0, [x10]
BRANCH_PAGE_END = 0x140003EE  # b 0x44000ffc from 0x44000044
DATA_PAGE_DESC = 0x44002403   # PA 0x44002000, AF=1, AP=00 (EL1 RW)
OLD_READONLY_DATA_PAGE_DESC = 0x440024C3  # AP=11 (EL1 RO; negative case)

INITIAL_Q_DATA = (0x1122334455667788, 0x99AABBCCDDEEFF00)
# MOVI V0.16B,#0xa5 fills both 64-bit halves.  These are the actual values
# written by the page-end STR Q; INITIAL_Q_DATA is the pre-store RAM pattern
# retained by the image contract.
Q_STORE_VALUES = (0xA5A5A5A5A5A5A5A5, 0xA5A5A5A5A5A5A5A5)


class GuardError(RuntimeError):
    """A semantic requirement was not proven."""


def _read_word(image: bytes, address: int) -> int:
    offset = address - BASE
    if offset < 0 or offset + 4 > len(image):
        raise GuardError(f"image 缺少地址 0x{address:x}")
    return struct.unpack_from("<I", image, offset)[0]


def _read_u64(image: bytes, offset: int) -> int:
    if offset < 0 or offset + 8 > len(image):
        raise GuardError(f"image 缺少页表/数据偏移 0x{offset:x}")
    return struct.unpack_from("<Q", image, offset)[0]


def _decode_b_target(word: int, pc: int) -> int | None:
    if word & 0xFC000000 != 0x14000000:
        return None
    immediate = word & 0x03FFFFFF
    if immediate & (1 << 25):
        immediate -= 1 << 26
    return pc + (immediate << 2)


def check_image(path: Path) -> bytes:
    """Validate the exact image contract and return its bytes."""

    image = path.read_bytes()
    errors: list[str] = []
    if len(image) != 0x16000:
        errors.append(
            f"image 大小为 0x{len(image):x}，期望固定 0x16000（保留原 image base/layout）"
        )

    expected_words = {
        BASE + 0x28: CPACR_MOVZ,
        BASE + 0x2C: CPACR_MSR,
        BASE + 0x30: ISB_SY,
        BASE + 0x34: NEON_MOVI,
        BASE + 0x38: SCTLR_MOVZ,
        BASE + 0x3C: SCTLR_MOVK,
        BASE + 0x40: SCTLR_MSR,
        BASE + 0x44: BRANCH_PAGE_END,
        PAGE_END_PC: Q_STORE,
    }
    for address, expected in expected_words.items():
        try:
            actual = _read_word(image, address)
        except GuardError as exc:
            errors.append(str(exc))
            continue
        if actual != expected:
            errors.append(
                f"image[0x{address:x}]=0x{actual:08x}，"
                f"期望 0x{expected:08x}"
            )

    # Decode the branch independently as an anti-regression check.  The
    # literal encoding above catches layout drift; this catches an incorrect
    # immediate that happens to retain the branch opcode.
    if not errors:
        target = _decode_b_target(_read_word(image, BASE + 0x44), BASE + 0x44)
        if target != PAGE_END_PC:
            errors.append(
                f"page-end branch target=0x{(target or 0):x}，"
                f"期望 0x{PAGE_END_PC:x}"
            )

    # Page-table contract: identity-map the code page and handler page, map
    # the Q destination as EL1-RW (AP=00), deliberately leave L3[1]
    # (VA 0x44001000) absent, and keep both Q data halves at their historical
    # addresses/values.
    table_words = {
        0x10000 + 0 * 8: 0x44011003,
        0x11000 + 1 * 8: 0x44012003,
        0x12000 + 32 * 8: 0x44014003,
        0x14000 + 0 * 8: 0x440004C3,
        0x14000 + 2 * 8: DATA_PAGE_DESC,
        0x14000 + 0x10 * 8: 0x440104C3,
    }
    for offset, expected in table_words.items():
        try:
            actual = _read_u64(image, offset)
        except GuardError as exc:
            errors.append(str(exc))
            continue
        if actual != expected:
            errors.append(
                f"页表[0x{offset:x}]=0x{actual:016x}，期望 0x{expected:016x}"
            )
    try:
        if _read_u64(image, 0x14000 + 1 * 8) != 0:
            errors.append("L3_id[1] 非 0，VA 0x44001000 未保持 unmapped")
        data_desc = _read_u64(image, 0x14000 + 2 * 8)
        if ((data_desc >> 6) & 0x3) != 0:
            errors.append(
                f"Q store data descriptor AP={(data_desc >> 6) & 0x3:02b}，"
                "不是 EL1-RW AP=00"
            )
        if _read_u64(image, 0x2000) != INITIAL_Q_DATA[0]:
            errors.append("Q store 目标页第一半初始数据已改变")
        if _read_u64(image, 0x2008) != INITIAL_Q_DATA[1]:
            errors.append("Q store 目标页第二半初始数据已改变")
    except GuardError as exc:
        errors.append(str(exc))

    if errors:
        raise GuardError("镜像语义守卫失败:\n  " + "\n  ".join(errors))
    return image


def _parse_trace_fields(line: str) -> dict[str, str]:
    parts = line.split()
    record: dict[str, str] = {"tag": parts[0]} if parts else {}
    for item in parts[1:]:
        key, separator, value = item.partition("=")
        if separator:
            record[key] = value
    return record


def _trace_records(path: Path) -> list[dict[str, str]]:
    """Read the scalar records from either a plain or gzip QEMU trace."""

    with path.open("rb") as probe:
        compressed = probe.read(2) == b"\x1f\x8b"
    stream = gzip.open(path, "rt", encoding="utf-8", errors="replace") \
        if compressed else path.open(encoding="utf-8", errors="replace")
    with stream:
        records = []
        for raw in stream:
            line = raw.strip()
            if not line or line.startswith("#") or line.startswith("fp_"):
                continue
            record = _parse_trace_fields(line)
            if record.get("tag") == "commit":
                records.append(record)
    if not records:
        raise GuardError(f"QEMU trace 没有 commit 记录：{path}")
    return records


def _uint(record: dict[str, str], key: str, default: int | None = None) -> int:
    value = record.get(key)
    if value is None:
        if default is not None:
            return default
        raise GuardError(f"trace commit 缺少字段 {key}")
    try:
        return int(value, 0)
    except ValueError as exc:
        raise GuardError(f"trace 字段 {key} 非整数：{value}") from exc


def check_trace(path: Path) -> None:
    records = _trace_records(path)
    order = [
        (BASE + 0x2C, CPACR_MSR, "CPACR MSR"),
        (BASE + 0x30, ISB_SY, "ISB"),
        (BASE + 0x34, NEON_MOVI, "first NEON MOVI"),
        (PAGE_END_PC, Q_STORE, "page-end STR Q"),
    ]
    positions: list[int] = []
    for address, insn, label in order:
        matches = [
            i for i, record in enumerate(records)
            if _uint(record, "pc") == address and _uint(record, "insn") == insn
        ]
        if not matches:
            raise GuardError(f"QEMU trace 未观察到 {label} @0x{address:x}")
        positions.append(matches[0])
    if positions != sorted(positions):
        raise GuardError(
            "QEMU trace 顺序错误：CPACR/ISB/NEON/页末 STR Q 未按程序顺序提交"
        )

    # A first-NEON access trap would be the exact false-green failure this
    # guard exists to catch.  Reject any exception attached before the page
    # end, including the historical EC=0x07.
    for record in records[:positions[-1] + 1]:
        if _uint(record, "exc_valid", 0) and _uint(record, "pc") != PAGE_END_PC:
            code = _uint(record, "exc_code", 0)
            raise GuardError(
                f"页末前出现异常 commit pc=0x{_uint(record, 'pc'):x} EC=0x{code:x}"
            )

    q_records = [
        record for record in records
        if _uint(record, "pc") == PAGE_END_PC and
        _uint(record, "insn") == Q_STORE
    ]
    if len(q_records) != 1:
        raise GuardError(f"页末 STR Q 记录数为 {len(q_records)}，期望恰好 1")
    q_record = q_records[0]
    if _uint(q_record, "next_pc") != HANDLER_PC:
        raise GuardError(
            f"页末 STR Q next_pc=0x{_uint(q_record, 'next_pc'):x}，"
            f"期望异常向量 0x{HANDLER_PC:x}"
        )
    # Non-step QEMU trace mode intentionally does not register the fork
    # discon callback, so its scalar record has no usable EC field.  The
    # strict step runner's QEMU side log is the authoritative EC=0x21 proof;
    # if a trace producer does include an exception field, still reject the
    # historical EC=0x07 signature.
    if _uint(q_record, "exc_code", 0) == 0x7:
        raise GuardError("页末 STR Q 仍报告 EC=0x07，拒绝假绿")
    if _uint(q_record, "stores") != 2:
        raise GuardError(
            f"页末 STR Q stores={_uint(q_record, 'stores')}，期望 mem+mem2 两条记录"
        )

    stores = []
    for index in range(2):
        address = _uint(q_record, f"s{index}_addr")
        data = _uint(q_record, f"s{index}_data")
        size = _uint(q_record, f"s{index}_size")
        stores.append((address, data, size))
    expected = [
        (Q_DATA0, Q_STORE_VALUES[0], 8),
        (Q_DATA1, Q_STORE_VALUES[1], 8),
    ]
    if stores != expected:
        raise GuardError(f"页末 STR Q store tuples={stores!r}，期望 {expected!r}")


def _read_text(path: Path) -> str:
    return path.read_text(encoding="utf-8", errors="replace")


def check_strict_log(path: Path) -> None:
    text = _read_text(path)
    if re.search(r"\bEC=0x0*7\b", text, flags=re.IGNORECASE):
        raise GuardError(f"strict QEMU 日志含历史早期 EC=0x07：{path}")
    # The fork prints the exception summary and the preceding ELR/PC detail
    # on adjacent lines.  Bind them within that small local window instead of
    # requiring a single physical line (or accepting unrelated EC/PC lines
    # from a stale run).
    bound_ec21 = False
    lines = text.splitlines()
    for index, line in enumerate(lines):
        if re.search(r"sync exception EC=0x21\b", line,
                     flags=re.IGNORECASE):
            nearby = "\n".join(lines[max(0, index - 1):index + 2])
            if re.search(r"异常指令 pc=0x44000ffc\b", nearby):
                bound_ec21 = True
                break
    if not bound_ec21:
        raise GuardError(
            f"strict QEMU 日志未观察绑定到页末 STR Q 的 EC=0x21：{path}"
        )


_COORD_RE = re.compile(
    r"seq=(\d+) OK \(pc=0x([0-9a-fA-F]+) next=0x([0-9a-fA-F]+) "
    r"exc=(\d+) mon_we=(\d+) mon_v=(\d+)\)"
)


def check_coord_log(path: Path, max_insns: int = MAX_INSNS) -> None:
    records = []
    for line in _read_text(path).splitlines():
        match = _COORD_RE.search(line)
        if match:
            records.append(tuple(int(value, 16) if index in (1, 2)
                                 else int(value)
                                 for index, value in enumerate(match.groups())))
    if len(records) != max_insns:
        raise GuardError(
            f"coordinator 进度记录 {len(records)}/{max_insns}，"
            "请使用 PROGRESS_EVERY=1 保留逐提交证据"
        )
    seqs = [record[0] for record in records]
    if seqs != list(range(max_insns)):
        raise GuardError(f"coordinator seq={seqs!r} 不是连续 0..{max_insns - 1}")
    q_records = [record for record in records if record[1] == PAGE_END_PC]
    if len(q_records) != 1:
        raise GuardError(f"coordinator 页末提交数为 {len(q_records)}，期望 1")
    q_record = q_records[0]
    if q_record[2] != HANDLER_PC or q_record[3] != 1:
        raise GuardError(
            "coordinator 页末提交未显示 next=向量且 exc=1："
            f"pc=0x{q_record[1]:x} next=0x{q_record[2]:x} exc={q_record[3]}"
        )
    q_seq = q_record[0]
    if any(record[3] for record in records if record[0] < q_seq):
        raise GuardError("页末提交前已有异常，疑似首条 NEON EC=0x07 假绿")


def _run_qemu_trace(image: Path, trace: Path, qemu: Path, plugin: Path,
                    qemu_log: Path, timeout_seconds: float) -> None:
    trace.parent.mkdir(parents=True, exist_ok=True)
    qemu_log.parent.mkdir(parents=True, exist_ok=True)
    trace.unlink(missing_ok=True)
    command = [
        str(qemu), "-machine", "virt",
        "-cpu", "cortex-a76,cntfrq=1000000000,has_el3=false,has_el2=false",
        "-accel", "tcg,thread=single,tb-size=64",
        "-icount", "shift=0,align=off,sleep=off",
        "-rtc", "base=2000-01-01T00:00:00,clock=vm",
        "-nographic",
        "-plugin", f"file={plugin},fp=required,trace={trace},limit={MAX_INSNS}",
        "-device", f"loader,file={image},addr=0x{BASE:x},cpu-num=0,force-raw=on",
    ]
    with qemu_log.open("w", encoding="utf-8") as log:
        process = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT)
        try:
            process.wait(timeout=timeout_seconds)
        except subprocess.TimeoutExpired:
            process.terminate()
            try:
                process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
    # A self-loop is expected after the 20-record trace window.  The plugin
    # flushes its gzip member from the QEMU atexit callback on termination.
    if process.returncode not in (0, -15, -2):
        raise GuardError(
            f"QEMU semantic trace 非预期退出码 {process.returncode}，日志见 {qemu_log}"
        )
    if not trace.is_file():
        raise GuardError(f"QEMU semantic trace 未生成：{trace}")


def _fake_trace() -> str:
    lines = []
    for address, insn in (
        (BASE + 0x2C, CPACR_MSR),
        (BASE + 0x30, ISB_SY),
        (BASE + 0x34, NEON_MOVI),
    ):
        lines.append(
            f"commit pc=0x{address:x} insn=0x{insn:08x} "
            f"next_pc=0x{address + 4:x} exc_valid=0 exc_code=0 stores=0"
        )
    lines.append(
        f"commit pc=0x{PAGE_END_PC:x} insn=0x{Q_STORE:08x} "
        f"next_pc=0x{HANDLER_PC:x} exc_valid=0 stores=2 "
        f"s0_addr=0x{Q_DATA0:016x} s0_data=0x{Q_STORE_VALUES[0]:016x} s0_size=8 "
        f"s1_addr=0x{Q_DATA1:016x} s1_data=0x{Q_STORE_VALUES[1]:016x} s1_size=8"
    )
    return "\n".join(lines) + "\n"


def _fake_coord() -> str:
    lines = []
    for seq in range(MAX_INSNS):
        if seq == 18:
            pc, next_pc, exc = PAGE_END_PC, HANDLER_PC, 1
        else:
            pc, next_pc, exc = BASE + seq * 4, BASE + seq * 4 + 4, 0
        lines.append(
            f"seq={seq} OK (pc=0x{pc:x} next=0x{next_pc:x} "
            f"exc={exc} mon_we=0 mon_v=0)"
        )
    return "\n".join(lines) + "\n"


def self_test(image_path: Path) -> None:
    """Exercise valid evidence and reject old FPEN/AP/EC=0x07 evidence."""

    image = check_image(image_path)
    with tempfile.TemporaryDirectory(prefix="neon-fetch-fault-guard-",
                                      dir=image_path.parent) as temp_dir:
        root = Path(temp_dir)
        good_image = root / "good.bin"
        good_image.write_bytes(image)
        good_trace = root / "good.trace"
        good_trace.write_text(_fake_trace(), encoding="utf-8")
        good_strict = root / "good.qemu.log"
        good_strict.write_text(
            "lcvex_difftest: sync exception EC=0x21 "
            "（异常指令 pc=0x44000ffc）\n", encoding="utf-8"
        )
        good_coord = root / "good.coord.log"
        good_coord.write_text(_fake_coord(), encoding="utf-8")
        check_trace(good_trace)
        check_strict_log(good_strict)
        check_coord_log(good_coord)

        old_image = root / "old.bin"
        old_bytes = bytearray(image)
        # Historical false-green layout: the first NEON MOVI occupied 0x28,
        # with no CPACR/ISB setup.  Deliberately leave the rest untouched so
        # the rejection is attributable to the guard, not a malformed file.
        struct.pack_into("<I", old_bytes, 0x28, NEON_MOVI)
        old_image.write_bytes(old_bytes)
        try:
            check_image(old_image)
        except GuardError:
            print("SEMANTIC_NEGATIVE_PASS old_fpen_layout")
        else:
            raise AssertionError("old image unexpectedly passed image guard")

        readonly_image = root / "old-readonly-data.bin"
        readonly_bytes = bytearray(image)
        # The pre-fix descriptor 0x440024c3 has AP=11.  It is a valid page
        # descriptor, but read-only at EL1, so a page-end STR Q would become
        # EC=0x25 at the data VA instead of reaching the intended IABT.
        struct.pack_into("<Q", readonly_bytes, 0x14000 + 2 * 8,
                         OLD_READONLY_DATA_PAGE_DESC)
        readonly_image.write_bytes(readonly_bytes)
        try:
            check_image(readonly_image)
        except GuardError:
            print("SEMANTIC_NEGATIVE_PASS old_readonly_data_descriptor")
        else:
            raise AssertionError(
                "old read-only Q-store descriptor unexpectedly passed image guard"
            )

        old_strict = root / "old.qemu.log"
        old_strict.write_text(
            "lcvex_difftest: sync exception EC=0x7 "
            "（异常指令 pc=0x44000028）\n", encoding="utf-8"
        )
        try:
            check_strict_log(old_strict)
        except GuardError:
            print("SEMANTIC_NEGATIVE_PASS old_ec_0x07")
        else:
            raise AssertionError("EC=0x07 strict evidence unexpectedly passed")
    print(f"SEMANTIC_SELFTEST_PASS image={image_path}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--image", type=Path, required=True)
    parser.add_argument("--trace", type=Path)
    parser.add_argument("--strict-log", type=Path)
    parser.add_argument("--coord-log", type=Path)
    parser.add_argument("--runner-log", type=Path)
    parser.add_argument("--static-only", action="store_true")
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("--run-qemu", action="store_true",
                        help="先以 required profile 运行只读 QEMU trace")
    parser.add_argument("--qemu-bin", type=Path,
                        default=REPO_ROOT.parent /
                        "qemu" / "build" / "qemu-system-aarch64")
    parser.add_argument("--plugin", type=Path,
                        default=REPO_ROOT /
                        "qemu" / "plugins" / "lcvex_difftest.so")
    parser.add_argument("--qemu-log", type=Path)
    parser.add_argument("--timeout-seconds", type=float, default=5.0)
    args = parser.parse_args()

    try:
        check_image(args.image)
        if args.self_test:
            self_test(args.image)
            return 0
        if args.static_only:
            print(f"SEMANTIC_IMAGE_PASS image={args.image}")
            return 0
        required = {
            "--trace": args.trace,
            "--strict-log": args.strict_log,
            "--coord-log": args.coord_log,
        }
        missing = [name for name, value in required.items() if value is None]
        if missing:
            parser.error("动态守卫缺少 " + ", ".join(missing) +
                         "；或使用 --static-only/--self-test")
        assert args.trace is not None
        assert args.strict_log is not None
        assert args.coord_log is not None
        if args.run_qemu:
            qemu_log = args.qemu_log or args.trace.with_suffix(".qemu.log")
            _run_qemu_trace(args.image, args.trace, args.qemu_bin, args.plugin,
                            qemu_log, args.timeout_seconds)
        if args.runner_log is not None:
            runner_text = _read_text(args.runner_log)
            expected = "PASS: mode=step 锁步 20 条"
            if expected not in runner_text:
                raise GuardError(f"strict runner 未找到 {expected!r}：{args.runner_log}")
        check_trace(args.trace)
        check_strict_log(args.strict_log)
        check_coord_log(args.coord_log)
    except (GuardError, OSError, ValueError) as exc:
        print(f"SEMANTIC_GUARD_FAIL: {exc}")
        return 1
    print(
        f"SEMANTIC_GUARD_PASS image={args.image} "
        f"trace={args.trace} strict={args.strict_log} coord={args.coord_log}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
