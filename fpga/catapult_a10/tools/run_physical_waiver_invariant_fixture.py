#!/usr/bin/env python3
"""Exercise the v2 invariant exporter/checker with two duplicate selections.

The fixture is synthetic and task-local.  Its old/new inputs have different
raw fitter duplicates but identical normalized endpoint sets.  Fault cases
then prove that normalization cannot hide functional, hierarchy, timing,
clock, duplicate-shape, or provenance drift.
"""

from __future__ import annotations

import argparse
import copy
import hashlib
import json
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Any

from export_physical_waiver_invariant_inventory import (
    DUPLICATE_SUFFIX,
    POLICY_ID,
    _digest,
    _sorted_members,
)


REPO = Path(__file__).resolve().parents[3]
EXPORTER = REPO / "fpga/catapult_a10/tools/export_physical_waiver_invariant_inventory.py"
CHECKER = REPO / "fpga/catapult_a10/tools/check_physical_waiver_invariants.py"
PRODUCTION_POLICY = REPO / "fpga/catapult_a10/physical_waivers_invariant.json"
DEFAULT_ROOT = REPO / "build/agents/T-20260910-001/invariant-fixture"
RESET = "soc|emif_adapter|emif_rst_sync1_n"
CLOCK = "emif|emif_bot|emif_bot_core_usr_clk"


def _dump(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def _semicolon(fields: list[str]) -> str:
    return "; " + " ; ".join(fields) + " ;\n"


def _normalized_ucp_rows() -> tuple[list[tuple[str, str]], list[tuple[str, str]]]:
    inputs = [
        ("altera_reserved_tdi", "jtag_uart_inst|jtag_uart|fixture_alt_jtag_atlantic|node[0]"),
        ("altera_reserved_tdi", "auto_fab_0|alt_sld_fab_0|fixture|tdi[0]"),
        ("altera_reserved_tdi", "emif|emif_bot|fixture|jtag_phy_embedded_in_jtag_master|tdi[0]"),
        ("altera_reserved_tdi", "altera_reserved_tdo"),
        ("altera_reserved_tms", "auto_fab_0|alt_sld_fab_0|fixture|tms[0]"),
        ("altera_reserved_tms", "auto_fab_0|alt_sld_fab_0|fixture|tms[1]"),
    ]
    outputs = [
        ("auto_fab_0|alt_sld_fab_0|fixture|tdo[0]", "altera_reserved_tdo"),
        ("altera_reserved_tdi", "altera_reserved_tdo"),
    ]
    return inputs, outputs


def _normalized_reset_endpoints() -> list[str]:
    return sorted(
        [
            "soc|emif_adapter|emif_req_q.writedata[0]",
            "soc|emif_adapter|emif_req_q.writedata[1]",
            "soc|emif_adapter|emif_state_q.EMIF_WAIT_READ",
            "soc|emif_adapter|timeout_count_q[0]",
            "soc|emif_adapter|calibration_gate|fail_emif_latched_q",
        ]
    )


def _member_rows(rows: list[tuple[str, str]]) -> list[dict[str, str]]:
    return _sorted_members({"from": source, "to": destination, "clock": ""} for source, destination in rows)


def _fixture_policy(root: Path) -> tuple[dict[str, Any], dict[str, Any], dict[str, Path]]:
    policy = json.loads(PRODUCTION_POLICY.read_text(encoding="utf-8"))
    policy["policy_id"] = POLICY_ID + "-FIXTURE"
    inputs, outputs = _normalized_ucp_rows()
    tdi = _member_rows([row for row in inputs if row[0] == "altera_reserved_tdi"])
    tms = _member_rows([row for row in inputs if row[0] == "altera_reserved_tms"])
    tdo = _member_rows(outputs)
    port_values = {
        "altera_reserved_tdi": (tdi, {"jtag_uart_alt_jtag_atlantic": 1, "auto_fab_sld": 1, "emif_embedded_jtag": 1, "reserved_jtag_port": 1}),
        "altera_reserved_tms": (tms, {"auto_fab_sld": 2}),
        "altera_reserved_tdo": (tdo, {"auto_fab_sld": 1, "reserved_jtag_port": 1}),
    }
    policy["ucp"]["summary"]["input_path_count"] = len(inputs)
    policy["ucp"]["summary"]["output_path_count"] = len(outputs)
    for port in policy["ucp"]["ports"]:
        members, groups = port_values[port["name"]]
        port["normalized_path_count"] = len(members)
        port["path_groups"] = groups
        port["endpoint_digest"] = _digest(members)

    reset_members = _normalized_reset_endpoints()
    policy["reset_control"]["endpoint_digest"] = _digest(reset_members)
    family_values = {
        "emif_req_q": reset_members[1:3],
        "emif_state_q": ["soc|emif_adapter|emif_state_q.EMIF_WAIT_READ"],
        "timeout_count_q": ["soc|emif_adapter|timeout_count_q[0]"],
        "calibration_gate": ["soc|emif_adapter|calibration_gate|fail_emif_latched_q"],
    }
    # Avoid relying on lexical positions in the list above.
    family_values["emif_req_q"] = [value for value in reset_members if "|emif_req_q." in value]
    for family in policy["reset_control"]["families"]:
        members = sorted(family_values[family["name"]])
        family["normalized_path_count"] = len(members)
        family["endpoint_digest"] = _digest(members)
    for check in policy["reset_control"]["checks"].values():
        check["normalized_path_count"] = len(reset_members)

    profile = {
        "task_id": "T-FIXTURE",
        "candidate_sha": "1" * 40,
        "candidate_tree_sha": "2" * 40,
        "branch": "fixture/invariant",
        "worktree": "/fixture",
        "candidate_manifest": None,
        "user_sdc_sha256": "",
        "generated_sdc_sha256": "",
        "quartus": "Quartus Prime Pro 21.4.0 Build 67",
        "device": "10AX115N4F40E3SG",
        "report_only": True,
        "source_pre_manifest_sha256": "",
        "source_post_manifest_sha256": "",
    }
    measurement_root = root / "measurement"
    measurement_root.mkdir(parents=True, exist_ok=True)
    measurement_paths = {
        "user_sdc": measurement_root / "fixture-user.sdc",
        "generated_sdc": measurement_root / "fixture-generated.sdc",
        "source_pre_manifest": measurement_root / "fixture-source-pre.tsv",
        "source_post_manifest": measurement_root / "fixture-source-post.tsv",
    }
    measurement_paths["user_sdc"].write_text("create_clock -name fixture -period 40 [get_ports clk]\n", encoding="utf-8")
    measurement_paths["generated_sdc"].write_text("# generated fixture SDC\n", encoding="utf-8")
    measurement_paths["source_pre_manifest"].write_text("fixture\t1\tsha256\n", encoding="utf-8")
    measurement_paths["source_post_manifest"].write_text("fixture\t1\tsha256\n", encoding="utf-8")
    hash_fields = {
        "user_sdc": "user_sdc_sha256",
        "generated_sdc": "generated_sdc_sha256",
        "source_pre_manifest": "source_pre_manifest_sha256",
        "source_post_manifest": "source_post_manifest_sha256",
    }
    for label, path in measurement_paths.items():
        profile[hash_fields[label]] = hashlib.sha256(path.read_bytes()).hexdigest()
    policy["provenance"]["accepted_profiles"] = {"T-FIXTURE": {key: value for key, value in profile.items() if key != "task_id"}}
    policy["provenance"]["report_profiles"] = {}
    return policy, profile, measurement_paths


def _raw_ucp(mode: str) -> str:
    inputs, outputs = _normalized_ucp_rows()
    raw_inputs = list(inputs)
    if mode == "old":
        raw_inputs.extend(
            [
                ("altera_reserved_tdi", "auto_fab_0|alt_sld_fab_0|fixture|tdi[0]" + DUPLICATE_SUFFIX),
                ("altera_reserved_tms", "auto_fab_0|alt_sld_fab_0|fixture|tms[0]" + DUPLICATE_SUFFIX),
            ]
        )
    else:
        raw_inputs.append(("altera_reserved_tms", "auto_fab_0|alt_sld_fab_0|fixture|tms[1]" + DUPLICATE_SUFFIX))
    summary = {
        "Illegal Clocks": 0,
        "Unconstrained Clocks": 2,
        "Unconstrained Input Ports": 2,
        "Unconstrained Input Port Paths": len(raw_inputs),
        "Unconstrained Output Ports": 1,
        "Unconstrained Output Port Paths": len(outputs),
    }
    lines = [
        "+---------------------+\n",
        "; Unconstrained Paths ;\n",
        "+---------------------+\n",
        "; Unconstrained Paths Summary ;\n",
        "; Property ; Setup ; Hold ;\n",
    ]
    for name, value in summary.items():
        lines.append(_semicolon([name, str(value), str(value)]))
    lines.extend(
        [
            "; Clock Status Summary ;\n",
            "; Target ; Clock ; Type ; Status ;\n",
            _semicolon(["altera_reserved_tck", "", "Base", "Unconstrained"]),
            _semicolon([RESET, "", "Base", "Unconstrained"]),
        ]
    )
    for analysis in ("Setup", "Hold"):
        lines.extend(
            [
                f"; {analysis} Analysis ;\n",
                "; Unconstrained Input Ports ;\n",
                "; Input Port ; Comment ;\n",
                _semicolon(["altera_reserved_tdi", "No input delay or false path"]),
                _semicolon(["altera_reserved_tms", "No input delay or false path"]),
                "; Unconstrained Output Ports ;\n",
                "; Output Port ; Comment ;\n",
                _semicolon(["altera_reserved_tdo", "No output delay or false path"]),
                "; Unconstrained Input Port Paths ;\n",
                "; From ; To ; To Clocks ;\n",
            ]
        )
        lines.extend(_semicolon([source, destination, ""]) for source, destination in raw_inputs)
        lines.extend(["; Unconstrained Output Port Paths ;\n", "; From ; To ; From Clocks ;\n"])
        lines.extend(_semicolon([source, destination, ""]) for source, destination in outputs)
    return "".join(lines)


def _raw_reset_rows(mode: str) -> list[str]:
    rows = _normalized_reset_endpoints()
    if mode == "old":
        rows.extend(
            [
                "soc|emif_adapter|emif_state_q.EMIF_WAIT_READ" + DUPLICATE_SUFFIX,
                "soc|emif_adapter|timeout_count_q[0]" + DUPLICATE_SUFFIX,
            ]
        )
    else:
        rows.append("soc|emif_adapter|emif_req_q.writedata[1]" + DUPLICATE_SUFFIX)
    return rows


def _timing_report(kind: str, mode: str) -> tuple[str, list[float]]:
    endpoints = _raw_reset_rows(mode)
    slacks = [round((0.500 if kind == "recovery" else 0.200) + index * 0.010, 3) for index in range(len(endpoints))]
    lines = [
        "----------------\n",
        "; Command Info ;\n",
        "----------------\n",
        f"Report Timing: Found {len(endpoints)} {kind} paths (0 violated).  Worst case slack is {min(slacks):.3f}\n",
        "Tcl Command:\n",
        f"    report_timing -{kind} -from [get_registers {{{RESET}}}] -to [get_registers {{soc|emif_adapter|*}}] -npaths 1000 -detail full_path\n",
        "; Summary of Paths ;\n",
        "; Slack ; From Node ; To Node ; Launch Clock ; Latch Clock ; Relationship ; Clock Skew ; Data Delay ; Worst-Case Operating Conditions ;\n",
        "+----------------+\n",
    ]
    for slack, endpoint in zip(slacks, endpoints):
        lines.append(_semicolon([f"{slack:.3f}", RESET, endpoint, CLOCK, CLOCK, "3.750", "0.000", "1.000", "Slow 900mV 100C Model"]))
    lines.append("+----------------+\n")
    return "".join(lines), slacks


def _summary(mode: str, names: dict[str, str], slacks: dict[str, list[float]]) -> str:
    endpoints = _raw_reset_rows(mode)
    lines = [
        "# task=T-20260909-007\n",
        "# label=B25-UNCONSTRAINED-CLOCK-AUDIT\n",
        "# fitted_source_sha=702bd8ee5295efe8a2ad9e094d6c12471a1d3089\n",
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
            for bound in ("max", "min"):
                label = f"reserved_{port}_paths_{bound}"
                lines.extend([f"report|{model}|{label}|ok|t007_{model}_{label}.rpt||\n", f"paths|{model}|{label}|ok|{bound}|0|\n", f"path_iter|{model}|{label}|error|||\n"])
        lines.extend(
            [
                f"reset_report|{model}|emif_reset|recovery|no_clock|t007_{model}_emif_reset_recovery.rpt|\n",
                f"reset_report|{model}|emif_reset|removal|no_clock|t007_{model}_emif_reset_removal.rpt|\n",
                f"reset_target_inventory|{model}|emif_reset|1|{len(endpoints)}|0|\n",
            ]
        )
        for kind in ("recovery", "removal"):
            label = f"emif_reset_to_adapter_{kind}"
            for index, (endpoint, slack) in enumerate(zip(endpoints, slacks[kind])):
                lines.append(f"path|{model}|{label}|{index}|_source|_node_{index}|_clock\n")
                lines.append(f"path_detail|{model}|{label}|{index}|_clock|{slack:.3f}|{kind}\n")
            lines.extend([f"paths|{model}|{label}|ok|{kind}|{len(endpoints)}|\n", f"path_iter|{model}|{label}|error|||\n"])
    lines.append("done|2026-09-10T00:00:00+0800||||\n")
    return "".join(lines)


def _make_input(root: Path, mode: str) -> dict[str, Path]:
    root.mkdir(parents=True, exist_ok=True)
    names = {
        "ucp_fast": "t007_fast_unconstrained_paths.rpt",
        "ucp_slow": "t007_slow_unconstrained_paths.rpt",
        "fast_recovery": "t007_fast_emif_reset_to_adapter_recovery.rpt",
        "fast_removal": "t007_fast_emif_reset_to_adapter_removal.rpt",
        "slow_recovery": "t007_slow_emif_reset_to_adapter_recovery.rpt",
        "slow_removal": "t007_slow_emif_reset_to_adapter_removal.rpt",
    }
    (root / names["ucp_fast"]).write_text(_raw_ucp(mode), encoding="utf-8")
    (root / names["ucp_slow"]).write_text(_raw_ucp(mode), encoding="utf-8")
    recovery, recovery_slacks = _timing_report("recovery", mode)
    removal, removal_slacks = _timing_report("removal", mode)
    for key in ("fast_recovery", "slow_recovery"):
        (root / names[key]).write_text(recovery, encoding="utf-8")
    for key in ("fast_removal", "slow_removal"):
        (root / names[key]).write_text(removal, encoding="utf-8")
    (root / "t007_summary.tsv").write_text(_summary(mode, names, {"recovery": recovery_slacks, "removal": removal_slacks}), encoding="utf-8")
    return {key: root / name for key, name in names.items()} | {"summary": root / "t007_summary.tsv"}


def _export_command(
    policy: Path,
    provenance: Path,
    measurement_paths: dict[str, Path],
    paths: dict[str, Path],
    output: Path,
) -> list[str]:
    return [
        sys.executable,
        str(EXPORTER),
        "--allow-fixture-policy",
        "--policy",
        str(policy),
        "--provenance",
        str(provenance),
        "--user-sdc",
        str(measurement_paths["user_sdc"]),
        "--generated-sdc",
        str(measurement_paths["generated_sdc"]),
        "--source-pre-manifest",
        str(measurement_paths["source_pre_manifest"]),
        "--source-post-manifest",
        str(measurement_paths["source_post_manifest"]),
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
    return subprocess.run(command, cwd=cwd, text=True, capture_output=True, check=False)


def _mutate_file(path: Path, old: str, new: str, count: int = 1) -> None:
    text = path.read_text(encoding="utf-8")
    if text.count(old) < count:
        raise RuntimeError(f"fixture mutation token missing in {path}: {old!r}")
    path.write_text(text.replace(old, new, count), encoding="utf-8")


def _raw_faults(
    root: Path,
    base: Path,
    policy: Path,
    provenance: Path,
    measurement_paths: dict[str, Path],
) -> list[dict[str, Any]]:
    root.mkdir(parents=True, exist_ok=True)
    cases: list[tuple[str, Any]] = []

    def add(name: str, mutation: Any) -> None:
        cases.append((name, mutation))

    add("missing-duplicate-base", lambda p, q: _mutate_file(p["ucp_fast"], "|fixture|tms[1] ;", "|fixture|tms[9] ;", 2))
    add("illegal-duplicate-suffix", lambda p, q: _mutate_file(p["ucp_fast"], DUPLICATE_SUFFIX, DUPLICATE_SUFFIX + "_1", 2))
    add("lowercase-duplicate-suffix", lambda p, q: _mutate_file(p["ucp_fast"], DUPLICATE_SUFFIX, "~duplicate", 2))
    add("duplicate-marker-clock", lambda p, q: _mutate_file(p["ucp_fast"], "|fixture|tms[1] ;  ;", "|fixture|tms[1] ; ~DUPLICATE ;", 2))
    add("duplicate-marker-port", lambda p, q: _mutate_file(p["ucp_fast"], "; altera_reserved_tms ; auto_fab_0|alt_sld_fab_0|fixture|tms[0] ;  ;", "; altera_reserved_tms~DUPLICATE ; auto_fab_0|alt_sld_fab_0|fixture|tms[0] ;  ;", 2))
    add("duplicate-marker-reset-source", lambda p, q: _mutate_file(p["fast_recovery"], f"; 0.500 ; {RESET} ;", f"; 0.500 ; {RESET}~DUPLICATE ;", 1))
    add("two-duplicates-one-base", lambda p, q: _mutate_file(p["fast_recovery"], "soc|emif_adapter|emif_state_q.EMIF_WAIT_READ", "soc|emif_adapter|emif_req_q.writedata[1]~DUPLICATE", 1))
    add("fast-slow-ucp-drift", lambda p, q: _mutate_file(p["ucp_slow"], "|fixture|tms[0] ;", "|fixture|tms[9] ;", 2))
    add("cross-corner-timing-drift", lambda p, q: _mutate_file(p["slow_recovery"], "emif_req_q.writedata[0]", "emif_req_q.writedata[9]", 1))
    add("recovery-removal-drift", lambda p, q: _mutate_file(p["fast_removal"], "emif_req_q.writedata[0]", "emif_req_q.writedata[9]", 1))
    add("timing-clock-drift", lambda p, q: _mutate_file(p["fast_recovery"], CLOCK, "sys_clk_25", 2))
    add("timing-header-count-drift", lambda p, q: _mutate_file(p["fast_recovery"], "Found 6 recovery paths", "Found 5 recovery paths"))
    add("negative-detailed-slack", lambda p, q: _mutate_file(p["fast_removal"], "; 0.200 ;", "; -0.001 ;", 1))
    add("ucp-summary-count-drift", lambda p, q: _mutate_file(p["ucp_fast"], "Unconstrained Input Port Paths ; 7 ; 7", "Unconstrained Input Port Paths ; 6 ; 6"))
    add("provenance-hash-drift", lambda p, q: q.update({"user_sdc_sha256": "0" * 64}))
    add("hierarchy-substitution", lambda p, q: _mutate_file(p["ucp_fast"], "auto_fab_0|alt_sld_fab_0|fixture|tms[0]", "emif|emif_bot|fixture|jtag_phy_embedded_in_jtag_master|tms[0]", 2))
    add("normalized-endpoint-deletion", lambda p, q: _mutate_file(p["fast_recovery"], "emif_req_q.writedata[0]", "emif_req_q.writedata[1]", 1))
    add("normalized-endpoint-replacement", lambda p, q: _mutate_file(p["fast_recovery"], "emif_req_q.writedata[0]", "emif_req_q.writedata[9]", 1))

    results: list[dict[str, Any]] = []
    for name, mutation in cases:
        case = root / name
        shutil.copytree(base, case)
        paths = {key: case / value.name for key, value in _make_path_map(base).items()}
        profile = json.loads(provenance.read_text(encoding="utf-8"))
        mutation(paths, profile)
        case_provenance = case / "provenance.json"
        _dump(case_provenance, profile)
        run = _run(_export_command(policy, case_provenance, measurement_paths, paths, case / "inventory.json"), case)
        results.append({"name": name, "exit_code": run.returncode, "rejected": run.returncode == 1, "stderr": run.stderr.strip()})
    return results


def _make_path_map(root: Path) -> dict[str, Path]:
    return {
        "summary": root / "t007_summary.tsv",
        "ucp_fast": root / "t007_fast_unconstrained_paths.rpt",
        "ucp_slow": root / "t007_slow_unconstrained_paths.rpt",
        "fast_recovery": root / "t007_fast_emif_reset_to_adapter_recovery.rpt",
        "fast_removal": root / "t007_fast_emif_reset_to_adapter_removal.rpt",
        "slow_recovery": root / "t007_slow_emif_reset_to_adapter_recovery.rpt",
        "slow_removal": root / "t007_slow_emif_reset_to_adapter_removal.rpt",
    }


def _inventory_faults(root: Path, policy: Path, positive: Path) -> list[dict[str, Any]]:
    base = json.loads(positive.read_text(encoding="utf-8"))
    cases: list[tuple[str, Any]] = [
        ("inventory-member-replacement", lambda x: x["recovery_removal"]["normalized_members"].__setitem__(0, "soc|emif_adapter|emif_req_q.writedata[99]")),
        ("inventory-group-digest", lambda x: x["ucp"]["ports"][0]["path_groups"][next(iter(x["ucp"]["ports"][0]["path_groups"]))].__setitem__("member_digest", "0" * 64)),
        ("inventory-duplicate-metadata", lambda x: x["ucp"]["ports"][2]["raw"]["fast"]["duplicates"][0].__setitem__("base_endpoint", "wrong")),
        ("inventory-negative-slack", lambda x: x["recovery_removal"]["corners"]["fast"]["removal"].__setitem__("worst_slack_ns", -0.001)),
        ("inventory-exception", lambda x: x["exceptions"].append({"kind": "false_path"})),
        ("inventory-provenance", lambda x: x["provenance"]["measurement"].__setitem__("candidate_sha", "0" * 40)),
        ("inventory-raw-type", lambda x: x["ucp"]["ports"][0]["raw"]["fast"].__setitem__("duplicate_count", "one")),
    ]
    results: list[dict[str, Any]] = []
    for name, mutation in cases:
        value = copy.deepcopy(base)
        mutation(value)
        path = root / f"{name}.json"
        _dump(path, value)
        run = _run([sys.executable, str(CHECKER), "--allow-fixture-policy", "--policy", str(policy), "--inventory", str(path), "--json"], root)
        results.append({"name": name, "exit_code": run.returncode, "rejected": run.returncode == 1, "stdout": run.stdout.strip()})
    return results


def _policy_faults(root: Path, fixture_policy: Path, positive: Path) -> list[dict[str, Any]]:
    root.mkdir(parents=True, exist_ok=True)
    results: list[dict[str, Any]] = []
    production = json.loads(PRODUCTION_POLICY.read_text(encoding="utf-8"))
    production["ucp"]["summary"]["input_path_count"] -= 1
    tampered = root / "tampered-production-policy.json"
    _dump(tampered, production)
    run = _run([sys.executable, str(CHECKER), "--policy", str(tampered), "--inventory", str(positive), "--json"], root)
    results.append({"name": "tampered-production-contract", "exit_code": run.returncode, "rejected": run.returncode == 1, "stdout": run.stdout.strip()})
    run = _run([sys.executable, str(CHECKER), "--policy", str(fixture_policy), "--inventory", str(positive), "--json"], root)
    results.append({"name": "fixture-policy-without-opt-in", "exit_code": run.returncode, "rejected": run.returncode == 1, "stdout": run.stdout.strip()})
    return results


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-dir", type=Path, default=DEFAULT_ROOT)
    args = parser.parse_args()
    root = args.output_dir.resolve()
    allowed = (REPO / "build/agents/T-20260910-001").resolve()
    if root != allowed and allowed not in root.parents:
        parser.error(f"output must remain below {allowed}")
    if root.exists():
        shutil.rmtree(root)
    root.mkdir(parents=True)
    policy, profile, measurement_paths = _fixture_policy(root)
    policy_path = root / "fixture-policy.json"
    provenance_path = root / "fixture-provenance.json"
    _dump(policy_path, policy)
    _dump(provenance_path, profile)

    positives: list[dict[str, Any]] = []
    positive_paths: dict[str, dict[str, Path]] = {}
    for mode in ("old", "new"):
        case = root / f"positive-{mode}"
        paths = _make_input(case, mode)
        positive_paths[mode] = paths
        output = case / "inventory.json"
        export = _run(_export_command(policy_path, provenance_path, measurement_paths, paths, output), case)
        check = _run([sys.executable, str(CHECKER), "--allow-fixture-policy", "--policy", str(policy_path), "--inventory", str(output), "--json"], case) if export.returncode == 0 else None
        positives.append({"mode": mode, "export_exit": export.returncode, "check_exit": None if check is None else check.returncode, "pass": export.returncode == 0 and check is not None and check.returncode == 0})

    raw_faults = _raw_faults(root / "raw-faults", positive_paths["new"]["summary"].parent, policy_path, provenance_path, measurement_paths)
    inventory_faults = _inventory_faults(root / "inventory-faults", policy_path, positive_paths["new"]["summary"].parent / "inventory.json")
    policy_faults = _policy_faults(root / "policy-faults", policy_path, positive_paths["new"]["summary"].parent / "inventory.json")
    matrix = {
        "schema_version": 1,
        "positives": positives,
        "raw_faults": raw_faults,
        "inventory_faults": inventory_faults,
        "policy_faults": policy_faults,
        "positive_pass": all(row["pass"] for row in positives),
        "negative_count": len(raw_faults) + len(inventory_faults) + len(policy_faults),
        "negative_rejected": sum(row["rejected"] for row in raw_faults + inventory_faults + policy_faults),
    }
    _dump(root / "matrix.json", matrix)
    print(json.dumps(matrix, indent=2, sort_keys=True))
    return 0 if matrix["positive_pass"] and matrix["negative_rejected"] == matrix["negative_count"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
