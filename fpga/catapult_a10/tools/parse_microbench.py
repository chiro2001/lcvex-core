#!/usr/bin/env python3
"""Strict parser for B25 microbench/CoreMark JTAG-UART transcripts."""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path


EXPECTED_COUNT = 24
EXPECTED_SIGNATURE = "8679CF21"
EXPECTED_CRCS = {
    "seed": 0xE9F5,
    "list": 0xE714,
    "matrix": 0x1FD7,
    "state": 0x8E3A,
}
CLOCK_HZ = 25_000_000
MIN_CYCLES = 250_000_000
EXPECTED_COMPILER_FLAGS = (
    "-std=c11 -O2 -march=armv8.2-a -mgeneral-regs-only -mstrict-align "
    "-ffreestanding -fno-builtin -fno-pie -fno-stack-protector "
    "-fno-unwind-tables -fno-asynchronous-unwind-tables "
    "-fno-tree-loop-distribute-patterns"
)


class ParseError(ValueError):
    pass


def _normalize_coremark_terminal_wrap(text: str) -> tuple[str, bool]:
    """Join the one observed Windows nios2-terminal right-margin redraw.

    When CMRESULT ends exactly in the terminal's last column, the captured
    console stream may redraw that last character after a CSI cursor-position
    sequence before continuing with `hz=...`. Accept only that unambiguous
    presentation artifact; never strip generic ANSI or whitespace.
    """

    pattern = re.compile(
        r"(?m)^(?P<record>CMRESULT VALID [^\r\n]*)\r?\n"
        r"\x1b\[(?P<row>[1-9][0-9]*);(?P<column>[1-9][0-9]*)H"
        r"(?P<redraw>[^\r\n])(?P<tail> hz=25000000[^\r\n]*)"
    )
    matches = list(pattern.finditer(text))
    if not matches:
        return text, False
    if len(matches) != 1:
        raise ParseError("ambiguous Windows terminal right-margin redraw")
    match = matches[0]
    record = match.group("record")
    column = int(match.group("column"), 10)
    if (
        column != len(record)
        or match.group("redraw") != record[-1:]
        or re.search(r" cycles=(?:0|[1-9][0-9]*)$", record) is None
    ):
        raise ParseError("unverified Windows terminal right-margin redraw")
    normalized = text[:match.start()] + record + match.group("tail") + text[match.end():]
    return normalized, True


def _single_line(text: str, prefix: str) -> str:
    lines = [line.strip() for line in text.splitlines() if line.strip().startswith(prefix)]
    if len(lines) != 1:
        raise ParseError(f"expected exactly one {prefix!r} line, found {len(lines)}")
    return lines[0]


def _fields(tokens: list[str]) -> dict[str, str]:
    result: dict[str, str] = {}
    for token in tokens:
        if "=" not in token:
            raise ParseError(f"malformed field {token!r}")
        key, value = token.split("=", 1)
        if not key or not value or key in result:
            raise ParseError(f"duplicate or empty field {token!r}")
        result[key] = value
    return result


def _decimal(fields: dict[str, str], key: str) -> int:
    value = fields.get(key)
    if value is None or re.fullmatch(r"0|[1-9][0-9]*", value) is None:
        raise ParseError(f"{key} is not canonical decimal")
    return int(value, 10)


def _hex(fields: dict[str, str], key: str) -> int:
    value = fields.get(key)
    if value is None or re.fullmatch(r"[0-9A-F]{8}", value) is None:
        raise ParseError(f"{key} is not eight uppercase hexadecimal digits")
    return int(value, 16)


def _check_crcs(fields: dict[str, str]) -> dict[str, int]:
    values = {name: _hex(fields, name) for name in (*EXPECTED_CRCS, "final")}
    for name, expected in EXPECTED_CRCS.items():
        if values[name] != expected:
            raise ParseError(f"{name} CRC mismatch: {values[name]:08X} != {expected:08X}")
    return values


def _raw_decimal(text: str, prefix: str) -> int:
    line = _single_line(text, prefix)
    value = line[len(prefix):]
    if re.fullmatch(r"0|[1-9][0-9]*", value) is None:
        raise ParseError(f"raw field {prefix!r} is not canonical decimal")
    return int(value, 10)


def _raw_hex(text: str, prefix: str) -> int:
    line = _single_line(text, prefix)
    value = line[len(prefix):]
    if re.fullmatch(r"0x[0-9a-fA-F]{4}", value) is None:
        raise ParseError(f"raw field {prefix!r} is not a four-digit hexadecimal value")
    return int(value, 16)


def parse_microbench(text: str) -> dict[str, object]:
    line = _single_line(text, "MBPASS ")
    match = re.fullmatch(r"MBPASS ([0-9]+) ([0-9A-F]{8})", line)
    if match is None:
        raise ParseError("malformed MBPASS line")
    count = int(match.group(1), 10)
    signature = match.group(2)
    if count != EXPECTED_COUNT or signature != EXPECTED_SIGNATURE:
        raise ParseError(
            f"microbench mismatch: count={count} signature={signature}"
        )
    if any(line_.strip().startswith("MBFAIL ") for line_ in text.splitlines()):
        raise ParseError("transcript contains MBFAIL")
    return {"status": "PASS", "count": count, "signature": signature}


def parse_selfcheck(text: str) -> dict[str, object]:
    line = _single_line(text, "CMSELF ")
    tokens = line.split()
    if len(tokens) < 3 or tokens[:2] != ["CMSELF", "PASS"]:
        raise ParseError("CoreMark short self-check did not report PASS")
    fields = _fields(tokens[2:])
    required = {"seed", "list", "matrix", "state", "final", "iterations", "cycles", "score"}
    if set(fields) != required:
        raise ParseError(f"CoreMark self-check fields mismatch: {sorted(fields)}")
    crcs = _check_crcs(fields)
    iterations = _decimal(fields, "iterations")
    cycles = _decimal(fields, "cycles")
    if iterations != 1 or cycles == 0 or fields["score"] != "INVALID":
        raise ParseError("short self-check must be one iteration with nonzero cycles and INVALID score")
    return {
        "status": "PASS",
        "mode": "selfcheck",
        "iterations": iterations,
        "cycles": cycles,
        "score": "INVALID",
        "crc": crcs,
    }


def parse_full(text: str) -> dict[str, object]:
    text, terminal_wrap_normalized = _normalize_coremark_terminal_wrap(text)
    line = _single_line(text, "CMRESULT ")
    tokens = line.split()
    if len(tokens) < 3 or tokens[0] != "CMRESULT":
        raise ParseError("malformed CMRESULT line")
    if tokens[1] != "VALID":
        raise ParseError(f"firmware rejected CoreMark result: {tokens[1]}")
    fields = _fields(tokens[2:])
    required = {
        "seed", "list", "matrix", "state", "final", "iterations",
        "cycles", "hz", "cms_x1000", "cmmhz_x1000",
    }
    if set(fields) != required:
        raise ParseError(f"CoreMark result fields mismatch: {sorted(fields)}")
    crcs = _check_crcs(fields)
    iterations = _decimal(fields, "iterations")
    cycles = _decimal(fields, "cycles")
    hz = _decimal(fields, "hz")
    cms_x1000 = _decimal(fields, "cms_x1000")
    cmmhz_x1000 = _decimal(fields, "cmmhz_x1000")
    if iterations == 0 or cycles < MIN_CYCLES or hz != CLOCK_HZ:
        raise ParseError(
            f"invalid measurement window: iterations={iterations} cycles={cycles} hz={hz}"
        )
    expected_cms = iterations * CLOCK_HZ * 1000 // cycles
    expected_cmmhz = iterations * 1_000_000_000 // cycles
    if cms_x1000 != expected_cms or cmmhz_x1000 != expected_cmmhz:
        raise ParseError(
            "score mismatch: "
            f"cms_x1000={cms_x1000}/{expected_cms} "
            f"cmmhz_x1000={cmmhz_x1000}/{expected_cmmhz}"
        )

    # Do not trust the firmware's VALID token or summary in isolation.  The
    # unmodified upstream report is present in full mode; bind every decisive
    # raw field to the compact record and independently require its success
    # marker and lack of error text.
    raw_size = _raw_decimal(text, "CoreMark Size    : ")
    raw_ticks = _raw_decimal(text, "Total ticks      : ")
    raw_seconds = _raw_decimal(text, "Total time (secs): ")
    raw_iterations_per_second = _raw_decimal(text, "Iterations/Sec   : ")
    raw_iterations = _raw_decimal(text, "Iterations       : ")
    raw_crcs = {
        "seed": _raw_hex(text, "seedcrc          : "),
        "list": _raw_hex(text, "[0]crclist       : "),
        "matrix": _raw_hex(text, "[0]crcmatrix     : "),
        "state": _raw_hex(text, "[0]crcstate      : "),
        "final": _raw_hex(text, "[0]crcfinal      : "),
    }
    if raw_size != 666:
        raise ParseError(f"raw CoreMark size is {raw_size}, expected 666")
    if raw_ticks != cycles or raw_seconds != cycles // CLOCK_HZ:
        raise ParseError("raw timing fields do not match CMRESULT")
    if raw_iterations != iterations or raw_iterations_per_second != iterations // raw_seconds:
        raise ParseError("raw iteration fields do not match CMRESULT")
    if raw_crcs != crcs:
        raise ParseError("raw CRC fields do not match CMRESULT")
    compiler_version_line = _single_line(text, "Compiler version : ")
    if not compiler_version_line.startswith("Compiler version : aarch64-linux-gnu-gcc "):
        raise ParseError("raw compiler version is not the pinned AArch64 GCC port")
    if _single_line(text, "Compiler flags   : ") != f"Compiler flags   : {EXPECTED_COMPILER_FLAGS}":
        raise ParseError("raw compiler flags do not match the audited port")
    if _single_line(text, "Memory location  : ") != "Memory location  : 64KiB M20K BRAM":
        raise ParseError("raw memory location is not the BRAM port")
    _single_line(text, "2K performance run parameters for coremark.")
    _single_line(text, "Correct operation validated. See readme.txt for run and reporting rules.")
    if any(marker in text for marker in ("ERROR!", "Errors detected", "Cannot validate operation")):
        raise ParseError("upstream report contains an error marker")
    return {
        "status": "VALID",
        "mode": "full",
        "iterations": iterations,
        "cycles": cycles,
        "hz": hz,
        "coremark_per_second_x1000": cms_x1000,
        "coremark_per_mhz_x1000": cmmhz_x1000,
        "crc": crcs,
        "upstream_raw_crosscheck": "PASS",
        "compiler_version": compiler_version_line.removeprefix("Compiler version : "),
        "terminal_capture_normalization": (
            "windows_right_margin_redraw" if terminal_wrap_normalized else "none"
        ),
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--mode", choices=("microbench", "selfcheck", "full", "all"), required=True)
    parser.add_argument("--input", type=Path, help="transcript path; stdin when omitted")
    args = parser.parse_args()
    text = args.input.read_text(encoding="utf-8", errors="strict") if args.input else sys.stdin.read()
    try:
        if args.mode == "microbench":
            result: object = parse_microbench(text)
        elif args.mode == "selfcheck":
            result = parse_selfcheck(text)
        elif args.mode == "full":
            result = parse_full(text)
        else:
            result = {
                "microbench": parse_microbench(text),
                "selfcheck": parse_selfcheck(text),
                "full": parse_full(text),
            }
    except ParseError as exc:
        print(f"MICROBENCH_PARSE_FAIL reason={exc}", file=sys.stderr)
        return 1
    print(json.dumps(result, sort_keys=True))
    print(f"MICROBENCH_PARSE_PASS mode={args.mode}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
