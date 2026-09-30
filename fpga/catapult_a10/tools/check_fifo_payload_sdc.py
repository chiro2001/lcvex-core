#!/usr/bin/env python3
"""Check the exact asynchronous FIFO payload exceptions in SDC section 3b.

The checker deliberately reads one SDC file and uses only the Python standard
library.  It does not invoke Quartus, inspect a fitted database, consult Git,
or resolve environment-dependent paths.  The contract is six direct
``set_false_path`` commands, one for each FIFO payload endpoint family:

* request FIFO memory -> ``emif_req_q``;
* response FIFO memory -> ``txn_local_q``, ``read_len_q``, ``read_beat_q``,
  ``read_line_q`` and ``response_code_q``.

Only section 3b is considered.  Other reset/CDC exceptions elsewhere in the
SDC are intentionally outside this checker contract.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from collections import defaultdict
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable


SCRIPT = Path(__file__).resolve()
DEFAULT_SDC = SCRIPT.parents[1] / "quartus" / "catapult_a10.sdc"


@dataclass(frozen=True)
class Pair:
    """An endpoint pair parsed from one active Tcl command."""

    source: str
    target: str
    strict: bool


@dataclass(frozen=True)
class Command:
    """One logical Tcl command and its one-based source line."""

    text: str
    line: int


EXPECTED: tuple[tuple[str, str, str], ...] = (
    (
        "request_mem_to_emif_req",
        "*request_fifo|mem*",
        "soc|emif_adapter|emif_req_q*",
    ),
    (
        "response_mem_to_txn_local",
        "*response_fifo|mem*",
        "soc|emif_adapter|txn_local_q*",
    ),
    (
        "response_mem_to_read_len",
        "*response_fifo|mem*",
        "soc|emif_adapter|read_len_q*",
    ),
    (
        "response_mem_to_read_beat",
        "*response_fifo|mem*",
        "soc|emif_adapter|read_beat_q*",
    ),
    (
        "response_mem_to_read_line",
        "*response_fifo|mem*",
        "soc|emif_adapter|read_line_q*",
    ),
    (
        "response_mem_to_response_code",
        "*response_fifo|mem*",
        "soc|emif_adapter|response_code_q*",
    ),
)
EXPECTED_BY_PAIR = {(source, target): name for name, source, target in EXPECTED}
EXPECTED_SOURCES = {source for _, source, _ in EXPECTED}
EXPECTED_TARGETS = {target for _, _, target in EXPECTED}
RESPONSE_TARGETS = {
    target for _, _, target in EXPECTED if target != "soc|emif_adapter|emif_req_q*"
}


def _normalise(text: str) -> str:
    """Collapse Tcl command whitespace while preserving endpoint spelling."""

    return " ".join(text.split())


def _section_bounds(lines: list[str]) -> tuple[int, int] | None:
    """Return zero-based ``(start, end)`` bounds for section 3b."""

    start = next(
        (index for index, line in enumerate(lines) if re.match(r"^\s*#\s*3b\.", line)),
        None,
    )
    if start is None:
        return None
    end = next(
        (
            index
            for index in range(start + 1, len(lines))
            if re.match(r"^\s*#\s*4(?:[a-z]*)?\.", lines[index])
        ),
        len(lines),
    )
    return start, end


def _split_semicolons(text: str) -> list[str]:
    """Split simple Tcl commands without splitting braces/brackets."""

    chunks: list[str] = []
    begin = 0
    brace_depth = 0
    bracket_depth = 0
    quote = False
    escaped = False
    for index, char in enumerate(text):
        if escaped:
            escaped = False
            continue
        if char == "\\":
            escaped = True
            continue
        if char == '"' and brace_depth == 0 and bracket_depth == 0:
            quote = not quote
            continue
        if quote:
            continue
        if char == "{":
            brace_depth += 1
        elif char == "}" and brace_depth:
            brace_depth -= 1
        elif char == "[":
            bracket_depth += 1
        elif char == "]" and bracket_depth:
            bracket_depth -= 1
        elif char == ";" and brace_depth == 0 and bracket_depth == 0:
            chunks.append(text[begin:index])
            begin = index + 1
    chunks.append(text[begin:])
    return chunks


def _logical_commands(lines: list[str], first_line: int) -> list[Command]:
    """Join backslash-continued lines and return active Tcl commands."""

    commands: list[Command] = []
    current: list[str] = []
    current_line = 0

    def flush() -> None:
        nonlocal current, current_line
        if not current:
            return
        joined = " ".join(part.strip() for part in current)
        for chunk in _split_semicolons(joined):
            if chunk.strip():
                commands.append(Command(_normalise(chunk), current_line))
        current = []
        current_line = 0

    for offset, raw in enumerate(lines):
        line = raw.rstrip()
        stripped = line.strip()
        if not current and (not stripped or stripped.startswith("#")):
            continue
        if not current:
            current_line = first_line + offset
        if line.endswith("\\"):
            current.append(line[:-1])
            continue
        current.append(line)
        flush()
    flush()
    return commands


STRICT_ENDPOINT_RE = r"\[get_registers\s+-nowarn\s+\{([^{}]*)\}\]"
GENERIC_ENDPOINT_RE = r"\[get_registers(?:\s+-nowarn)?\s+\{([^{}]*)\}\]"
STRICT_PAIR_RE = re.compile(
    rf"^set_false_path\s+-from\s+{STRICT_ENDPOINT_RE}\s+-to\s+{STRICT_ENDPOINT_RE}$"
)
GENERIC_PAIR_RE = re.compile(r"^set_false_path\b(?P<body>.*)$")
FROM_RE = re.compile(rf"-from\s+{GENERIC_ENDPOINT_RE}")
TO_RE = re.compile(rf"-to\s+{GENERIC_ENDPOINT_RE}")


def _parse_pair(text: str) -> Pair | None:
    strict_match = STRICT_PAIR_RE.fullmatch(text)
    if strict_match:
        return Pair(strict_match.group(1), strict_match.group(2), True)
    if not GENERIC_PAIR_RE.fullmatch(text):
        return None
    from_matches = FROM_RE.findall(text)
    to_matches = TO_RE.findall(text)
    if len(from_matches) != 1 or len(to_matches) != 1:
        return None
    return Pair(from_matches[0], to_matches[0], False)


def _fifo_kind(pattern: str) -> str | None:
    if pattern == "*request_fifo|mem*":
        return "request"
    if pattern == "*response_fifo|mem*":
        return "response"
    return None


def _is_fifo_mem(pattern: str) -> bool:
    return _fifo_kind(pattern) is not None


def _is_broad_fifo_source(pattern: str) -> bool:
    return bool(re.search(r"(?:request|response)_fifo\|", pattern)) and pattern not in EXPECTED_SOURCES


def _is_broad_adapter_target(pattern: str) -> bool:
    prefix = "soc|emif_adapter|"
    if not pattern.startswith(prefix):
        return False
    tail = pattern[len(prefix) :]
    if tail in {"*", "response_fifo|*"}:
        return True
    # These forms select multiple endpoint families, unlike the six explicit
    # ``*_q*`` families in the contract.
    if tail in {"txn_*", "read_*", "response_*", "*_q*"}:
        return True
    return "*" in tail and tail not in EXPECTED_TARGETS


def _target_kind(pattern: str) -> str | None:
    if pattern == "soc|emif_adapter|emif_req_q*":
        return "request"
    if pattern in RESPONSE_TARGETS:
        return "response"
    return None


def _pair_error(pair: Pair) -> str:
    """Classify a non-contract pair for fail-closed diagnostics."""

    source_kind = _fifo_kind(pair.source)
    target_kind = _target_kind(pair.target)
    if _is_broad_fifo_source(pair.source) or _is_broad_adapter_target(pair.target):
        return f"broad FIFO payload endpoint pair: {pair.source!r} -> {pair.target!r}"
    if _is_adapter_sink(pair.source) and _is_fifo_mem(pair.target):
        return f"wrong direction (adapter sink -> FIFO memory): {pair.source!r} -> {pair.target!r}"
    if source_kind is not None and target_kind is not None and source_kind != target_kind:
        return f"wrong direction (request/response domains crossed): {pair.source!r} -> {pair.target!r}"
    if _is_fifo_mem(pair.source) and pair.target.startswith("soc|emif_adapter|"):
        return f"unexpected FIFO payload destination (must be an exact family): {pair.source!r} -> {pair.target!r}"
    return f"unexpected FIFO payload endpoint pair: {pair.source!r} -> {pair.target!r}"


def _is_adapter_sink(pattern: str) -> bool:
    return pattern.startswith("soc|emif_adapter|") and not pattern.startswith(
        "soc|emif_adapter|request_fifo|"
    ) and not pattern.startswith("soc|emif_adapter|response_fifo|")


def check_text(text: str, label: str = "<memory>") -> tuple[dict[str, object], list[str]]:
    """Check one SDC text and return a JSON-compatible report plus errors."""

    errors: list[str] = []
    lines = text.splitlines()
    bounds = _section_bounds(lines)
    result: dict[str, object] = {
        "sdc": label,
        "section": "3b",
        "expected_endpoint_families": len(EXPECTED),
        "observed_commands": 0,
        "families": [],
    }
    if bounds is None:
        errors.append("section 3b marker or section 4 boundary missing")
        result["status"] = "FAIL"
        result["errors"] = errors
        return result, errors

    start, end = bounds
    commands = _logical_commands(lines[start + 1 : end], start + 2)
    result["section_lines"] = {"start": start + 1, "end": end}
    result["observed_commands"] = len(commands)
    if len(commands) != len(EXPECTED):
        errors.append(
            f"section 3b must contain exactly {len(EXPECTED)} active commands; got {len(commands)}"
        )

    observed: dict[tuple[str, str], list[int]] = defaultdict(list)
    for command in commands:
        if not command.text.startswith("set_false_path"):
            errors.append(
                f"line {command.line}: unexpected active command in section 3b: {command.text!r}"
            )
            continue
        pair = _parse_pair(command.text)
        if pair is None:
            errors.append(f"line {command.line}: malformed set_false_path command: {command.text!r}")
            continue
        observed[(pair.source, pair.target)].append(command.line)
        if not pair.strict:
            errors.append(
                f"line {command.line}: endpoint command is not the exact direct form: {command.text!r}"
            )
        if (pair.source, pair.target) not in EXPECTED_BY_PAIR:
            errors.append(f"line {command.line}: {_pair_error(pair)}")

    families: list[dict[str, object]] = []
    for name, source, target in EXPECTED:
        lines_for_pair = observed.get((source, target), [])
        family: dict[str, object] = {
            "name": name,
            "source": source,
            "target": target,
            "count": len(lines_for_pair),
            "lines": lines_for_pair,
        }
        families.append(family)
        if not lines_for_pair:
            errors.append(f"missing exact endpoint family: {name} ({source} -> {target})")
        elif len(lines_for_pair) > 1:
            errors.append(
                f"duplicate exact endpoint family: {name} occurs {len(lines_for_pair)} times"
            )
    result["families"] = families
    result["status"] = "FAIL" if errors else "PASS"
    result["errors"] = errors
    return result, errors


def check_path(path: Path) -> tuple[dict[str, object], list[str]]:
    """Read and check an SDC path without consulting any external state."""

    try:
        text = path.read_text(encoding="utf-8")
    except OSError as exc:
        result = {"sdc": str(path), "status": "FAIL", "errors": [f"cannot read SDC: {exc}"]}
        return result, list(result["errors"])
    return check_text(text, str(path))


def _command_block(source: str, target: str) -> str:
    return (
        f"set_false_path -from [get_registers -nowarn {{{source}}}] \\\n"
        f"               -to [get_registers -nowarn {{{target}}}]\n"
    )


def _replace_one(text: str, old: str, new: str) -> str:
    if text.count(old) != 1:
        raise AssertionError(f"self-test fixture anchor count is not one: {old!r}")
    return text.replace(old, new, 1)


def _self_test(path: Path) -> tuple[dict[str, object], list[str]]:
    """Run an in-memory positive and task-local fault matrix."""

    try:
        baseline = path.read_text(encoding="utf-8")
    except OSError as exc:
        return {"status": "FAIL", "errors": [f"cannot read self-test SDC: {exc}"]}, [str(exc)]

    _, positive_errors = check_text(baseline, "<self-test:positive>")
    errors: list[str] = []
    if positive_errors:
        errors.append(f"positive fixture unexpectedly failed: {positive_errors}")

    pairs = {name: (source, target) for name, source, target in EXPECTED}
    txn_source, txn_target = pairs["response_mem_to_txn_local"]
    request_source, request_target = pairs["request_mem_to_emif_req"]
    txn_block = _command_block(txn_source, txn_target)
    request_block = _command_block(request_source, request_target)

    mutations: list[tuple[str, str, str]] = []
    mutations.append(
        (
            "missing_request_family",
            "remove request_mem_to_emif_req",
            baseline.replace(request_block, "", 1),
        )
    )
    mutations.append(
        (
            "duplicate_response_txn_local",
            "duplicate response_mem_to_txn_local",
            _replace_one(baseline, txn_block, txn_block + txn_block),
        )
    )
    mutations.append(
        (
            "broad_response_target",
            "broaden response target to adapter wildcard",
            _replace_one(baseline, txn_block, _command_block(txn_source, "soc|emif_adapter|*")),
        )
    )
    mutations.append(
        (
            "broad_response_source",
            "broaden response source beyond memory",
            _replace_one(baseline, txn_block, _command_block("*response_fifo|*", txn_target)),
        )
    )
    mutations.append(
        (
            "wrong_direction",
            "swap response source and destination",
            _replace_one(baseline, txn_block, _command_block(txn_target, txn_source)),
        )
    )
    mutations.append(
        (
            "wrong_request_response_direction",
            "use response memory for request sink",
            _replace_one(baseline, request_block, _command_block("*response_fifo|mem*", request_target)),
        )
    )

    matrix: list[dict[str, object]] = []
    for name, mutation, fixture in mutations:
        report, fixture_errors = check_text(fixture, f"<self-test:{name}>")
        passed = bool(fixture_errors)
        matrix.append(
            {
                "name": name,
                "mutation": mutation,
                "expected": "FAIL",
                "observed_status": report.get("status"),
                "passed": passed,
                "errors": fixture_errors,
            }
        )
        if not passed:
            errors.append(f"fault fixture {name} was accepted")

    result: dict[str, object] = {
        "sdc": str(path),
        "status": "FAIL" if errors else "PASS",
        "positive": {"expected": "PASS", "passed": not positive_errors, "errors": positive_errors},
        "fault_matrix": matrix,
        "faults_passed": sum(1 for item in matrix if item["passed"]),
        "faults_total": len(matrix),
        "errors": errors,
    }
    return result, errors


def main(argv: Iterable[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--sdc",
        type=Path,
        default=DEFAULT_SDC,
        help="SDC to check (default: fpga/catapult_a10/quartus/catapult_a10.sdc)",
    )
    parser.add_argument(
        "--self-test",
        action="store_true",
        help="run a positive check and the task-local missing/duplicate/broad/direction fault matrix",
    )
    args = parser.parse_args(list(argv) if argv is not None else None)

    if args.self_test:
        result, errors = _self_test(args.sdc)
    else:
        result, errors = check_path(args.sdc)
    print(json.dumps(result, ensure_ascii=False, indent=2, sort_keys=True))
    if errors:
        print("FIFO_PAYLOAD_SDC_CHECK_FAIL", file=sys.stderr)
        for error in errors:
            print(f"- {error}", file=sys.stderr)
        return 1
    print("FIFO_PAYLOAD_SDC_CHECK_PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
