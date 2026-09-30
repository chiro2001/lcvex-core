#!/usr/bin/env python3
"""Run synthetic and fault-injection tests for the B25 inventory exporter.

The fixture is generated entirely below ``build/``.  It contains no QDB or
Quartus output and is deliberately small in structure while retaining the
T-007 report grammar, exact row cardinalities, and the reserved TDI->TDO
loopback edge observed in the real report.  Every case invokes the exporter
from its own output directory and the positive case is then passed through the
T-010 checker.
"""

from __future__ import annotations

import json
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Any


REPO = Path(__file__).resolve().parents[3]
EXPORTER = REPO / "fpga/catapult_a10/tools/export_physical_waiver_inventory.py"
CHECKER = REPO / "fpga/catapult_a10/tools/check_physical_waivers.py"
POLICY = REPO / "fpga/catapult_a10/physical_waivers.json"
DEFAULT_ROOT = REPO / "build/agents/T-20260909-012/physical-inventory-fixture"
SOURCE_SHA = "702bd8ee5295efe8a2ad9e094d6c12471a1d3089"
RESET_NAME = "soc|emif_adapter|emif_rst_sync1_n"


def _policy() -> dict[str, Any]:
    return json.loads(POLICY.read_text(encoding="utf-8"))


def _semicolon(fields: list[str]) -> str:
    return "; " + " ; ".join(fields) + " ;\n"


def _ucp_report(policy: dict[str, Any]) -> str:
    clocks = [item["name"] for item in policy["ucp"]["clocks"]]
    ports = policy["ucp"]["ports"]
    input_rows: list[tuple[str, str]] = []
    input_rows.extend(
        (
            "altera_reserved_tdi",
            f"jtag_uart_inst|jtag_uart|alt_jtag_atlantic|td_shift[{index}]",
        )
        for index in range(7)
    )
    input_rows.extend(
        (
            "altera_reserved_tdi",
            f"auto_fab_0|alt_sld_fab_0|sldfabric|node[{index}]",
        )
        for index in range(11)
    )
    input_rows.extend(
        (
            "altera_reserved_tdi",
            f"emif|emif_bot|col_if|jtag_phy_embedded_in_jtag_master|data[{index}]",
        )
        for index in range(7)
    )
    input_rows.append(("altera_reserved_tdi", "altera_reserved_tdo"))
    input_rows.extend(
        (
            "altera_reserved_tms",
            f"auto_fab_0|alt_sld_fab_0|sldfabric|tms[{index}]",
        )
        for index in range(37)
    )
    output_rows = [
        ("auto_fab_0|alt_sld_fab_0|jtagpins|tdo[0]", "altera_reserved_tdo"),
        ("auto_fab_0|alt_sld_fab_0|jtagpins|tdo[1]", "altera_reserved_tdo"),
        ("auto_fab_0|alt_sld_fab_0|jtagpins|tdo[2]", "altera_reserved_tdo"),
        ("altera_reserved_tdi", "altera_reserved_tdo"),
    ]
    summary = {
        "Illegal Clocks": 0,
        "Unconstrained Clocks": len(clocks),
        "Unconstrained Input Ports": sum(item["direction"] == "input" for item in ports),
        "Unconstrained Input Port Paths": len(input_rows),
        "Unconstrained Output Ports": sum(item["direction"] == "output" for item in ports),
        "Unconstrained Output Port Paths": len(output_rows),
    }
    lines = [
        "+---------------------+\n",
        "; Unconstrained Paths ;\n",
        "+---------------------+\n",
        "; Unconstrained Paths Summary                    ;\n",
        "; Property                        ; Setup ; Hold ;\n",
    ]
    for name, value in summary.items():
        lines.append(_semicolon([name, str(value), str(value)]))
    lines.extend(
        [
            "; Clock Status Summary ;\n",
            "; Target ; Clock ; Type ; Status ;\n",
        ]
    )
    for name in clocks:
        lines.append(_semicolon([name, "", "Base", "Unconstrained"]))
    for analysis in ("Setup", "Hold"):
        lines.extend(
            [
                f"; {analysis} Analysis ;\n",
                "; Unconstrained Input Ports ;\n",
                "; Input Port ; Comment ;\n",
            ]
        )
        for port in ports:
            if port["direction"] == "input":
                lines.append(_semicolon([port["name"], "No input delay, min/max delays, false-path exceptions, or max skew assignments found"]))
        lines.extend(
            [
                "; Unconstrained Output Ports ;\n",
                "; Output Port ; Comment ;\n",
            ]
        )
        for port in ports:
            if port["direction"] == "output":
                lines.append(_semicolon([port["name"], "No output delay, min/max delays, false-path exceptions, or max skew assignments found"]))
        lines.extend(
            [
                "; Unconstrained Input Port Paths ;\n",
                "; From ; To ; To Clocks ;\n",
            ]
        )
        for source, destination in input_rows:
            lines.append(_semicolon([source, destination, ""]))
        lines.extend(
            [
                "; Unconstrained Output Port Paths ;\n",
                "; From ; To ; From Clocks ;\n",
            ]
        )
        for source, destination in output_rows:
            lines.append(_semicolon([source, destination, ""]))
    return "".join(lines)


def _timing_report(policy: dict[str, Any], kind: str, baseline: float) -> str:
    count = policy["reset_control"]["checks"][kind]["path_count"]
    lines = [
        "----------------\n",
        "; Command Info ;\n",
        "----------------\n",
        f"Report Timing: Found {count} {kind} paths (0 violated).  Worst case slack is {baseline:.3f} \n",
        "\n",
        "Tcl Command:\n",
        f"    report_timing -{kind} -file fixture.rpt -from [get_registers {{{RESET_NAME}}}] -to [get_registers {{soc|emif_adapter|*}}] -npaths 1000 -detail full_path\n",
        "\n",
        "+----------------+\n",
        "; Summary of Paths ;\n",
        "+----------------+\n",
        "; Slack ; From Node ; To Node ; Launch Clock ; Latch Clock ; Relationship ; Clock Skew ; Data Delay ; Worst-Case Operating Conditions ;\n",
        "+----------------+\n",
    ]
    for index in range(count):
        slack = baseline + index / 1000.0
        lines.append(
            _semicolon(
                [
                    f"{slack:.3f}",
                    RESET_NAME,
                    f"soc|emif_adapter|emif_req_q.writedata[{index}]",
                    "emif|emif_bot|emif_bot_core_usr_clk",
                    "emif|emif_bot|emif_bot_core_usr_clk",
                    "3.750",
                    "0.000",
                    "1.000",
                    "Synthetic 900mV 0C Model",
                ]
            )
        )
    lines.append("+----------------+\n")
    return "".join(lines)


def _summary(policy: dict[str, Any], names: dict[str, str]) -> str:
    reset_count = policy["reset_control"]["checks"]["recovery"]["path_count"]
    recovery_min = policy["reset_control"]["checks"]["recovery"]["baseline_worst_slack_ns"]
    removal_min = policy["reset_control"]["checks"]["removal"]["baseline_worst_slack_ns"]
    lines = [
        "# task=T-20260909-007\n",
        "# label=B25-UNCONSTRAINED-CLOCK-AUDIT\n",
        f"# fitted_source_sha={SOURCE_SHA}\n",
        "# report_only=true; synthesis_rerun=false; fitter_rerun=false; assembler=false\n",
        "# columns=kind|model|label|value1|value2|value3|value4\n",
    ]
    for model in ("fast", "slow"):
        lines.extend(
            [
                f"report|{model}|clocks|ok|t007_{model}_clocks.rpt||\n",
                f"report|{model}|unconstrained_paths|ok|{names[f'ucp_{model}']}||\n",
                f"report|{model}|exceptions|ok|t007_{model}_exceptions.rpt||\n",
                f"report|{model}|emif_reset_to_adapter_recovery|ok|{names[f'{model}_recovery']}||\n",
                f"report|{model}|emif_reset_to_adapter_removal|ok|{names[f'{model}_removal']}||\n",
            ]
        )
        for port in ("tdi", "tms", "tdo"):
            for mode in ("max", "min"):
                label = f"reserved_{port}_paths_{mode}"
                lines.extend(
                    [
                        f"report|{model}|{label}|ok|t007_{model}_{label}.rpt||\n",
                        f"paths|{model}|{label}|ok|{mode}|0|\n",
                        f"path_iter|{model}|{label}|error|||\n",
                    ]
                )
        lines.extend(
            [
                f"reset_report|{model}|emif_reset|recovery|no_clock|t007_{model}_emif_reset_recovery.rpt|\n",
                f"reset_report|{model}|emif_reset|removal|no_clock|t007_{model}_emif_reset_removal.rpt|\n",
                f"reset_target_inventory|{model}|emif_reset|1|5462|0|\n",
            ]
        )
        for kind, baseline in (("recovery", recovery_min), ("removal", removal_min)):
            label = f"emif_reset_to_adapter_{kind}"
            for index in range(reset_count):
                slack = baseline + index / 1000.0
                lines.append(
                    f"path|{model}|{label}|{index}|_quartus_sta_node__source|_quartus_sta_node__{index}|_quartus_sta_clock__6\n"
                )
                lines.append(
                    f"path_detail|{model}|{label}|{index}|_quartus_sta_clock__6|{slack:.3f}|{kind}\n"
                )
            lines.append(f"paths|{model}|{label}|ok|{kind}|{reset_count}|\n")
            lines.append(f"path_iter|{model}|{label}|error|||\n")
    lines.append("done|2026-09-09T12:23:07+0800||||\n")
    return "".join(lines)


def _make_fixture(root: Path) -> dict[str, Path]:
    policy = _policy()
    root.mkdir(parents=True, exist_ok=True)
    names = {
        "ucp_fast": "t007_fast_unconstrained_paths.rpt",
        "ucp_slow": "t007_slow_unconstrained_paths.rpt",
        "fast_recovery": "t007_fast_emif_reset_to_adapter_recovery.rpt",
        "fast_removal": "t007_fast_emif_reset_to_adapter_removal.rpt",
        "slow_recovery": "t007_slow_emif_reset_to_adapter_recovery.rpt",
        "slow_removal": "t007_slow_emif_reset_to_adapter_removal.rpt",
    }
    for key in ("ucp_fast", "ucp_slow"):
        (root / names[key]).write_text(_ucp_report(policy), encoding="utf-8")
    (root / names["fast_recovery"]).write_text(
        _timing_report(policy, "recovery", 1.202), encoding="utf-8"
    )
    (root / names["slow_recovery"]).write_text(
        _timing_report(policy, "recovery", 1.202), encoding="utf-8"
    )
    (root / names["fast_removal"]).write_text(
        _timing_report(policy, "removal", 0.191), encoding="utf-8"
    )
    (root / names["slow_removal"]).write_text(
        _timing_report(policy, "removal", 0.191), encoding="utf-8"
    )
    (root / "t007_summary.tsv").write_text(_summary(policy, names), encoding="utf-8")
    return {key: root / value for key, value in names.items()} | {"summary": root / "t007_summary.tsv"}


def _command(paths: dict[str, Path], output: Path) -> list[str]:
    return [
        sys.executable,
        str(EXPORTER),
        "--policy",
        str(POLICY),
        "--summary",
        str(paths["summary"]),
        "--ucp-fast",
        str(paths["ucp_fast"]),
        "--ucp-slow",
        str(paths["ucp_slow"]),
        "--fast-recovery",
        str(paths["fast_recovery"]),
        "--fast-removal",
        str(paths["fast_removal"]),
        "--slow-recovery",
        str(paths["slow_recovery"]),
        "--slow-removal",
        str(paths["slow_removal"]),
        "--output",
        str(output),
    ]


def _run(command: list[str], cwd: Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(command, cwd=cwd, capture_output=True, text=True, check=False)


def _faults(base: Path, paths: dict[str, Path]) -> dict[str, tuple[str, dict[str, Path]]]:
    cases: dict[str, tuple[str, dict[str, Path]]] = {}

    def copy_case(name: str) -> tuple[Path, dict[str, Path]]:
        case_root = base / name
        shutil.copytree(base / "positive-input", case_root)
        case_paths = {key: case_root / path.name for key, path in paths.items()}
        return case_root, case_paths

    case_root, case_paths = copy_case("missing-report")
    case_paths["ucp_slow"] = case_root / "missing.rpt"
    cases["missing-report"] = ("missing raw UCP report", case_paths)

    case_root, case_paths = copy_case("missing-ucp-row")
    target = case_paths["ucp_fast"]
    text = target.read_text(encoding="utf-8")
    row = "; altera_reserved_tms ; auto_fab_0|alt_sld_fab_0|sldfabric|tms[36] ;  ;\n"
    target.write_text(text.replace(row, "", 1), encoding="utf-8")
    cases["missing-ucp-row"] = ("missing one UCP row", case_paths)

    case_root, case_paths = copy_case("malformed-summary")
    target = case_paths["summary"]
    target.write_text(
        target.read_text(encoding="utf-8").replace(
            "# columns=kind|model|label|value1|value2|value3|value4",
            "# columns=kind|model|label|value1|value2",
            1,
        ),
        encoding="utf-8",
    )
    cases["malformed-summary"] = ("malformed summary header", case_paths)

    case_root, case_paths = copy_case("duplicate-key")
    target = case_paths["summary"]
    text = target.read_text(encoding="utf-8")
    target.write_text(text.replace("# task=T-20260909-007\n", "# task=T-20260909-007\n# task=T-20260909-007\n", 1), encoding="utf-8")
    cases["duplicate-key"] = ("duplicate summary header key", case_paths)

    for name in ("extra-ucp-clock", "extra-ucp-port"):
        case_root, case_paths = copy_case(name)
        for key in ("ucp_fast", "ucp_slow"):
            target = case_paths[key]
            text = target.read_text(encoding="utf-8")
            if name == "extra-ucp-clock":
                text = text.replace(
                    "; Clock Status Summary ;\n; Target ; Clock ; Type ; Status ;\n",
                    "; Clock Status Summary ;\n; Target ; Clock ; Type ; Status ;\n; user_debug_clk ;  ; Base ; Unconstrained ;\n",
                    1,
                )
            else:
                text = text.replace(
                    "; Input Port ; Comment ;\n",
                    "; Input Port ; Comment ;\n; user_debug_tap ; No input delay ;\n",
                    1,
                )
            target.write_text(text, encoding="utf-8")
        cases[name] = ("extra unconstrained UCP object", case_paths)

    case_root, case_paths = copy_case("ucp-clock-period-create-clock")
    for key in ("ucp_fast", "ucp_slow"):
        target = case_paths[key]
        text = target.read_text(encoding="utf-8")
        text = text.replace(
            "; altera_reserved_tck ;  ; Base ; Unconstrained ;",
            "; altera_reserved_tck ; create_clock -period 10 ; Base ; Unconstrained ;",
            1,
        )
        target.write_text(text, encoding="utf-8")
    cases["ucp-clock-period-create-clock"] = (
        "non-empty raw UCP Clock field with period/create_clock text",
        case_paths,
    )

    case_root, case_paths = copy_case("ucp-unknown-summary-row")
    target = case_paths["ucp_fast"]
    text = target.read_text(encoding="utf-8")
    text = text.replace(
        "; Clock Status Summary ;\n",
        "; Unexpected UCP Property ; 1 ; 1 ;\n; Clock Status Summary ;\n",
        1,
    )
    target.write_text(text, encoding="utf-8")
    cases["ucp-unknown-summary-row"] = ("unknown non-decorative UCP summary row", case_paths)

    case_root, case_paths = copy_case("count-drift")
    target = case_paths["fast_recovery"]
    target.write_text(
        target.read_text(encoding="utf-8").replace(
            "Report Timing: Found 627 recovery paths", "Report Timing: Found 626 recovery paths", 1
        ),
        encoding="utf-8",
    )
    cases["count-drift"] = ("timing header count drift", case_paths)

    case_root, case_paths = copy_case("source-sha-mismatch")
    target = case_paths["summary"]
    target.write_text(
        target.read_text(encoding="utf-8").replace(SOURCE_SHA, "0123456789abcdef0123456789abcdef01234567", 1),
        encoding="utf-8",
    )
    cases["source-sha-mismatch"] = ("frozen source SHA mismatch", case_paths)

    case_root, case_paths = copy_case("missing-summary-row")
    target = case_paths["summary"]
    text = target.read_text(encoding="utf-8")
    target.write_text(text.replace("path_detail|fast|emif_reset_to_adapter_recovery|626|", "", 1), encoding="utf-8")
    cases["missing-summary-row"] = ("missing summary path_detail row", case_paths)

    case_root, case_paths = copy_case("duplicate-ucp-row")
    for key in ("ucp_fast", "ucp_slow"):
        target = case_paths[key]
        text = target.read_text(encoding="utf-8")
        row = "; altera_reserved_tms ; auto_fab_0|alt_sld_fab_0|sldfabric|tms[36] ;  ;\n"
        target.write_text(text.replace(row, row + row, 1), encoding="utf-8")
    cases["duplicate-ucp-row"] = ("duplicate UCP path key", case_paths)

    case_root, case_paths = copy_case("timing-tail-path-row")
    target = case_paths["fast_recovery"]
    target.write_text(
        target.read_text(encoding="utf-8")
        + _semicolon(
            [
                "9.999",
                RESET_NAME,
                "soc|emif_adapter|extra_tail_path",
                "emif|emif_bot|emif_bot_core_usr_clk",
                "emif|emif_bot|emif_bot_core_usr_clk",
                "3.750",
                "0.000",
                "1.000",
                "Synthetic 900mV 0C Model",
            ]
        ),
        encoding="utf-8",
    )
    cases["timing-tail-path-row"] = ("extra timing path after table separator", case_paths)
    return cases


def main(argv: list[str] | None = None) -> int:
    del argv
    import argparse

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-dir", type=Path, default=DEFAULT_ROOT)
    args = parser.parse_args()
    root = args.output_dir.resolve()
    positive_root = root / "positive-input"
    positive_root.mkdir(parents=True, exist_ok=True)
    paths = _make_fixture(positive_root)
    positive_output = root / "positive-inventory.json"
    positive = _run(_command(paths, positive_output), root)
    (root / "positive-export.stdout.log").write_text(positive.stdout, encoding="utf-8")
    (root / "positive-export.stderr.log").write_text(positive.stderr, encoding="utf-8")
    if positive.returncode != 0:
        raise AssertionError("synthetic positive export failed")
    checker = _run(
        [
            sys.executable,
            str(CHECKER),
            "--policy",
            str(POLICY),
            "--inventory",
            str(positive_output),
            "--json",
        ],
        root,
    )
    (root / "positive-checker.stdout.json").write_text(checker.stdout, encoding="utf-8")
    (root / "positive-checker.stderr.log").write_text(checker.stderr, encoding="utf-8")
    if checker.returncode != 0:
        raise AssertionError("synthetic positive inventory failed T-010 checker")

    outcomes: dict[str, int] = {}
    descriptions: dict[str, str] = {}
    for name, (description, case_paths) in _faults(root, paths).items():
        case_root = next(iter(case_paths.values())).parent
        output = case_root / "inventory.json"
        result = _run(_command(case_paths, output), case_root)
        outcomes[name] = result.returncode
        descriptions[name] = description
        (case_root / "export.stdout.log").write_text(result.stdout, encoding="utf-8")
        (case_root / "export.stderr.log").write_text(result.stderr, encoding="utf-8")
        if result.returncode == 0:
            raise AssertionError(f"negative fixture was accepted: {name}")

    result = {"positive_export": "PASS", "positive_checker": "PASS", "negative": outcomes, "descriptions": descriptions}
    (root / "matrix.json").write_text(json.dumps(result, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(json.dumps(result, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
