#!/usr/bin/env python3
"""Hermetic checker for the B25 CDC data-delay contract.

The checker deliberately parses only active ``set_false_path``,
``set_data_delay`` and ``set_max_delay`` commands.  It does not invoke
Quartus, read a fitted database, consult a sibling checkout, or depend on
environment variables.  The five CDC pairs below must each have one exact
full false-path cut followed (in the SDC source) by one independent 2.000 ns
data-delay bound.  The optional ``--fault-matrix`` mode applies deterministic
in-memory mutations and proves that the fail-closed checks catch the common
ways this contract can regress.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_SDC = ROOT / "quartus/catapult_a10.sdc"
EXPECTED_VALUE = "2.000"
ALLOWED_OPTIONS = {"-from", "-to"}


@dataclass(frozen=True)
class Pair:
    """One source-to-first-stage CDC crossing and its expected width."""

    label: str
    source: str
    target: str
    width: int


PAIRS: tuple[Pair, ...] = (
    Pair(
        "request_wr",
        "*request_fifo|wr_ptr_gray_q*",
        "*request_fifo|wr_ptr_gray_rd1_q*",
        3,
    ),
    Pair(
        "request_rd",
        "*request_fifo|rd_ptr_gray_q*",
        "*request_fifo|rd_ptr_gray_wr1_q*",
        3,
    ),
    Pair(
        "response_rd",
        "*response_fifo|rd_ptr_gray_q*",
        "*response_fifo|rd_ptr_gray_wr1_q*",
        3,
    ),
    Pair(
        "response_wr",
        "*response_fifo|wr_ptr_gray_q*",
        "*response_fifo|wr_ptr_gray_rd1_q*",
        3,
    ),
    Pair(
        "poison",
        "*emif_adapter|emif_poisoned_q*",
        "*emif_adapter|emif_poisoned_cpu_meta_q*",
        1,
    ),
)

PAIR_BY_ROUTE = {(pair.source, pair.target): pair for pair in PAIRS}

# A command starts at the beginning of a non-comment line.  SDC commands in
# this project use Tcl's trailing backslash continuation; retaining the
# physical span lets --fault-matrix mutate a command without writing a file.
COMMAND_RE = re.compile(
    r"(?m)^[ \t]*(set_false_path|set_data_delay|set_max_delay)\b"
    r"[^\\\n]*(?:\\[ \t]*\n[^\\\n]*)*",
    re.IGNORECASE,
)
SELECTOR_RE = re.compile(
    r"\[get_registers\s+-nowarn\s+\{([^{}\n]*)\}\]"
)
TOKEN_RE = re.compile(r"\[get_registers\s+-nowarn\s+\{[^{}\n]*\}\]|[^\s]+")


@dataclass(frozen=True)
class Command:
    name: str
    line: int
    start: int
    end: int
    text: str
    tokens: tuple[str, ...]
    source: str | None
    target: str | None

    @property
    def value(self) -> str | None:
        """Return the trailing scalar, if this command has one."""

        if len(self.tokens) < 2:
            return None
        candidate = self.tokens[-1]
        if candidate.startswith("-") or candidate.startswith("["):
            return None
        return candidate

    @property
    def unsupported_options(self) -> tuple[str, ...]:
        return tuple(
            token
            for token in self.tokens[1:]
            if token.startswith("-") and token not in ALLOWED_OPTIONS
        )


def _strip_comments_preserve_spans(text: str) -> str:
    """Blank full-line comments while preserving every character offset.

    The SDC is intentionally simple and uses comments only at line starts.
    Inline comments are also blanked after a ``#`` outside a bracket/brace
    expression so a commented-out command can never be mistaken for active
    timing Tcl.  Newlines are retained for line-number reporting.
    """

    output: list[str] = []
    for line in text.splitlines(keepends=True):
        newline = ""
        body = line
        if body.endswith("\n"):
            body, newline = body[:-1], "\n"
            if body.endswith("\r"):
                body, newline = body[:-1], "\r\n"
        if body.lstrip().startswith("#"):
            output.append(" " * len(body) + newline)
            continue

        # Do not treat a # inside a Tcl brace/bracket expression as a
        # comment.  None of the expected selectors contains #, but retaining
        # this small scanner makes the parser safe for future selectors.
        brace_depth = 0
        bracket_depth = 0
        comment_at: int | None = None
        for index, char in enumerate(body):
            if char == "{":
                brace_depth += 1
            elif char == "}" and brace_depth:
                brace_depth -= 1
            elif char == "[":
                bracket_depth += 1
            elif char == "]" and bracket_depth:
                bracket_depth -= 1
            elif char == "#" and brace_depth == 0 and bracket_depth == 0:
                comment_at = index
                break
        if comment_at is not None:
            body = body[:comment_at] + " " * (len(body) - comment_at)
        output.append(body + newline)
    return "".join(output)


def _logical_text(command_text: str) -> str:
    return re.sub(r"\\[ \t]*\n", " ", command_text).strip()


def _tokens(command_text: str) -> tuple[str, ...]:
    return tuple(TOKEN_RE.findall(_logical_text(command_text)))


def _selector(token: str) -> str | None:
    match = SELECTOR_RE.fullmatch(token)
    return match.group(1) if match else None


def _route(tokens: Iterable[str]) -> tuple[str | None, str | None]:
    values = tuple(tokens)
    source: str | None = None
    target: str | None = None
    for index, token in enumerate(values[:-1]):
        if token == "-from":
            source = _selector(values[index + 1])
        elif token == "-to":
            target = _selector(values[index + 1])
    return source, target


def extract_commands(text: str) -> tuple[Command, ...]:
    """Extract active timing commands with source/target selectors."""

    clean = _strip_comments_preserve_spans(text)
    commands: list[Command] = []
    for match in COMMAND_RE.finditer(clean):
        raw = match.group(0)
        tokens = _tokens(raw)
        if not tokens:
            continue
        name = tokens[0].lower()
        source, target = _route(tokens)
        line = clean.count("\n", 0, match.start()) + 1
        commands.append(
            Command(
                name=name,
                line=line,
                start=match.start(),
                end=match.end(),
                text=raw,
                tokens=tokens,
                source=source,
                target=target,
            )
        )
    return tuple(commands)


def _pair_for(command: Command) -> Pair | None:
    if command.source is None or command.target is None:
        return None
    return PAIR_BY_ROUTE.get((command.source, command.target))


def _is_broad_selector(command: Command) -> bool:
    selectors = (command.source or "", command.target or "")
    return any(
        selector.endswith("|*")
        or selector in {"*request_fifo|*", "*response_fifo|*", "*emif_adapter|*"}
        for selector in selectors
    )


def _describe_route(command: Command) -> str:
    source = command.source if command.source is not None else "<unparsed>"
    target = command.target if command.target is not None else "<unparsed>"
    return f"line {command.line}: {source} -> {target}"


def _exact_false(command: Command, pair: Pair) -> bool:
    return (
        command.name == "set_false_path"
        and command.source == pair.source
        and command.target == pair.target
        and command.tokens
        == (
            "set_false_path",
            "-from",
            f"[get_registers -nowarn {{{pair.source}}}]",
            "-to",
            f"[get_registers -nowarn {{{pair.target}}}]",
        )
    )


def _exact_data(command: Command, pair: Pair) -> bool:
    return (
        command.name == "set_data_delay"
        and command.source == pair.source
        and command.target == pair.target
        and command.value == EXPECTED_VALUE
        and not command.unsupported_options
        and command.tokens
        == (
            "set_data_delay",
            "-from",
            f"[get_registers -nowarn {{{pair.source}}}]",
            "-to",
            f"[get_registers -nowarn {{{pair.target}}}]",
            EXPECTED_VALUE,
        )
    )


def _route_candidates(commands: Iterable[Command], name: str, pair: Pair) -> list[Command]:
    return [
        command
        for command in commands
        if command.name == name
        and command.source == pair.source
        and command.target == pair.target
    ]


def check_text(text: str) -> tuple[dict[str, object], list[str]]:
    """Check one SDC body and return JSON-ready details plus errors."""

    commands = extract_commands(text)
    errors: list[str] = []
    false_commands = [c for c in commands if c.name == "set_false_path"]
    data_commands = [c for c in commands if c.name == "set_data_delay"]
    max_commands = [c for c in commands if c.name == "set_max_delay"]

    if max_commands:
        for command in max_commands:
            errors.append(
                f"legacy set_max_delay is forbidden ({_describe_route(command)})"
            )

    for command in data_commands:
        if command.unsupported_options:
            options = ", ".join(command.unsupported_options)
            errors.append(
                f"unsupported set_data_delay option(s) {options} ({_describe_route(command)})"
            )
        if command.source is None or command.target is None:
            errors.append(f"unparseable set_data_delay ({_describe_route(command)})")
        elif _pair_for(command) is None:
            kind = "broad" if _is_broad_selector(command) else "wrong/unexpected"
            errors.append(f"{kind} set_data_delay selector ({_describe_route(command)})")
        elif command.value != EXPECTED_VALUE:
            errors.append(
                f"wrong set_data_delay value {command.value!r}; expected {EXPECTED_VALUE} "
                f"({_describe_route(command)})"
            )

    # No extra data-delay command is allowed: every such command must be one
    # of the five exact pair/value forms.  This catches a broad wildcard that
    # happens to coexist with all five required commands.
    extra_data = [
        command
        for command in data_commands
        if not any(_exact_data(command, pair) for pair in PAIRS)
    ]
    if extra_data:
        errors.append(
            f"unexpected set_data_delay command count={len(extra_data)}"
        )
    if len(data_commands) != len(PAIRS):
        errors.append(
            f"set_data_delay command count is {len(data_commands)}; expected {len(PAIRS)}"
        )

    for command in false_commands:
        if command.source is None or command.target is None:
            continue
        pair = _pair_for(command)
        if pair is None:
            # Other sections intentionally contain broad reset/control false
            # paths.  Diagnose a broad/wrong selector only when one side is
            # still an exact side of one of our five CDC pairs; otherwise it
            # is unrelated SDC policy and must not be rejected here.
            related = any(
                command.source == expected.source or command.target == expected.target
                for expected in PAIRS
            )
            if related:
                kind = "broad" if _is_broad_selector(command) else "wrong/unexpected"
                errors.append(
                    f"{kind} set_false_path selector ({_describe_route(command)})"
                )
            continue
        if command.unsupported_options:
            options = ", ".join(command.unsupported_options)
            errors.append(
                f"set_false_path for {pair.label} is not full; unsupported option(s) {options}"
            )
        elif not _exact_false(command, pair):
            errors.append(
                f"set_false_path for {pair.label} is not the exact full form "
                f"({_describe_route(command)})"
            )

    pair_details: dict[str, dict[str, object]] = {}
    for pair in PAIRS:
        false_candidates = _route_candidates(false_commands, "set_false_path", pair)
        data_candidates = _route_candidates(data_commands, "set_data_delay", pair)
        exact_false = [command for command in false_candidates if _exact_false(command, pair)]
        exact_data = [command for command in data_candidates if _exact_data(command, pair)]

        if len(exact_false) == 0:
            errors.append(f"missing exact full set_false_path for {pair.label}")
        elif len(exact_false) > 1:
            errors.append(
                f"duplicate exact full set_false_path for {pair.label}: {len(exact_false)}"
            )
        if len(exact_data) == 0:
            errors.append(f"missing exact set_data_delay 2.000 for {pair.label}")
        elif len(exact_data) > 1:
            errors.append(
                f"duplicate exact set_data_delay for {pair.label}: {len(exact_data)}"
            )
        if exact_false and exact_data and exact_false[0].start > exact_data[0].start:
            errors.append(
                f"set_data_delay precedes full set_false_path for {pair.label}"
            )

        pair_details[pair.label] = {
            "source": pair.source,
            "target": pair.target,
            "width": pair.width,
            "full_false_count": len(exact_false),
            "data_delay_count": len(exact_data),
            "false_route_candidates": len(false_candidates),
            "data_route_candidates": len(data_candidates),
            "false_line": exact_false[0].line if exact_false else None,
            "data_line": exact_data[0].line if exact_data else None,
        }

    result: dict[str, object] = {
        "status": "FAIL" if errors else "PASS",
        "expected_pairs": len(PAIRS),
        "active_command_counts": {
            "set_false_path": len(false_commands),
            "set_data_delay": len(data_commands),
            "set_max_delay": len(max_commands),
        },
        "pairs": pair_details,
        "errors": errors,
    }
    return result, errors


def _find_exact_command(text: str, name: str, pair: Pair) -> Command:
    commands = extract_commands(text)
    for command in commands:
        if command.name != name:
            continue
        if command.source != pair.source or command.target != pair.target:
            continue
        return command
    raise ValueError(f"cannot find {name} command for {pair.label}")


def _mutate_remove(text: str, command: Command) -> str:
    return text[: command.start] + text[command.end :]


def _mutate_duplicate(text: str, command: Command) -> str:
    body = text[command.start : command.end]
    return text[: command.end] + "\n" + body + text[command.end :]


def _mutate_replace(text: str, command: Command, old: str, new: str) -> str:
    body = text[command.start : command.end]
    if old not in body:
        raise ValueError(f"mutation anchor {old!r} missing from {command.name}")
    body = body.replace(old, new, 1)
    return text[: command.start] + body + text[command.end :]


def fault_matrix(text: str) -> dict[str, dict[str, object]]:
    """Apply common SDC faults in memory and report whether each was caught."""

    pair = PAIRS[0]
    data = _find_exact_command(text, "set_data_delay", pair)
    false = _find_exact_command(text, "set_false_path", pair)
    mutations = {
        "missing_data_delay": _mutate_remove(text, data),
        "duplicate_data_delay": _mutate_duplicate(text, data),
        "broad_data_delay": _mutate_replace(
            text, data, "{" + pair.source + "}", "{*request_fifo|*}"
        ),
        "wrong_data_delay_value": _mutate_replace(text, data, EXPECTED_VALUE, "2.500"),
        "unsupported_data_delay_option": _mutate_replace(
            text, data, "set_data_delay", "set_data_delay -setup"
        ),
        "legacy_set_max_delay": _mutate_replace(
            text, data, "set_data_delay", "set_max_delay"
        ),
        "missing_full_false_path": _mutate_remove(text, false),
        "duplicate_full_false_path": _mutate_duplicate(text, false),
        "broad_full_false_path": _mutate_replace(
            text, false, "{" + pair.target + "}", "{*request_fifo|*}"
        ),
        "hold_only_false_path": _mutate_replace(
            text, false, "set_false_path", "set_false_path -hold"
        ),
    }

    matrix: dict[str, dict[str, object]] = {}
    for name, mutated in mutations.items():
        result, errors = check_text(mutated)
        matrix[name] = {
            "caught": bool(errors),
            "status": result["status"],
            "errors": errors,
        }
    return matrix


def check_path(path: Path) -> tuple[dict[str, object], list[str]]:
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as exc:
        return {"status": "FAIL", "errors": [f"cannot read SDC {path}: {exc}"]}, [str(exc)]
    result, errors = check_text(text)
    result["sdc"] = str(path)
    return result, errors


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--sdc",
        type=Path,
        default=DEFAULT_SDC,
        help="SDC to check (default: fpga/catapult_a10/quartus/catapult_a10.sdc)",
    )
    parser.add_argument(
        "--fault-matrix",
        action="store_true",
        help="run deterministic in-memory missing/duplicate/broad/value/option faults",
    )
    args = parser.parse_args(argv)

    result, errors = check_path(args.sdc)
    if args.fault_matrix and not errors:
        text = args.sdc.read_text(encoding="utf-8")
        matrix = fault_matrix(text)
        result["fault_matrix"] = matrix
        missed = [name for name, row in matrix.items() if not row["caught"]]
        if missed:
            errors = [f"fault matrix missed: {', '.join(missed)}"]
            result["errors"] = errors
            result["status"] = "FAIL"

    print(json.dumps(result, indent=2, sort_keys=True))
    if errors:
        print("CDC_DATA_DELAY_SDC_CHECK_FAIL", file=sys.stderr)
        for error in errors:
            print(f"- {error}", file=sys.stderr)
        return 1
    print("CDC_DATA_DELAY_SDC_CHECK_PASS", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
