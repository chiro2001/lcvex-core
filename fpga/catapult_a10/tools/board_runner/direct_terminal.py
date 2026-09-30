#!/usr/bin/env python3
"""Run one contract-driven paced JTAG-UART session with fail-closed gates."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import select
import signal
import subprocess
import termios
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Callable

from validate_contract import load_contract


LABEL_RE = re.compile(r"^[A-Za-z0-9_-]+$")


def now_iso() -> str:
    return datetime.now(timezone.utc).astimezone().isoformat()


def rows(data: bytes, tag: bytes) -> list[tuple[int, int, int, int]]:
    pattern = tag + rb"\s+([0-9A-Fa-f]{8})\s+([0-9A-Fa-f]{8})\s+([0-9A-Fa-f]{8})\s+([0-9A-Fa-f]{8})"
    return [tuple(int(group, 16) for group in match.groups()) for match in re.finditer(pattern, data)]


def rxdbg_rows(data: bytes) -> list[tuple[int, int]]:
    return [
        (int(first, 16), int(second, 16))
        for first, second in re.findall(rb"RXDBG\s+([0-9A-Fa-f]{8})\s+([0-9A-Fa-f]{8})", data)
    ]


def parsed_payload(data: bytes) -> dict[str, object]:
    return {
        "rxdbg_lines": [list(row) for row in rxdbg_rows(data)],
        "rxpath_lines": [list(row) for row in rows(data, b"RXPATH")],
        "rxcpu_lines": [list(row) for row in rows(data, b"RXCPU")],
        "text_lines": [line.decode("ascii", errors="replace") for line in data.splitlines()],
    }


def remote_command(contract: dict[str, object]) -> str:
    hardware = contract["hardware"]
    terminal = contract["terminal"]
    assert isinstance(hardware, dict) and isinstance(terminal, dict)
    return (
        f'{terminal["executable"]} -c "{hardware["console_cable"]}" '
        f'-d {hardware["console_device"]} -i {hardware["console_instance"]}'
    )


class LiveTerminal:
    def __init__(self, contract: dict[str, object]) -> None:
        remote = contract["remote"]
        assert isinstance(remote, dict)
        self.command = remote_command(contract)
        self.master, slave = os.openpty()
        attrs = termios.tcgetattr(slave)
        attrs[3] &= ~(termios.ECHO | termios.ECHONL)
        termios.tcsetattr(slave, termios.TCSANOW, attrs)
        self.proc = subprocess.Popen(
            [
                "ssh", "-tt", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10",
                str(remote["host"]), self.command,
            ],
            stdin=slave,
            stdout=slave,
            stderr=slave,
            close_fds=True,
        )
        os.close(slave)
        self.buffer = bytearray()
        self.events: list[dict[str, object]] = []
        self.started = time.time()
        self.started_iso = now_iso()

    def read_once(self, timeout: float = 1.0) -> bool:
        ready, _, _ = select.select([self.master], [], [], timeout)
        if not ready:
            return False
        try:
            chunk = os.read(self.master, 65536)
        except OSError:
            return False
        if not chunk:
            return False
        self.buffer.extend(chunk)
        return True

    def wait_regex(self, pattern: bytes, timeout: float, start: int = 0) -> re.Match[bytes]:
        compiled = re.compile(pattern, re.MULTILINE)
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            match = compiled.search(bytes(self.buffer), start)
            if match is not None:
                return match
            if self.proc.poll() is not None:
                raise RuntimeError(f"terminal exited before {pattern!r}: {self.proc.returncode}")
            self.read_once(min(1.0, max(0.05, deadline - time.monotonic())))
        raise RuntimeError(f"timeout waiting for {pattern!r}")

    def send_raw_regex(self, byte: bytes, name: str, response: bytes, timeout: float, attempt: int) -> dict[str, object]:
        if len(byte) != 1:
            raise RuntimeError("terminal plan byte must contain exactly one byte")
        before = len(self.buffer)
        sent_at = time.time()
        os.write(self.master, byte)
        event: dict[str, object] = {
            "name": name,
            "attempt": attempt,
            "byte_hex": byte.hex(),
            "offset": before,
            "sent_at": sent_at,
            "sent_at_iso": datetime.fromtimestamp(sent_at, timezone.utc).astimezone().isoformat(),
            "response_pattern": response.decode("ascii", errors="strict"),
        }
        self.events.append(event)
        match = self.wait_regex(response, timeout, before)
        event["response_match_start"] = match.start()
        event["response_match_end"] = match.end()
        event["response_text"] = match.group(0).decode("ascii", errors="replace")
        event["responded_at"] = time.time()
        event["responded_at_iso"] = now_iso()
        return event

    def stop(self) -> None:
        if self.proc.poll() is None:
            try:
                os.write(self.master, b"\x03")
            except OSError:
                pass
            deadline = time.monotonic() + 15.0
            while self.proc.poll() is None and time.monotonic() < deadline:
                self.read_once(0.5)
            if self.proc.poll() is None:
                os.kill(self.proc.pid, signal.SIGTERM)
                self.proc.wait(timeout=10)
        for _ in range(5):
            self.read_once(0.2)
        os.close(self.master)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--contract", required=True, type=Path)
    parser.add_argument("--task-id", required=True)
    parser.add_argument("--output-dir", type=Path)
    parser.add_argument("--run-label")
    parser.add_argument("--print-command", action="store_true")
    args = parser.parse_args()
    if not args.print_command:
        if args.output_dir is None or args.run_label is None:
            parser.error("--output-dir and --run-label are required unless --print-command is used")
        if not LABEL_RE.fullmatch(args.run_label):
            parser.error("run label must contain only ASCII letters, digits, '_' or '-'")
    return args


def main() -> int:
    args = parse_args()
    contract = load_contract(args.contract, args.task_id)
    command = remote_command(contract)
    if args.print_command:
        print(command)
        return 0

    assert args.output_dir is not None and args.run_label is not None
    args.output_dir.mkdir(parents=True, exist_ok=True)
    transcript_path = args.output_dir / f"direct-terminal-{args.run_label}.typescript"
    result_path = args.output_dir / f"direct-terminal-{args.run_label}-result.json"
    parsed_path = args.output_dir / f"direct-terminal-{args.run_label}-parsed-lines.json"
    contract_hash = hashlib.sha256(args.contract.read_bytes()).hexdigest()
    terminal_plan = contract["terminal"]
    assert isinstance(terminal_plan, dict)

    terminal = LiveTerminal(contract)
    failure: str | None = None
    result: dict[str, object]
    predicates: dict[str, dict[str, object]] = {}
    try:
        cursor = 0
        for item in terminal_plan["startup_sequence"]:
            assert isinstance(item, dict)
            pattern = str(item["regex"]).encode("ascii")
            match = terminal.wait_regex(pattern, float(item["timeout_s"]), cursor)
            predicates[str(item["name"])] = {
                "matched": True,
                "start": match.start(),
                "end": match.end(),
                "text": match.group(0).decode("ascii", errors="replace"),
            }
            cursor = match.end()

        for item in terminal_plan["steps"]:
            assert isinstance(item, dict)
            accepted = False
            for attempt in range(1, int(item["max_attempts"]) + 1):
                event = terminal.send_raw_regex(
                    bytes.fromhex(str(item["byte_hex"])),
                    str(item["name"]),
                    str(item["response_regex"]).encode("ascii"),
                    float(item["timeout_s"]),
                    attempt,
                )
                accept_regex = item.get("accept_regex")
                accepted = accept_regex is None or bool(
                    re.search(str(accept_regex).encode("ascii"), str(event["response_text"]).encode("ascii"))
                )
                if accepted:
                    predicates[str(item["name"])] = {
                        "matched": True,
                        "attempt": attempt,
                        "text": event["response_text"],
                    }
                    break
                if attempt < int(item["max_attempts"]):
                    time.sleep(int(item["interval_s"]))
            if not accepted:
                raise RuntimeError(f"terminal step {item['name']} never matched accept_regex")

        for item in terminal_plan["postconditions"]:
            assert isinstance(item, dict)
            pattern = str(item["regex"]).encode("ascii")
            match = terminal.wait_regex(pattern, float(item["timeout_s"]), 0)
            predicates[str(item["name"])] = {
                "matched": True,
                "start": match.start(),
                "end": match.end(),
                "text": match.group(0).decode("ascii", errors="replace"),
            }

        data = bytes(terminal.buffer)
        connected = bool(re.search(rb"connected to hardware target using JTAG UART", data, re.I))
        required = {
            regex: bool(re.search(regex.encode("ascii"), data, re.MULTILINE))
            for regex in terminal_plan["required_regex"]
        }
        forbidden = {
            regex: bool(re.search(regex.encode("ascii"), data, re.MULTILINE))
            for regex in terminal_plan["forbidden_regex"]
        }
        acceptance = connected and all(required.values()) and not any(forbidden.values())
        result = {
            "result": "PASS" if acceptance else "FAIL",
            "acceptance": acceptance,
            "contract_id": contract["contract_id"],
            "contract_sha256": contract_hash,
            "connected": connected,
            "predicates": predicates,
            "required_regex": required,
            "forbidden_regex": forbidden,
            "input_events": terminal.events,
            "remote_command": command,
            "terminal_pid_local": terminal.proc.pid,
        }
        if not acceptance:
            raise RuntimeError("one or more terminal contract predicates were false")
    except Exception as exc:
        failure = str(exc)
        data = bytes(terminal.buffer)
        connected = bool(re.search(rb"connected to hardware target using JTAG UART", data, re.I))
        required = {
            regex: bool(re.search(regex.encode("ascii"), data, re.MULTILINE))
            for regex in terminal_plan["required_regex"]
        }
        forbidden = {
            regex: bool(re.search(regex.encode("ascii"), data, re.MULTILINE))
            for regex in terminal_plan["forbidden_regex"]
        }
        result = {
            "result": "FAIL",
            "acceptance": False,
            "failure": failure,
            "contract_id": contract["contract_id"],
            "contract_sha256": contract_hash,
            "connected": connected,
            "predicates": predicates,
            "required_regex": required,
            "forbidden_regex": forbidden,
            "input_events": terminal.events,
            "remote_command": command,
            "terminal_pid_local": terminal.proc.pid,
        }
    finally:
        terminal.stop()
        transcript = bytes(terminal.buffer)
        transcript_path.write_bytes(transcript)
        parsed = parsed_payload(transcript)
        parsed["predicates"] = predicates
        parsed_path.write_text(json.dumps(parsed, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        result["terminal_exit_code"] = terminal.proc.returncode
        result["terminal_started_at"] = terminal.started_iso
        result["finished_at"] = now_iso()
        result["transcript_bytes"] = transcript_path.stat().st_size
        result["transcript_sha256"] = hashlib.sha256(transcript).hexdigest()
        result["parsed_lines_path"] = str(parsed_path)
        result["parsed_lines_sha256"] = hashlib.sha256(parsed_path.read_bytes()).hexdigest()
        if failure is not None:
            result["failure"] = failure
        result_path.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(json.dumps(result, sort_keys=True))
    print(f"TRANSCRIPT={transcript_path}")
    print(f"TRANSCRIPT_SHA256={hashlib.sha256(transcript_path.read_bytes()).hexdigest()}")
    print(f"PARSED_LINES={parsed_path}")
    print(f"RESULT={result_path}")
    print(f"RESULT_SHA256={hashlib.sha256(result_path.read_bytes()).hexdigest()}")
    return 0 if result.get("acceptance") else 1


if __name__ == "__main__":
    raise SystemExit(main())
