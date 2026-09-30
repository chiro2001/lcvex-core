#!/usr/bin/env python3
"""Run the B25 physical-waiver checker against task-local synthetic data.

The fixtures are deliberately generated below ``build/`` so no Quartus,
database, DUT output, network, or release artifact is involved.  A subprocess
is launched from the fixture directory to prove that the checker is
independent of the caller's current directory.
"""

from __future__ import annotations

import argparse
import copy
import json
import subprocess
import sys
from pathlib import Path


REPO = Path(__file__).resolve().parents[3]
CHECKER = REPO / "fpga/catapult_a10/tools/check_physical_waivers.py"
POLICY = REPO / "fpga/catapult_a10/physical_waivers.json"
DEFAULT_OUTPUT = REPO / "build/agents/T-20260909-010/physical-waivers-fixture"


def _inventory() -> dict[str, object]:
    return {
        "schema_version": 1,
        "inventory_kind": "lcvex-physical-ucp-recovery-removal-v1",
        "provenance": {
            "source_task": "T-20260909-007",
            "source_sha": "702bd8ee5295efe8a2ad9e094d6c12471a1d3089",
            "exporter": "quartus_sta_structured_inventory_v1",
        },
        "ucp": {
            "summary": {
                "clock_count": 2,
                "input_port_count": 2,
                "input_path_count": 63,
                "output_port_count": 1,
                "output_path_count": 4,
            },
            "clocks": [
                {
                    "name": "altera_reserved_tck",
                    "status": "unconstrained",
                    "kind": "vendor_generated_jtag_clock",
                },
                {
                    "name": "soc|emif_adapter|emif_rst_sync1_n",
                    "status": "unconstrained",
                    "kind": "synchronized_reset_control",
                },
            ],
            "ports": [
                {
                    "name": "altera_reserved_tdi",
                    "direction": "input",
                    "path_count": 26,
                    "path_groups": {
                        "jtag_uart_alt_jtag_atlantic": {
                            "count": 7,
                            "hierarchy": "jtag_uart_inst|jtag_uart|alt_jtag_atlantic|sink",
                        },
                        "auto_fab_sld": {
                            "count": 11,
                            "hierarchy": "auto_fab_0|alt_sld_fab_0|jtagpins|atom_inst",
                        },
                        "emif_embedded_jtag": {
                            "count": 7,
                            "hierarchy": "emif|emif_bot|col_if|jtag_phy_embedded_in_jtag_master|data",
                        },
                        "reserved_jtag_port": {
                            "count": 1,
                            "hierarchy": "reserved_jtag_port|altera_reserved_tdo",
                        },
                    },
                },
                {
                    "name": "altera_reserved_tms",
                    "direction": "input",
                    "path_count": 37,
                    "path_groups": {
                        "auto_fab_sld": {
                            "count": 37,
                            "hierarchy": "auto_fab_0|alt_sld_fab_0|jtagpins|tms",
                        },
                    },
                },
                {
                    "name": "altera_reserved_tdo",
                    "direction": "output",
                    "path_count": 4,
                    "path_groups": {
                        "auto_fab_sld": {
                            "count": 4,
                            "hierarchy": "auto_fab_0|alt_sld_fab_0|jtagpins|tdo",
                        },
                    },
                },
            ],
        },
        "recovery_removal": {
            "reset_control": "soc|emif_adapter|emif_rst_sync1_n",
            "kind": "synchronized_active_low_reset_control",
            "corners": {
                "fast": {
                    "recovery": {
                        "path_count": 627,
                        "violated": 0,
                        "worst_slack_ns": 1.202,
                    },
                    "removal": {
                        "path_count": 627,
                        "violated": 0,
                        "worst_slack_ns": 0.191,
                    },
                },
                "slow": {
                    "recovery": {
                        "path_count": 627,
                        "violated": 0,
                        "worst_slack_ns": 1.202,
                    },
                    "removal": {
                        "path_count": 627,
                        "violated": 0,
                        "worst_slack_ns": 0.191,
                    },
                },
            },
        },
        "clock_constraints": [],
        "exceptions": [],
    }


def _mutations(base: dict[str, object]) -> dict[str, dict[str, object]]:
    cases: dict[str, dict[str, object]] = {}

    value = copy.deepcopy(base)
    value["ucp"]["clocks"].append(
        {
            "name": "user_debug_clk",
            "status": "unconstrained",
            "kind": "user_functional_clock",
        }
    )
    cases["extra-user-clock"] = value

    value = copy.deepcopy(base)
    value["ucp"]["ports"].append(
        {
            "name": "user_debug_tap",
            "direction": "input",
            "path_count": 1,
            "path_groups": {},
        }
    )
    cases["extra-user-port"] = value

    value = copy.deepcopy(base)
    value["ucp"]["ports"][0]["path_groups"]["user_logic"] = {
        "count": 1,
        "hierarchy": "soc|user_logic|debug_tap",
    }
    cases["extra-user-path"] = value

    value = copy.deepcopy(base)
    value["ucp"]["summary"]["input_path_count"] = 62
    cases["input-path-count-change"] = value

    value = copy.deepcopy(base)
    del value["ucp"]["ports"][0]["path_groups"]["emif_embedded_jtag"]
    cases["missing-emif-vendor-hierarchy"] = value

    value = copy.deepcopy(base)
    del value["ucp"]["ports"][0]["path_groups"]["jtag_uart_alt_jtag_atlantic"]
    cases["missing-alt-jtag-hierarchy"] = value

    value = copy.deepcopy(base)
    del value["ucp"]["ports"][1]["path_groups"]["auto_fab_sld"]
    cases["missing-auto-fab-hierarchy"] = value

    value = copy.deepcopy(base)
    value["recovery_removal"]["corners"]["fast"]["recovery"]["path_count"] = 626
    cases["recovery-path-count-change"] = value

    value = copy.deepcopy(base)
    value["recovery_removal"]["corners"]["slow"]["removal"]["path_count"] = 628
    cases["removal-path-count-change"] = value

    value = copy.deepcopy(base)
    value["recovery_removal"]["corners"]["fast"]["recovery"]["worst_slack_ns"] = 0
    cases["zero-recovery-slack"] = value

    value = copy.deepcopy(base)
    value["recovery_removal"]["corners"]["slow"]["removal"]["worst_slack_ns"] = -0.001
    cases["negative-removal-slack"] = value

    value = copy.deepcopy(base)
    value["clock_constraints"].append(
        {
            "name": "altera_reserved_tck",
            "kind": "user_jtag_clock",
            "period_ns": 15.0,
        }
    )
    cases["arbitrary-jtag-period"] = value

    value = copy.deepcopy(base)
    value["exceptions"].append(
        {
            "type": "false_path",
            "from": "soc|emif_adapter|emif_rst_sync1_n",
            "to": "soc|emif_adapter|emif_req_q.*",
        }
    )
    cases["reset-false-path"] = value

    value = copy.deepcopy(base)
    value["provenance"]["source_sha"] = "0123456789abcdef0123456789abcdef01234567"
    cases["source-sha-mismatch"] = value

    value = copy.deepcopy(base)
    value["exceptions"].append(
        {
            "type": "multicycle_path",
            "from": "soc|debug_q",
            "to": "soc|trace_q",
        }
    )
    cases["unexpected-exception"] = value

    value = copy.deepcopy(base)
    value["ucp"]["clocks"][0]["kind"] = "user_functional_clock"
    cases["wrong-clock-kind"] = value

    value = copy.deepcopy(base)
    value["ucp"]["ports"][0]["direction"] = "output"
    cases["wrong-port-direction"] = value
    return cases


def _run(path: Path, output_dir: Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [
            sys.executable,
            str(CHECKER),
            "--policy",
            str(POLICY),
            "--inventory",
            str(path),
            "--json",
        ],
        cwd=output_dir,
        capture_output=True,
        text=True,
        check=False,
    )


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-dir", type=Path, default=DEFAULT_OUTPUT)
    args = parser.parse_args(argv)
    output_dir = args.output_dir.resolve()
    output_dir.mkdir(parents=True, exist_ok=True)

    base = _inventory()
    positive = output_dir / "ucp_inventory.pass.json"
    positive.write_text(
        json.dumps(base, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    result = _run(positive, output_dir)
    (output_dir / "positive.stdout.json").write_text(result.stdout, encoding="utf-8")
    (output_dir / "positive.stderr.log").write_text(result.stderr, encoding="utf-8")
    if result.returncode != 0:
        raise AssertionError("positive inventory was rejected")

    outcomes: dict[str, int] = {}
    mutations = _mutations(base)
    for case, fixture in mutations.items():
        path = output_dir / f"ucp_inventory.{case}.json"
        path.write_text(
            json.dumps(fixture, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
        result = _run(path, output_dir)
        outcomes[case] = result.returncode
        (output_dir / f"{case}.stdout.json").write_text(result.stdout, encoding="utf-8")
        (output_dir / f"{case}.stderr.log").write_text(result.stderr, encoding="utf-8")
        if result.returncode == 0:
            raise AssertionError(f"negative fixture was accepted: {case}")

    duplicate_key = output_dir / "ucp_inventory.duplicate-json-key.json"
    duplicate_key.write_text(
        json.dumps(base, indent=2, sort_keys=True).replace(
            '  "exceptions": [],',
            '  "exceptions": [],\n  "exceptions": [],',
            1,
        )
        + "\n",
        encoding="utf-8",
    )
    result = _run(duplicate_key, output_dir)
    outcomes["duplicate-json-key"] = result.returncode
    (output_dir / "duplicate-json-key.stdout.json").write_text(
        result.stdout, encoding="utf-8"
    )
    (output_dir / "duplicate-json-key.stderr.log").write_text(
        result.stderr, encoding="utf-8"
    )
    if result.returncode == 0:
        raise AssertionError("negative fixture was accepted: duplicate-json-key")

    print(json.dumps({"positive": "PASS", "negative": outcomes}, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
