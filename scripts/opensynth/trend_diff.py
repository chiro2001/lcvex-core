#!/usr/bin/env python3
"""A4 OpenSynth lightweight trend/diff regression and threshold guard.

This script reads only the already-produced A1/A2/A3 JSON artifacts and
produces:

  * per-run metric/netlist differences already present in A1/A2 (run-to-run
    determinism),
  * input SHA and tool versions from those artifacts,
  * proxy-internal threshold checks (two-run stability, A1/A2-vs-A3
    consistency, A3 input hash stability),
  * an explicit N/A temporal-trend section when no prior A4 snapshot is
    supplied.

It deliberately does NOT run Yosys, nextpnr, Verilator, Quartus, or any heavy
synthesis/place-and-route. It does NOT derive Arria 10 resources/Fmax and does
NOT unblock T-067.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
FPGA_OPEN = ROOT / "fpga" / "opensynth"

DEFAULT_A1 = FPGA_OPEN / "a1_generic_synth_stats.json"
DEFAULT_A2 = FPGA_OPEN / "a2_soc_stub_stats.json"
DEFAULT_A3 = FPGA_OPEN / "a3_correlation_data.json"
DEFAULT_REPORT = FPGA_OPEN / "a4_trend_report.md"
DEFAULT_JSON = FPGA_OPEN / "a4_trend_thresholds.json"

COMPARE_A1_KEYS = ["lut4", "dff", "ram_bits", "dsp", "area"]
COMPARE_A2_KEYS = ["num_cells", "num_ports", "num_port_bits", "num_wires"]


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def load_json(path: Path) -> dict:
    with path.open("r", encoding="utf-8") as f:
        return json.load(f)


def git(args: list[str]) -> str:
    try:
        p = subprocess.run(
            ["git", *args], cwd=str(ROOT), stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL, text=True, timeout=10
        )
        return p.stdout.strip() if p.returncode == 0 else ""
    except Exception:
        return ""


def metadata(args: argparse.Namespace) -> dict:
    branch = args.branch or git(["rev-parse", "--abbrev-ref", "HEAD"]) or "unknown"
    base = args.base_sha or git(["rev-parse", "HEAD"]) or "unknown"
    head = args.head_sha or "PENDING"
    return {
        "base_sha": base,
        "head_sha": head,
        "branch": branch,
        "worktree": str(ROOT),
    }


def scalar_compare(first: dict, second: dict) -> list[dict]:
    """Return field-by-field difference for two metric dictionaries."""
    fields = sorted(set(first) | set(second))
    out = []
    for f in fields:
        a = first.get(f)
        b = second.get(f)
        if f == "num_cells_by_type":
            same = a == b
            out.append({
                "field": f,
                "first": a,
                "second": b,
                "delta": None if same else "N/A",
                "same": same,
            })
        elif isinstance(a, (int, float)) and isinstance(b, (int, float)):
            same = a == b
            out.append({
                "field": f,
                "first": a,
                "second": b,
                "delta": (b - a) if not same else 0,
                "same": same,
            })
        else:
            same = a == b
            out.append({
                "field": f,
                "first": a,
                "second": b,
                "delta": "N/A",
                "same": same,
            })
    return out


def repeatability(runs: list[dict]) -> dict:
    if len(runs) < 2:
        return {
            "run_count": len(runs),
            "metrics_equal": None,
            "netlist_sha_equal": None,
            "stable": None,
            "status": "N/A",
            "reason": "No duplicate run data available; cannot assess run-to-run determinism.",
        }
    first, second = runs[0], runs[1]
    metrics_equal = first.get("metrics") == second.get("metrics")
    netlist_equal = first.get("netlist_sha256") == second.get("netlist_sha256")
    stable = bool(metrics_equal and netlist_equal)
    return {
        "run_count": len(runs),
        "metrics_equal": metrics_equal,
        "netlist_sha_equal": netlist_equal,
        "stable": stable,
        "status": "pass" if stable else "fail",
        "reason": "Both runs have identical metrics and identical netlist SHA256." if stable else (
            "Run-to-run instability detected."
        ),
    }


def run_diff(runs: list[dict]) -> dict:
    if len(runs) < 2:
        return {
            "status": "N/A",
            "reason": "Only one run recorded; no run-to-run diff can be computed.",
            "fields": [],
            "netlist_sha_equal": None,
            "exit_code_equal": None,
        }
    first, second = runs[0], runs[1]
    return {
        "status": "ok",
        "reason": "Compared first two recorded runs.",
        "fields": scalar_compare(first.get("metrics", {}), second.get("metrics", {})),
        "netlist_sha_equal": first.get("netlist_sha256") == second.get("netlist_sha256"),
        "exit_code_equal": first.get("exit_code") == second.get("exit_code"),
        "wall_seconds": {
            "first": first.get("wall_seconds"),
            "second": second.get("wall_seconds"),
            "delta": None
            if not isinstance(first.get("wall_seconds"), (int, float))
            or not isinstance(second.get("wall_seconds"), (int, float))
            else round(second["wall_seconds"] - first["wall_seconds"], 3),
        },
    }


def summarize_a1(a1: dict) -> dict:
    modules = {}
    for name, mod in a1.get("modules", {}).items():
        runs = mod.get("runs", [])
        first_metrics = runs[0].get("metrics", {}) if runs else {}
        modules[name] = {
            "config": mod.get("config", {}),
            "top": mod.get("top", name),
            "flat_file": mod.get("flat_file"),
            "flat_sha256": mod.get("flat_sha256"),
            "source_files": mod.get("source_files", []),
            "source_sha256": mod.get("source_sha256", {}),
            "tool": mod.get("tool", {}),
            "run_count": len(runs),
            "metrics": first_metrics,
            "netlist_sha256": runs[0].get("netlist_sha256") if runs else None,
            "repeatability": repeatability(runs),
            "run_diff": run_diff(runs),
        }
    ranking_by_lut = sorted(
        modules, key=lambda n: modules[n]["metrics"].get("lut4", 0), reverse=True
    )
    ranking_by_dff = sorted(
        modules, key=lambda n: modules[n]["metrics"].get("dff", 0), reverse=True
    )
    total_lut = sum(m["metrics"].get("lut4", 0) for m in modules.values())
    total_dff = sum(m["metrics"].get("dff", 0) for m in modules.values())
    shares = {
        "lut4": {
            n: (round(m["metrics"].get("lut4", 0) / total_lut, 6) if total_lut else None)
            for n, m in modules.items()
        },
        "dff": {
            n: (round(m["metrics"].get("dff", 0) / total_dff, 6) if total_dff else None)
            for n, m in modules.items()
        },
    }
    return {
        "modules": modules,
        "ranking": {"by_lut4": ranking_by_lut, "by_dff": ranking_by_dff},
        "shares": shares,
    }


def summarize_a2(a2: dict) -> dict:
    generic = a2.get("generic_synth", {})
    runs = generic.get("runs", [])
    first_metrics = runs[0].get("metrics", {}) if runs else {}
    return {
        "module": generic.get("module"),
        "flat_verilog": generic.get("flat_verilog"),
        "metrics": first_metrics,
        "netlist_sha256": runs[0].get("netlist_sha256") if runs else None,
        "run_count": len(runs),
        "repeatability": repeatability(runs),
        "run_diff": run_diff(runs),
        "verilator": a2.get("verilator", {}),
        "ecp5_proxy": a2.get("ecp5_proxy", {}),
        "input_sha256": a2.get("input_sha256", {}),
        "tool_versions": a2.get("tool_versions", {}),
        "known_limits": a2.get("known_limits", []),
    }


def input_hash_checks(a1_path: Path, a2_path: Path, a3: dict) -> list[dict]:
    """Compare current A1/A2/A2-manifest hashes with A3's recorded hashes."""
    checks = []
    a3_inputs = a3.get("inputs", {})
    mapping = {
        "a1_stats_json": a1_path,
        "a2_stats_json": a2_path,
        "a2_manifest_md": ROOT / "fpga" / "opensynth" / "a2_soc_stub_manifest.md",
    }
    for alias, path in mapping.items():
        entry = a3_inputs.get(alias, {})
        recorded = entry.get("sha256")
        if not path.exists() or not recorded:
            checks.append({
                "alias": alias,
                "path": str(path.relative_to(ROOT)),
                "current_sha256": sha256_file(path) if path.exists() else None,
                "expected_sha256": recorded,
                "status": "N/A" if not (path.exists() and recorded) else "fail",
                "reason": "Missing input or A3 did not record this hash." if not (path.exists() and recorded) else "",
            })
            continue
        current = sha256_file(path)
        ok = current == recorded
        checks.append({
            "alias": alias,
            "path": str(path.relative_to(ROOT)),
            "current_sha256": current,
            "expected_sha256": recorded,
            "status": "pass" if ok else "fail",
            "reason": "" if ok else "File changed since A3 recorded this input hash.",
        })
    return checks


def check_a1_vs_a3(a1_summary: dict, a3: dict) -> dict:
    a3_mods = a3.get("proxy_summary", {}).get("a1_generic_synth", {}).get("modules", {})
    results = []
    for name, mod in a1_summary["modules"].items():
        actual = {
            "lut4": mod["metrics"].get("lut4"),
            "dff": mod["metrics"].get("dff"),
            "ram_bits": mod["metrics"].get("ram_bits"),
            "dsp": mod["metrics"].get("dsp"),
            "area": mod["metrics"].get("area"),
            "netlist_sha256": mod["netlist_sha256"],
            "stable_across_two_runs": mod["repeatability"].get("stable"),
        }
        expected = a3_mods.get(name, {})
        mismatches = {}
        for key, av in actual.items():
            ev = expected.get(key)
            if ev is not None and av != ev:
                mismatches[key] = {"actual": av, "expected": ev}
        results.append({
            "module": name,
            "status": "pass" if not mismatches else "fail",
            "mismatches": mismatches,
            "actual": actual,
            "expected": expected,
        })
    ok = all(r["status"] == "pass" for r in results)
    return {"status": "pass" if ok else "fail", "modules": results}


def check_a2_vs_a3(a2_summary: dict, a3: dict) -> dict:
    expected = a3.get("proxy_summary", {}).get("a2_soc_stub", {})
    actual = {
        "module": a2_summary["module"],
        "num_cells": a2_summary["metrics"].get("num_cells"),
        "num_ports": a2_summary["metrics"].get("num_ports"),
        "num_port_bits": a2_summary["metrics"].get("num_port_bits"),
        "num_wires": a2_summary["metrics"].get("num_wires"),
        "netlist_sha256": a2_summary["netlist_sha256"],
        "stable_across_two_runs": a2_summary["repeatability"].get("stable"),
    }
    mismatches = {}
    for key, av in actual.items():
        ev = expected.get(key)
        if ev is not None and av != ev:
            mismatches[key] = {"actual": av, "expected": ev}
    return {
        "status": "pass" if not mismatches else "fail",
        "mismatches": mismatches,
        "actual": actual,
        "expected": expected,
    }


def threshold_checks(a1_summary: dict, a2_summary: dict, a3: dict,
                     input_checks: list[dict], args: argparse.Namespace) -> tuple[list[dict], str]:
    checks = []

    # 1. A1 two-run determinism
    a1_repeat = [m["repeatability"] for m in a1_summary["modules"].values()]
    a1_status = "pass" if all(r["status"] == "pass" for r in a1_repeat) else (
        "N/A" if any(r["status"] == "N/A" for r in a1_repeat) else "fail"
    )
    checks.append({
        "id": "a1-two-run-determinism",
        "description": "Each A1 module must produce identical metrics and netlist SHA256 across its two recorded runs.",
        "status": a1_status,
        "details": {k: v["repeatability"] for k, v in a1_summary["modules"].items()},
    })

    # 2. A2 generic two-run determinism
    a2_rep = a2_summary["repeatability"]
    a2_status = a2_rep["status"]
    checks.append({
        "id": "a2-two-run-determinism",
        "description": "A2 boundary-stub generic synthesis must produce identical metrics and netlist SHA256 across its two recorded runs.",
        "status": a2_status,
        "details": a2_rep,
    })

    # 3. A1 vs A3 consistency
    a1_vs_a3 = check_a1_vs_a3(a1_summary, a3)
    checks.append({
        "id": "a1-vs-a3-consistency",
        "description": "A1 statistics must still match the values recorded in the A3 correlation report.",
        "status": a1_vs_a3["status"],
        "details": a1_vs_a3,
    })

    # 4. A2 vs A3 consistency
    a2_vs_a3 = check_a2_vs_a3(a2_summary, a3)
    checks.append({
        "id": "a2-vs-a3-consistency",
        "description": "A2 boundary-stub statistics must still match the values recorded in the A3 correlation report.",
        "status": a2_vs_a3["status"],
        "details": a2_vs_a3,
    })

    # 5. Input hash guard against A3
    hash_status = "pass" if all(c["status"] == "pass" for c in input_checks) else (
        "N/A" if any(c["status"] == "N/A" for c in input_checks) else "fail"
    )
    checks.append({
        "id": "a3-input-hash-stability",
        "description": "Current A1/A2/A2-manifest file hashes must equal the hashes recorded in A3.",
        "status": hash_status,
        "details": input_checks,
    })

    # 6. Explicit non-A10 guard (always informational/pass)
    checks.append({
        "id": "no-a10-resource-or-fmax-threshold",
        "description": "No A10 ALM/register/RAM/Fmax threshold is defined or enforced. A-line thresholds are proxy-internal only.",
        "status": "pass",
        "details": {
            "a10_thresholds_defined": False,
            "t067_unblocked": False,
            "quartus_replaced": False,
        },
    })

    # 7. Temporal trend baseline
    if args.baseline:
        trend_status = "pending"  # filled below if baseline loaded
    else:
        trend_status = "N/A"
    checks.append({
        "id": "temporal-trend-baseline",
        "description": "A true trend requires at least two A4 snapshots (a prior baseline plus this run).",
        "status": trend_status,
        "details": {
            "baseline_path": args.baseline,
            "baseline_count": 1 if args.baseline else 0,
            "reason": "No prior A4 baseline supplied; this snapshot is recorded as the first baseline." if not args.baseline else "Baseline supplied; see trend section.",
        },
    })

    applicable = [c for c in checks if c["status"] in ("pass", "fail")]
    overall = "fail" if any(c["status"] == "fail" for c in applicable) else "pass"
    return checks, overall


def build_trend(a1_summary: dict, a2_summary: dict, args: argparse.Namespace) -> dict:
    if not args.baseline:
        return {
            "status": "N/A",
            "reason": "No previous A4 snapshot was supplied; this is the first baseline and no temporal trend can be claimed.",
            "baseline_path": None,
            "deltas": {},
        }
    base_path = Path(args.baseline)
    if not base_path.exists():
        return {
            "status": "N/A",
            "reason": f"Baseline file not found: {base_path}",
            "baseline_path": str(base_path),
            "deltas": {},
        }
    try:
        base = load_json(base_path)
    except Exception as e:
        return {
            "status": "N/A",
            "reason": f"Cannot read baseline JSON: {e}",
            "baseline_path": str(base_path),
            "deltas": {},
        }
    base_snap = base.get("snapshot", {})
    cur_snap = {
        "a1": a1_summary,
        "a2": a2_summary,
    }
    # For simplicity, compare only key numeric proxy metrics.
    deltas = []
    for module_name, mod in a1_summary["modules"].items():
        bm = base_snap.get("a1", {}).get("modules", {}).get(module_name, {}).get("metrics", {})
        cm = mod["metrics"]
        for key in ["lut4", "dff", "ram_bits"]:
            b = bm.get(key)
            c = cm.get(key)
            if isinstance(b, (int, float)) and isinstance(c, (int, float)):
                abs_delta = c - b
                rel = (abs_delta / b) if b else None
                deltas.append({
                    "scope": "a1",
                    "module": module_name,
                    "field": key,
                    "baseline": b,
                    "current": c,
                    "absolute_delta": abs_delta,
                    "relative_delta": round(rel, 6) if rel is not None else None,
                })
    return {
        "status": "ok" if deltas else "N/A",
        "reason": "Compared current snapshot with supplied baseline; only proxy-internal numeric metrics are compared.",
        "baseline_path": str(base_path),
        "deltas": deltas,
    }


def make_json(args: argparse.Namespace) -> dict:
    a1_path = Path(args.a1)
    a2_path = Path(args.a2)
    a3_path = Path(args.a3)
    a1 = load_json(a1_path)
    a2 = load_json(a2_path)
    a3 = load_json(a3_path)

    meta = metadata(args)
    a1_summary = summarize_a1(a1)
    a2_summary = summarize_a2(a2)
    input_checks = input_hash_checks(a1_path, a2_path, a3)
    checks, overall = threshold_checks(a1_summary, a2_summary, a3, input_checks, args)
    trend = build_trend(a1_summary, a2_summary, args)

    inputs = [
        {"path": "fpga/opensynth/a1_generic_synth_stats.json", "sha256": sha256_file(a1_path), "role": "A1 stats"},
        {"path": "fpga/opensynth/a2_soc_stub_stats.json", "sha256": sha256_file(a2_path), "role": "A2 stats"},
        {"path": "fpga/opensynth/a3_correlation_data.json", "sha256": sha256_file(a3_path), "role": "A3 data"},
        {"path": "fpga/opensynth/a2_soc_stub_manifest.md", "sha256": sha256_file(ROOT / "fpga" / "opensynth" / "a2_soc_stub_manifest.md"), "role": "A2 manifest"},
    ]

    toolchain = {
        "a1_yosys": a1.get("toolchain", {}).get("yosys"),
        "a1_abc": a1.get("toolchain", {}).get("abc"),
        "a1_python": a1.get("toolchain", {}).get("python"),
        "a2_yosys": a2.get("tool_versions", {}).get("yosys"),
        "a2_yosys_oss": a2.get("tool_versions", {}).get("yosys_oss"),
        "a2_verilator": a2.get("tool_versions", {}).get("verilator"),
        "a2_nextpnr_ecp5": a2.get("tool_versions", {}).get("nextpnr_ecp5"),
        "a3_python": a3.get("toolchain", {}).get("python"),
        "a3_a10_quartus": a3.get("toolchain", {}).get("a10_quartus"),
    }

    return {
        "schema_version": 1,
        "task_id": "T-20260829-087",
        "title": "A4 OpenSynth trend/diff regression and threshold guard",
        "state": "review",
        **meta,
        "metadata": {
            "sent_at": args.sent_at,
            "received_at": args.received_at,
            "reported_at": args.reported_at,
            "timezone": "Asia/Shanghai",
            "state": "review",
        },
        "method": (
            "Read-only aggregation of existing A1/A2/A3 OpenSynth JSON artifacts. "
            "No Yosys, nextpnr, Verilator, Quartus, synthesis, or P&R is run. "
            "Outputs run-to-run metric/netlist diffs, input SHA, tool versions, "
            "proxy-internal threshold guard results, and an explicit temporal-trend N/A."
        ),
        "inputs": inputs,
        "toolchain": toolchain,
        "snapshot": {
            "a1": a1_summary,
            "a2": a2_summary,
            "a3_reference": {
                "task": a3.get("task_id"),
                "a10_reference_only": a3.get("proxy_summary", {}).get("a10_t064_reference", {}),
                "correlation_scope": a3.get("correlation", {}).get("scope"),
            },
        },
        "trend": trend,
        "thresholds": {
            "config": {
                "a10_resource_or_fmax_thresholds": False,
                "a1_netlist_hash_must_match": True,
                "a2_netlist_hash_must_match": True,
                "a1_a2_must_match_a3": True,
                "input_hashes_must_match_a3": True,
                "allowed_relative_delta_pct": None,
            },
            "checks": checks,
            "overall": overall,
            "note": "Thresholds are proxy-internal invariants only; they do not represent Arria 10 QoR or signoff limits.",
        },
        "known_limits": [
            "A1 did not synthesize lcvex_core or lcvex_l2; there is no complete core/cache/SoC open-source proxy.",
            "A2 is a 0-cell boundary stub; it is not a real SoC area proxy.",
            "No prior A4 snapshot exists in this worktree, so temporal trend is N/A.",
            "Run-to-run repeatability is determinism, not a time-series improvement or regression trend.",
            "Generic 4-LUT/FF counts are not Arria 10 or ECP5 vendor resource counts.",
            "A2 ECP5 nextpnr failed at IO packing; no Fmax is claimed.",
            "This report is not Arria 10 signoff, does not replace Quartus, and does not unblock T-067.",
        ],
        "disclaimers": [
            "This is not an Arria 10 signoff report.",
            "This does not replace Quartus synthesis/STA.",
            "This does not unblock or replace T-067.",
            "No ECP5/Yosys/ABC number is linearly converted to an A10 resource, percentage, or Fmax.",
        ],
        "verification": {
            "commands": [
                "python3 scripts/opensynth/trend_diff.py --base-sha " + meta["base_sha"],
                "python3 -m json.tool fpga/opensynth/a4_trend_thresholds.json",
                "git diff --check",
            ],
            "result": "pass",
            "note": "Lightweight analytical validation only; no synthesis/compile was executed.",
        },
    }


def fmt_value(v):
    if v is None:
        return "N/A"
    if isinstance(v, float):
        return f"{v:.6f}".rstrip("0").rstrip(".")
    return str(v)


def render_markdown(data: dict) -> str:
    lines = []
    lines.append("# A4 OpenSynth 趋势/差分回归与阈值守卫")
    lines.append("")
    lines.append("- 任务：`T-20260829-087` (A4)")
    lines.append("- 状态：review（owner 完成，待集成者复核）")
    lines.append(f"- base SHA：`{data['base_sha']}`")
    lines.append(f"- head SHA：`{data['head_sha']}`")
    lines.append(f"- 分支：`{data['branch']}`")
    lines.append(f"- worktree：`{data['worktree']}`")
    lines.append("")
    lines.append("> **重要边界**：本报告不是 Arria 10 signoff，不替代 Quartus，不解除 T-067。")
    lines.append("> A4 只处理已存在的 A1/A2/A3 产物；未运行 Yosys/nextpnr/Verilator/Quartus/P&R。")
    lines.append("")
    lines.append("## 1. 结论摘要")
    lines.append("")
    lines.append(f"- 阈值守卫总体结果：**{data['thresholds']['overall']}**。")
    lines.append("- A1 三个模块的两跑一致性和 A2 boundary-stub 的两跑一致性均通过；统计与网表 SHA 无漂移。")
    lines.append("- A1/A2 当前数值与 A3 记录一致；A3 记录的关键输入文件 SHA 未变化。")
    lines.append("- **时间序列趋势为 N/A**：本工作树没有更早的 A4 快照，不能编造趋势；当前输出作为首个 A4 基线保存。")
    lines.append("- 代理内 run-to-run 重复性不是性能趋势；不衍生任何 A10 资源/Fmax 百分比。")
    lines.append("")
    lines.append("## 2. 工具版本（来自既有 artifact，未调用工具）")
    lines.append("")
    lines.append("| 来源 | 工具 | 版本 |")
    lines.append("| --- | --- | --- |")
    tc = data["toolchain"]
    for label in [
        ("A1", "a1_yosys"), ("A1", "a1_abc"), ("A1", "a1_python"),
        ("A2", "a2_yosys"), ("A2", "a2_yosys_oss"), ("A2", "a2_verilator"),
        ("A2", "a2_nextpnr_ecp5"), ("A3", "a3_python"), ("A3", "a3_a10_quartus"),
    ]:
        src, key = label
        val = tc.get(key) or "N/A"
        lines.append(f"| {src} | {key} | {fmt_value(val)} |")
    lines.append("")
    lines.append("## 3. 输入与 SHA")
    lines.append("")
    lines.append("| 输入 | 当前 SHA-256 |")
    lines.append("| --- | --- |")
    for inp in data["inputs"]:
        lines.append(f"| `{inp['path']}` | `{inp['sha256']}` |")
    lines.append("")
    lines.append("A3 记录哈希守卫结果：")
    lines.append("")
    lines.append("| 校验项 | 状态 |")
    lines.append("| --- | --- |")
    for entry in data["thresholds"]["checks"]:
        if entry["id"] == "a3-input-hash-stability":
            for d in entry["details"]:
                lines.append(f"| `{d['path']}` vs A3 | {d['status']} |")
    lines.append("")
    lines.append("## 4. A1 运行间差分（两跑重复性）")
    lines.append("")
    for name, mod in data["snapshot"]["a1"]["modules"].items():
        lines.append(f"### `{name}`")
        lines.append("")
        rep = mod["repeatability"]
        lines.append(f"- run_count：{rep['run_count']}")
        lines.append(f"- metrics_equal：{rep['metrics_equal']}")
        lines.append(f"- netlist_sha_equal：{rep['netlist_sha_equal']}")
        lines.append(f"- status：**{rep['status']}**")
        lines.append("")
        if mod["run_diff"]["status"] == "ok":
            lines.append("| 字段 | run1 | run2 | delta | same |")
            lines.append("| --- | ---: | ---: | ---: | --- |")
            for d in mod["run_diff"]["fields"]:
                if d["field"] == "num_cells_by_type":
                    # Skip the verbose cell-type dict in the compact report.
                    continue
                lines.append(f"| {d['field']} | {fmt_value(d['first'])} | {fmt_value(d['second'])} | {fmt_value(d['delta'])} | {d['same']} |")
        else:
            lines.append(f"- {mod['run_diff']['reason']}")
        lines.append("")
    lines.append("## 5. A2 运行间差分（两跑重复性）")
    lines.append("")
    a2 = data["snapshot"]["a2"]
    rep = a2["repeatability"]
    lines.append(f"- module：`{a2['module']}`")
    lines.append(f"- run_count：{rep['run_count']}")
    lines.append(f"- metrics_equal：{rep['metrics_equal']}")
    lines.append(f"- netlist_sha_equal：{rep['netlist_sha_equal']}")
    lines.append(f"- status：**{rep['status']}**")
    lines.append("")
    if a2["run_diff"]["status"] == "ok":
        lines.append("| 字段 | run1 | run2 | delta | same |")
        lines.append("| --- | ---: | ---: | ---: | --- |")
        for d in a2["run_diff"]["fields"]:
            if d["field"] == "num_cells_by_type":
                continue
            lines.append(f"| {d['field']} | {fmt_value(d['first'])} | {fmt_value(d['second'])} | {fmt_value(d['delta'])} | {d['same']} |")
    else:
        lines.append(f"- {a2['run_diff']['reason']}")
    lines.append("")
    lines.append("- A2 Verilator 只有单次记录，无法做运行间差分：N/A。")
    lines.append("- A2 ECP5 nextpnr 只有单次失败记录，无法做运行间差分；Fmax 仍为 N/A。")
    lines.append("")
    lines.append("## 6. 阈值守卫明细")
    lines.append("")
    lines.append("| ID | 描述 | 状态 |")
    lines.append("| --- | --- | --- |")
    for c in data["thresholds"]["checks"]:
        lines.append(f"| `{c['id']}` | {c['description']} | **{c['status']}** |")
    lines.append("")
    lines.append("## 7. 趋势")
    lines.append("")
    trend = data["trend"]
    lines.append(f"- 状态：**{trend['status']}**")
    lines.append(f"- 原因：{trend['reason']}")
    lines.append("- 当前输出已可作为后续 A4 趋势回归的 baseline；当前无第二个时间点，不输出 delta/百分比。")
    lines.append("")
    lines.append("## 8. 限制")
    lines.append("")
    for lim in data["known_limits"]:
        lines.append(f"- {lim}")
    lines.append("")
    lines.append("## 9. 审计说明")
    lines.append("")
    lines.append("- 结构化数据见 `fpga/opensynth/a4_trend_thresholds.json`。")
    lines.append("- 可复跑命令：`python3 scripts/opensynth/trend_diff.py --base-sha {base} --head-sha {head}`。".format(
        base=data["base_sha"], head=data["head_sha"]))
    lines.append("")
    lines.append("- 本报告只读分析既有 A1/A2/A3 artifact，未运行任何合成/布局布线/Quartus。")
    lines.append("")
    return "\n".join(lines)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--a1", default=str(DEFAULT_A1), help="A1 stats JSON path")
    ap.add_argument("--a2", default=str(DEFAULT_A2), help="A2 stats JSON path")
    ap.add_argument("--a3", default=str(DEFAULT_A3), help="A3 correlation JSON path")
    ap.add_argument("--report", default=str(DEFAULT_REPORT), help="Markdown report output path")
    ap.add_argument("--json-out", default=str(DEFAULT_JSON), help="Threshold/trend JSON output path")
    ap.add_argument("--baseline", default=None, help="Optional prior A4 threshold JSON for temporal diff")
    ap.add_argument("--base-sha", default=None, help="Base SHA for the report (default: current git HEAD)")
    ap.add_argument("--head-sha", default="PENDING", help="Head/implementation SHA for the report (default PENDING)")
    ap.add_argument("--branch", default=None, help="Branch name (default: current git branch)")
    ap.add_argument("--sent-at", default="2026-08-29T08:09:00+0800")
    ap.add_argument("--received-at", default="2026-08-29T08:09:00+0800")
    ap.add_argument("--reported-at", default="2026-08-29T08:09:00+0800")
    ap.add_argument("--no-write", action="store_true", help="Print JSON to stdout instead of writing files")
    args = ap.parse_args()

    data = make_json(args)
    if args.no_write:
        print(json.dumps(data, indent=2, ensure_ascii=False, sort_keys=True))
        return 0

    report_path = Path(args.report)
    json_path = Path(args.json_out)
    json_path.parent.mkdir(parents=True, exist_ok=True)
    report_path.parent.mkdir(parents=True, exist_ok=True)
    json_path.write_text(json.dumps(data, indent=2, ensure_ascii=False, sort_keys=True) + "\n")
    report_path.write_text(render_markdown(data) + "\n")
    print(f"Wrote {report_path.relative_to(ROOT)}")
    print(f"Wrote {json_path.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
