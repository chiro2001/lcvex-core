#!/usr/bin/env python3
"""Fail-closed validation for a task-specific volatile B25 board contract."""

from __future__ import annotations

import argparse
import json
import re
from pathlib import Path
from typing import Any


TASK_RE = re.compile(r"^T-[0-9]{8}-[0-9]{3}$")
SHA_RE = re.compile(r"^[0-9a-f]{64}$")
HEX8_RE = re.compile(r"^0x[0-9A-Fa-f]{8}$")
DESIGN_RE = re.compile(r"^[0-9A-Fa-f]{16,64}$")
BYTE_RE = re.compile(r"^[0-9A-Fa-f]{2}$")
WIN_ABS_RE = re.compile(r"^[A-Za-z]:[A-Za-z0-9_.\\/+:-]+$")
HOST_RE = re.compile(r"^[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?$")
LABEL_VALUE_RE = re.compile(r"^[A-Za-z0-9_.-]+$")
FORBIDDEN_FORMAT_RE = re.compile(r"\.(?:jic|pof|rbf|jbc|svf|jam)$", re.IGNORECASE)
SERVER_FILES = {
    "ccl_ver.dll", "client.conf", "ftd2xx.dll", "ftd2xx_real.dll", "head_blaster.h",
    "jtag_client.dll", "jtag_hw_microsoft_catapult.dll", "jtagserver.exe", "msftdi.cfg",
    "pgm_pgmdrv_apu_usb.dll",
}
INITIAL_CHAIN_DEFAULT = "require_golden_design_hash"
INITIAL_CHAIN_USER_ATTESTED = "user_attested_flash_boot"
INITIAL_CHAIN_POLICIES = {INITIAL_CHAIN_DEFAULT, INITIAL_CHAIN_USER_ATTESTED}
USER_FLASH_BOOT_ATTESTATION = "user_confirmed_flash_boot_vexriscv_linux"
T053_CANDIDATE = {
    "path": (
        "D:/Projects/fpga-altra/lcvex/build/"
        "T-20260920-052-b25-coremark-uart-volatile-sof/"
        "fpga/catapult_a10/quartus/output_files/catapult_a10.sof"
    ),
    "bytes": 36842099,
    "sha256": "39c2945466804036366a6306125323b585bef097aded7e8fff494d60a3ea2def",
    "checksum": "0x31585D80",
    "design_hash": "48917DD6FD70C4420BD5765A206DACBB",
}
T053_GOLDEN = {
    "path": "D:/Projects/fpga-altra/a10-linux-riscv/dist/golden/vex_soc_ddr.sof",
    "bytes": 36844906,
    "sha256": "290ab3cfb18cfd6ee47e5a2bc9324e63882de51d0ae5ac6c2688d7d6a2385f92",
    "checksum": "0x31510BB6",
    "design_hash": "193DE4BC8A30F3ED5F1F",
}


class ContractError(ValueError):
    pass


def require_object(value: Any, where: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise ContractError(f"{where} must be an object")
    return value


def require_keys(value: dict[str, Any], keys: set[str], where: str) -> None:
    missing = sorted(keys - value.keys())
    if missing:
        raise ContractError(f"{where} missing keys: {', '.join(missing)}")


def require_string(value: Any, where: str) -> str:
    if not isinstance(value, str) or not value:
        raise ContractError(f"{where} must be a non-empty string")
    return value


def require_windows_path(value: Any, where: str, suffix: str | None = None) -> str:
    text = require_string(value, where)
    if not WIN_ABS_RE.match(text):
        raise ContractError(f"{where} must be an absolute Windows drive path")
    if FORBIDDEN_FORMAT_RE.search(text):
        raise ContractError(f"{where} names a forbidden persistent format")
    if suffix is not None and not text.lower().endswith(suffix.lower()):
        raise ContractError(f"{where} must end with {suffix}")
    return text


def validate_image(value: Any, where: str) -> None:
    image = require_object(value, where)
    require_keys(image, {"path", "bytes", "sha256", "checksum", "design_hash"}, where)
    require_windows_path(image["path"], f"{where}.path", ".sof")
    if not isinstance(image["bytes"], int) or isinstance(image["bytes"], bool) or image["bytes"] <= 0:
        raise ContractError(f"{where}.bytes must be a positive integer")
    if not SHA_RE.fullmatch(require_string(image["sha256"], f"{where}.sha256")):
        raise ContractError(f"{where}.sha256 must be lowercase SHA-256")
    if not HEX8_RE.fullmatch(require_string(image["checksum"], f"{where}.checksum")):
        raise ContractError(f"{where}.checksum must be 0x plus eight hex digits")
    if not DESIGN_RE.fullmatch(require_string(image["design_hash"], f"{where}.design_hash")):
        raise ContractError(f"{where}.design_hash must contain 16-64 hex digits")


def validate_regex(value: Any, where: str) -> str:
    text = require_string(value, where)
    try:
        re.compile(text.encode("ascii"))
    except (UnicodeEncodeError, re.error) as exc:
        raise ContractError(f"{where} is not a valid ASCII regex: {exc}") from exc
    return text


def validate_terminal(value: Any) -> None:
    terminal = require_object(value, "terminal")
    require_keys(
        terminal,
        {"executable", "startup_sequence", "steps", "postconditions", "required_regex", "forbidden_regex"},
        "terminal",
    )
    require_windows_path(terminal["executable"], "terminal.executable", ".exe")
    startup = terminal["startup_sequence"]
    steps = terminal["steps"]
    postconditions = terminal["postconditions"]
    if not isinstance(startup, list) or len(startup) < 2:
        raise ContractError("terminal.startup_sequence must contain at least two ordered predicates")
    if not isinstance(steps, list) or not steps:
        raise ContractError("terminal.steps must not be empty")
    if not isinstance(postconditions, list):
        raise ContractError("terminal.postconditions must be an array")
    names: set[str] = set()
    for index, entry_value in enumerate(startup):
        entry = require_object(entry_value, f"terminal.startup_sequence[{index}]")
        require_keys(entry, {"name", "regex", "timeout_s"}, f"terminal.startup_sequence[{index}]")
        name = require_string(entry["name"], f"terminal.startup_sequence[{index}].name")
        if name in names:
            raise ContractError(f"duplicate terminal predicate name: {name}")
        names.add(name)
        validate_regex(entry["regex"], f"terminal.startup_sequence[{index}].regex")
        if not isinstance(entry["timeout_s"], int) or not 1 <= entry["timeout_s"] <= 3600:
            raise ContractError(f"terminal.startup_sequence[{index}].timeout_s out of range")
    for index, entry_value in enumerate(steps):
        entry = require_object(entry_value, f"terminal.steps[{index}]")
        require_keys(
            entry,
            {"name", "byte_hex", "response_regex", "timeout_s", "max_attempts", "interval_s"},
            f"terminal.steps[{index}]",
        )
        name = require_string(entry["name"], f"terminal.steps[{index}].name")
        if name in names:
            raise ContractError(f"duplicate terminal predicate name: {name}")
        names.add(name)
        if not BYTE_RE.fullmatch(require_string(entry["byte_hex"], f"terminal.steps[{index}].byte_hex")):
            raise ContractError(f"terminal.steps[{index}].byte_hex must be exactly one byte")
        validate_regex(entry["response_regex"], f"terminal.steps[{index}].response_regex")
        if "accept_regex" in entry:
            validate_regex(entry["accept_regex"], f"terminal.steps[{index}].accept_regex")
        if not isinstance(entry["timeout_s"], int) or not 1 <= entry["timeout_s"] <= 7200:
            raise ContractError(f"terminal.steps[{index}].timeout_s out of range")
        if not isinstance(entry["max_attempts"], int) or not 1 <= entry["max_attempts"] <= 100:
            raise ContractError(f"terminal.steps[{index}].max_attempts out of range")
        if entry["max_attempts"] > 1 and "accept_regex" not in entry:
            raise ContractError(f"terminal.steps[{index}] needs accept_regex when max_attempts > 1")
        if not isinstance(entry["interval_s"], int) or not 0 <= entry["interval_s"] <= 300:
            raise ContractError(f"terminal.steps[{index}].interval_s out of range")
    for index, entry_value in enumerate(postconditions):
        entry = require_object(entry_value, f"terminal.postconditions[{index}]")
        require_keys(entry, {"name", "regex", "timeout_s"}, f"terminal.postconditions[{index}]")
        name = require_string(entry["name"], f"terminal.postconditions[{index}].name")
        if name in names:
            raise ContractError(f"duplicate terminal predicate name: {name}")
        names.add(name)
        validate_regex(entry["regex"], f"terminal.postconditions[{index}].regex")
        if not isinstance(entry["timeout_s"], int) or not 1 <= entry["timeout_s"] <= 7200:
            raise ContractError(f"terminal.postconditions[{index}].timeout_s out of range")
    for key in ("required_regex", "forbidden_regex"):
        values = terminal[key]
        if not isinstance(values, list):
            raise ContractError(f"terminal.{key} must be an array")
        for index, regex in enumerate(values):
            validate_regex(regex, f"terminal.{key}[{index}]")


def validate_contract(data: Any, expected_task_id: str | None = None) -> dict[str, Any]:
    root = require_object(data, "contract")
    require_keys(
        root,
        {
            "schema_version", "contract_id", "task_id", "remote", "paths", "hardware",
            "candidate", "golden", "server_bundle", "terminal", "policy",
        },
        "contract",
    )
    if root["schema_version"] != 1:
        raise ContractError("schema_version must equal 1")
    contract_id = require_string(root["contract_id"], "contract_id")
    if not LABEL_VALUE_RE.fullmatch(contract_id):
        raise ContractError("contract_id contains unsafe characters")
    task_id = require_string(root["task_id"], "task_id")
    if not TASK_RE.fullmatch(task_id):
        raise ContractError("task_id must match T-YYYYMMDD-NNN")
    if expected_task_id is not None and task_id != expected_task_id:
        raise ContractError(f"task_id mismatch: expected {expected_task_id}, got {task_id}")

    remote = require_object(root["remote"], "remote")
    require_keys(remote, {"host", "task_root", "bootstrap_path"}, "remote")
    host = require_string(remote["host"], "remote.host")
    if not HOST_RE.fullmatch(host):
        raise ContractError("remote.host contains unsafe characters")
    require_windows_path(remote["task_root"], "remote.task_root")
    require_windows_path(remote["bootstrap_path"], "remote.bootstrap_path", ".ps1")
    if task_id not in remote["task_root"] or task_id not in remote["bootstrap_path"]:
        raise ContractError("remote task_root and bootstrap_path must contain task_id")

    paths = require_object(root["paths"], "paths")
    require_keys(paths, {"quartus_bin", "license_file", "source_server"}, "paths")
    for key in ("quartus_bin", "license_file", "source_server"):
        require_windows_path(paths[key], f"paths.{key}")

    hardware = require_object(root["hardware"], "hardware")
    require_keys(
        hardware,
        {
            "jtag_id", "console_cable", "program_cable", "console_device", "console_instance",
            "server_port", "server_frequency_hz", "terminal_to_golden_delay_s", "required_nodes",
        },
        "hardware",
    )
    if not re.fullmatch(r"[0-9A-Fa-f]{8}", require_string(hardware["jtag_id"], "hardware.jtag_id")):
        raise ContractError("hardware.jtag_id must contain eight hex digits")
    for key in ("console_cable", "program_cable"):
        cable = require_string(hardware[key], f"hardware.{key}")
        if any(ord(char) < 0x20 for char in cable) or '"' in cable or "'" in cable:
            raise ContractError(f"hardware.{key} contains unsafe characters")
    if hardware["console_device"] != 1 or hardware["console_instance"] != 0:
        raise ContractError("reviewed B25 console must use device=1 instance=0")
    if hardware["server_port"] != 1310 or hardware["server_frequency_hz"] != 15000000:
        raise ContractError("reviewed programming server must use port 1310 at 15 MHz")
    delay = hardware["terminal_to_golden_delay_s"]
    if not isinstance(delay, int) or isinstance(delay, bool) or not 0 <= delay <= 60:
        raise ContractError("hardware.terminal_to_golden_delay_s must be an integer in [0, 60]")
    nodes = hardware["required_nodes"]
    if nodes != ["JTAG UART #0", "JTAG PHY #0"]:
        raise ContractError("required_nodes must be the reviewed UART/PHY pair")
    initial_chain_policy = hardware.get("initial_chain_policy", INITIAL_CHAIN_DEFAULT)
    if not isinstance(initial_chain_policy, str) or initial_chain_policy not in INITIAL_CHAIN_POLICIES:
        raise ContractError("hardware.initial_chain_policy is not a reviewed policy")
    if initial_chain_policy == INITIAL_CHAIN_USER_ATTESTED:
        if task_id != "T-20260920-053":
            raise ContractError("user-attested Flash boot policy is reserved for T-053")
        attestation = hardware.get("initial_state_attestation")
        if attestation != USER_FLASH_BOOT_ATTESTATION:
            raise ContractError("T-053 user-attested policy requires the fixed Flash boot attestation")
    elif "initial_state_attestation" in hardware:
        raise ContractError("initial_state_attestation is only valid with user-attested Flash boot policy")

    validate_image(root["candidate"], "candidate")
    validate_image(root["golden"], "golden")
    if root["candidate"]["sha256"] == root["golden"]["sha256"]:
        raise ContractError("candidate and golden identities must differ")
    if initial_chain_policy == INITIAL_CHAIN_USER_ATTESTED:
        if root["candidate"] != T053_CANDIDATE or root["golden"] != T053_GOLDEN:
            raise ContractError("user-attested initial policy requires the frozen T-053 candidate/golden pair")

    bundle = require_object(root["server_bundle"], "server_bundle")
    require_keys(bundle, {"required_files", "pinned_sha256"}, "server_bundle")
    required_files = bundle["required_files"]
    pinned = require_object(bundle["pinned_sha256"], "server_bundle.pinned_sha256")
    expected_pins = {"jtagserver.exe", "jtag_hw_microsoft_catapult.dll", "client.conf", "msftdi.cfg"}
    if not isinstance(required_files, list) or set(required_files) != SERVER_FILES or len(required_files) != len(SERVER_FILES):
        raise ContractError("server_bundle.required_files must equal the reviewed ten-file set")
    if set(pinned) != expected_pins:
        raise ContractError("server bundle pins must exactly cover the reviewed four identities")
    for name, sha in pinned.items():
        if "/" in name or "\\" in name or not SHA_RE.fullmatch(require_string(sha, f"server pin {name}")):
            raise ContractError(f"invalid server bundle pin: {name}")

    validate_terminal(root["terminal"])

    policy = require_object(root["policy"], "policy")
    expected_policy = {
        "volatile_sof_only": True,
        "persistent_formats_allowed": False,
        "allow_reset": False,
        "allow_power_cycle": False,
        "allow_standard_or_unknown_process_stop": False,
        "candidate_program_invocations": 1,
        "terminal_sessions": 1,
        "golden_program_invocations": 1,
    }
    require_keys(policy, set(expected_policy), "policy")
    for key, expected in expected_policy.items():
        if policy[key] != expected:
            raise ContractError(f"policy.{key} must equal {expected!r}")
    return root


def load_contract(path: Path, expected_task_id: str | None = None) -> dict[str, Any]:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise ContractError(f"cannot read contract {path}: {exc}") from exc
    return validate_contract(data, expected_task_id)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--contract", required=True, type=Path)
    parser.add_argument("--task-id")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    contract = load_contract(args.contract, args.task_id)
    print(json.dumps({"result": "PASS", "task_id": contract["task_id"], "contract_id": contract["contract_id"]}, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
