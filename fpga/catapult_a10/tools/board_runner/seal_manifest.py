#!/usr/bin/env python3
"""Create a deterministic per-file seal for one parameterized runner bundle."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
from pathlib import Path

from validate_contract import load_contract


FILES = (
    "contract_common.ps1",
    "prepare_task_root.ps1",
    "validate_scripts.ps1",
    "verify_seal.ps1",
    "preflight.ps1",
    "program_once.ps1",
    "postflight.ps1",
    "direct_terminal.py",
    "run_board_once.sh",
    "seal_manifest.py",
    "validate_contract.py",
)
TASK_RE = re.compile(r"^T-[0-9]{8}-[0-9]{3}$")


def digest(path: Path) -> tuple[int, str]:
    data = path.read_bytes()
    return len(data), hashlib.sha256(data).hexdigest()


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--task-id", required=True)
    parser.add_argument("--tools-root", type=Path, default=Path(__file__).resolve().parent)
    parser.add_argument("--contract", required=True, type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    if not TASK_RE.fullmatch(args.task_id):
        parser.error("task ID must match T-YYYYMMDD-NNN")
    if args.output is None:
        args.output = args.tools_root.parent / "script-manifest.json"
    return args


def main() -> int:
    args = parse_args()
    contract = load_contract(args.contract, args.task_id)
    entries = []
    for name in FILES:
        path = args.tools_root / name
        if not path.is_file():
            raise SystemExit(f"missing bundle file before seal: {path}")
        size, sha256 = digest(path)
        entries.append({"name": name, "bytes": size, "sha256": sha256, "remote": True})
    contract_path = args.contract.resolve()
    contract_size, contract_sha256 = digest(contract_path)
    entries.append(
        {
            "name": "board-contract.json",
            "source": str(contract_path),
            "bytes": contract_size,
            "sha256": contract_sha256,
            "remote": True,
        }
    )
    manifest = {
        "schema_version": 2,
        "task_id": args.task_id,
        "contract_id": contract["contract_id"],
        "contract_sha256": contract_sha256,
        "files": entries,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(json.dumps(manifest, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
