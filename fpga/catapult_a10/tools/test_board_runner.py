#!/usr/bin/env python3
"""No-hardware regression for the tracked B25 board runner contract."""

from __future__ import annotations

import copy
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


TOOLS = Path(__file__).resolve().parent / "board_runner"
EXAMPLE = TOOLS / "contract-example.json"

spec = importlib.util.spec_from_file_location("board_contract", TOOLS / "validate_contract.py")
assert spec is not None and spec.loader is not None
board_contract = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = board_contract
spec.loader.exec_module(board_contract)


class ContractTests(unittest.TestCase):
    def setUp(self) -> None:
        self.contract = json.loads(EXAMPLE.read_text(encoding="utf-8"))

    def reject(self, mutate) -> None:
        value = copy.deepcopy(self.contract)
        mutate(value)
        with self.assertRaises(board_contract.ContractError):
            board_contract.validate_contract(value, "T-20990101-001")

    @staticmethod
    def attested_t053_contract() -> dict[str, object]:
        value = json.loads(EXAMPLE.read_text(encoding="utf-8"))
        value["contract_id"] = "t053-b25-coremark-uart-fixed"
        value["task_id"] = "T-20260920-053"
        value["remote"]["task_root"] = "D:/Projects/fpga-altra/lcvex/build/T-20260920-053-b25-coremark-uart-board"
        value["remote"]["bootstrap_path"] = "D:/Projects/fpga-altra/lcvex/build/T-20260920-053-prepare.ps1"
        value["candidate"] = {
            "path": "D:/Projects/fpga-altra/lcvex/build/T-20260920-052-b25-coremark-uart-volatile-sof/fpga/catapult_a10/quartus/output_files/catapult_a10.sof",
            "bytes": 36842099,
            "sha256": "39c2945466804036366a6306125323b585bef097aded7e8fff494d60a3ea2def",
            "checksum": "0x31585D80",
            "design_hash": "48917DD6FD70C4420BD5765A206DACBB",
        }
        value["golden"] = {
            "path": "D:/Projects/fpga-altra/a10-linux-riscv/dist/golden/vex_soc_ddr.sof",
            "bytes": 36844906,
            "sha256": "290ab3cfb18cfd6ee47e5a2bc9324e63882de51d0ae5ac6c2688d7d6a2385f92",
            "checksum": "0x31510BB6",
            "design_hash": "193DE4BC8A30F3ED5F1F",
        }
        value["hardware"]["initial_chain_policy"] = "user_attested_flash_boot"
        value["hardware"]["initial_state_attestation"] = "user_confirmed_flash_boot_vexriscv_linux"
        return value

    def test_example_passes(self) -> None:
        result = board_contract.validate_contract(self.contract, "T-20990101-001")
        self.assertEqual(result["contract_id"], "non-executable-example")

    def test_task_mismatch_fails(self) -> None:
        with self.assertRaisesRegex(board_contract.ContractError, "task_id mismatch"):
            board_contract.validate_contract(self.contract, "T-20990101-002")

    def test_persistent_candidate_format_fails(self) -> None:
        self.reject(lambda value: value["candidate"].__setitem__("path", "D:/artifacts/candidate.jic"))

    def test_policy_relaxation_fails(self) -> None:
        self.reject(lambda value: value["policy"].__setitem__("allow_reset", True))

    def test_bad_hash_fails(self) -> None:
        self.reject(lambda value: value["candidate"].__setitem__("sha256", "A" * 64))

    def test_candidate_equals_golden_fails(self) -> None:
        self.reject(lambda value: value["golden"].__setitem__("sha256", value["candidate"]["sha256"]))

    def test_server_file_path_traversal_fails(self) -> None:
        self.reject(lambda value: value["server_bundle"]["required_files"].__setitem__(0, "../evil.dll"))

    def test_wrong_console_instance_fails(self) -> None:
        self.reject(lambda value: value["hardware"].__setitem__("console_instance", 1))

    def test_excessive_terminal_to_golden_delay_fails(self) -> None:
        self.reject(lambda value: value["hardware"].__setitem__("terminal_to_golden_delay_s", 61))

    def test_user_attested_flash_boot_policy_accepts_only_frozen_t053_pair(self) -> None:
        contract = self.attested_t053_contract()
        validated = board_contract.validate_contract(contract, "T-20260920-053")
        self.assertEqual(validated["hardware"]["initial_chain_policy"], "user_attested_flash_boot")

    def test_user_attested_flash_boot_policy_rejects_other_task(self) -> None:
        contract = self.attested_t053_contract()
        contract["task_id"] = "T-20260920-054"
        contract["remote"]["task_root"] = "D:/Projects/fpga-altra/lcvex/build/T-20260920-054-board"
        contract["remote"]["bootstrap_path"] = "D:/Projects/fpga-altra/lcvex/build/T-20260920-054-prepare.ps1"
        with self.assertRaisesRegex(board_contract.ContractError, "reserved for T-053"):
            board_contract.validate_contract(contract)

    def test_user_attested_flash_boot_policy_rejects_missing_or_wrong_attestation(self) -> None:
        contract = self.attested_t053_contract()
        del contract["hardware"]["initial_state_attestation"]
        with self.assertRaisesRegex(board_contract.ContractError, "fixed Flash boot attestation"):
            board_contract.validate_contract(contract, "T-20260920-053")
        contract = self.attested_t053_contract()
        contract["hardware"]["initial_state_attestation"] = "some-other-image"
        with self.assertRaisesRegex(board_contract.ContractError, "fixed Flash boot attestation"):
            board_contract.validate_contract(contract, "T-20260920-053")

    def test_user_attested_flash_boot_policy_rejects_changed_candidate_or_golden(self) -> None:
        contract = self.attested_t053_contract()
        contract["candidate"]["sha256"] = "0" * 64
        with self.assertRaisesRegex(board_contract.ContractError, "frozen T-053 candidate/golden"):
            board_contract.validate_contract(contract, "T-20260920-053")
        contract = self.attested_t053_contract()
        contract["golden"]["design_hash"] = "0" * 20
        with self.assertRaisesRegex(board_contract.ContractError, "frozen T-053 candidate/golden"):
            board_contract.validate_contract(contract, "T-20260920-053")

    def test_default_policy_remains_golden_hash_required(self) -> None:
        self.assertNotIn("initial_chain_policy", self.contract["hardware"])
        validated = board_contract.validate_contract(self.contract, "T-20990101-001")
        self.assertEqual(
            validated["hardware"].get("initial_chain_policy", board_contract.INITIAL_CHAIN_DEFAULT),
            "require_golden_design_hash",
        )

    def test_default_and_attested_preflight_branches_remain_explicit(self) -> None:
        preflight = (TOOLS / "preflight.ps1").read_text(encoding="utf-8")
        common = (TOOLS / "contract_common.ps1").read_text(encoding="utf-8")
        self.assertIn("require_golden_design_hash", common)
        self.assertIn("user_attested_flash_boot", common)
        self.assertIn("T-20260920-053", common)
        self.assertIn("user_confirmed_flash_boot_vexriscv_linux", common)
        self.assertIn("$initialChainPolicy -eq 'user_attested_flash_boot'", preflight)
        self.assertIn("$goldenHashReported", preflight)
        self.assertIn("INITIAL_DESIGN_HASH_ROLE=DIAGNOSTIC_ONLY_NOT_LIVE_IDENTITY", preflight)
        self.assertIn("$cableOk", preflight)
        self.assertIn("$jtagOk", preflight)
        self.assertIn("$nodesOk", preflight)

    def test_empty_terminal_steps_fails(self) -> None:
        self.reject(lambda value: value["terminal"].__setitem__("steps", []))

    def test_repeated_step_without_accept_regex_fails(self) -> None:
        self.reject(lambda value: value["terminal"]["steps"][0].__setitem__("max_attempts", 2))

    def test_bad_terminal_regex_fails(self) -> None:
        self.reject(lambda value: value["terminal"]["steps"][0].__setitem__("response_regex", "("))

    def test_remote_path_injection_fails(self) -> None:
        self.reject(lambda value: value["remote"].__setitem__("task_root", "D:/safe/\" & whoami"))

    def test_remote_host_option_injection_fails(self) -> None:
        self.reject(lambda value: value["remote"].__setitem__("host", "-oProxyCommand=bad"))

    def test_cli_does_not_contact_remote(self) -> None:
        completed = subprocess.run(
            [sys.executable, str(TOOLS / "validate_contract.py"), "--contract", str(EXAMPLE), "--task-id", "T-20990101-001"],
            check=False,
            text=True,
            capture_output=True,
        )
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertIn('"result": "PASS"', completed.stdout)

    def test_seal_binds_contract(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "manifest.json"
            completed = subprocess.run(
                [
                    sys.executable,
                    str(TOOLS / "seal_manifest.py"),
                    "--task-id",
                    "T-20990101-001",
                    "--contract",
                    str(EXAMPLE),
                    "--output",
                    str(output),
                ],
                check=False,
                text=True,
                capture_output=True,
            )
            self.assertEqual(completed.returncode, 0, completed.stderr)
            manifest = json.loads(output.read_text(encoding="utf-8"))
            entries = {entry["name"]: entry for entry in manifest["files"]}
            self.assertEqual(len(entries), 12)
            self.assertIn("board-contract.json", entries)
            self.assertEqual(entries["board-contract.json"]["source"], str(EXAMPLE.resolve()))

    def test_operational_sources_have_no_t030_identity(self) -> None:
        forbidden = (
            "T-20260920-030-b25-logic-imm-repair-volatile-sof",
            "bb292699cced5ba988c20b852914c2478f6ef2e5385695e299558bbc582fd264",
        )
        for name in (
            "preflight.ps1",
            "program_once.ps1",
            "postflight.ps1",
            "direct_terminal.py",
            "run_board_once.sh",
        ):
            text = (TOOLS / name).read_text(encoding="utf-8")
            for token in forbidden:
                self.assertNotIn(token, text, f"{name} still embeds frozen candidate identity")

    def test_invalid_contract_stops_before_remote(self) -> None:
        value = copy.deepcopy(self.contract)
        value["policy"]["allow_power_cycle"] = True
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            contract = root / "invalid.json"
            contract.write_text(json.dumps(value), encoding="utf-8")
            fakebin = root / "fakebin"
            fakebin.mkdir()
            marker = root / "remote-called"
            for command in ("ssh", "scp"):
                shim = fakebin / command
                shim.write_text(f"#!/bin/sh\ntouch '{marker}'\nexit 99\n", encoding="utf-8")
                shim.chmod(0o755)
            environment = dict(os.environ)
            environment["PATH"] = str(fakebin) + os.pathsep + environment["PATH"]
            completed = subprocess.run(
                [
                    "bash",
                    str(TOOLS / "run_board_once.sh"),
                    str(contract),
                    str(root / "output"),
                    "negative",
                ],
                check=False,
                text=True,
                capture_output=True,
                env=environment,
            )
            self.assertEqual(completed.returncode, 2, completed.stdout + completed.stderr)
            self.assertFalse(marker.exists(), "invalid contract reached ssh/scp")

    def test_no_broad_process_termination_source(self) -> None:
        text = (TOOLS / "program_once.ps1").read_text(encoding="utf-8")
        self.assertNotIn("Stop-Process -Name", text)
        self.assertNotIn("Get-Process jtagserver | Stop-Process", text)
        self.assertIn("Stop-Process -Id $script:ownedServer.Id", text)


if __name__ == "__main__":
    unittest.main()
