#!/usr/bin/env python3
"""Validate an exported B25 v2 normalized physical waiver inventory."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Sequence

from export_physical_waiver_invariant_inventory import (
    InvariantError,
    _load_json,
    _policy,
    validate_inventory,
)


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--policy", type=Path, default=Path(__file__).resolve().parents[1] / "physical_waivers_invariant.json")
    parser.add_argument("--inventory", type=Path, required=True)
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--allow-fixture-policy", action="store_true", help=argparse.SUPPRESS)
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    try:
        policy = _policy(args.policy.resolve(), args.allow_fixture_policy)
        inventory = _load_json(args.inventory.resolve(), "invariant inventory")
        result = validate_inventory(policy, inventory)
    except (InvariantError, TypeError, KeyError, ValueError) as exc:
        result = {"schema_version": 2, "status": "FAIL", "errors": [str(exc)]}
        if args.json:
            print(json.dumps(result, indent=2, sort_keys=True))
        else:
            print("PHYSICAL_WAIVER_INVARIANT_CHECK_FAIL", file=sys.stderr)
            print(f"- {exc}", file=sys.stderr)
        return 1
    output = {"schema_version": 2, **result}
    if args.json:
        print(json.dumps(output, indent=2, sort_keys=True))
    else:
        print("PHYSICAL_WAIVER_INVARIANT_CHECK_PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
