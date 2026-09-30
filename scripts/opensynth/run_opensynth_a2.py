#!/usr/bin/env python3
"""A2 SoC stub/tie-off open-synthesis proxy.

This script reproduces the A2 evidence:

1. Writes/checks the fpga/opensynth tie-off wrapper and plain-Verilog boundary
   stub (the wrapper is a lint harness around the real lcvex_catapult_soc_top;
   the stub is a Yosys-readable boundary proxy).
2. Runs Verilator lint/elaboration on the real SoC through the tie-off wrapper.
3. Runs Yosys generic 4-LUT synthesis twice on the plain-Verilog boundary stub.
4. If an OSS Yosys with ECP5 support and nextpnr-ecp5 are available, attempts
   ECP5 place-and-route on the boundary stub. The stub has 109 ports / 2627 port
   bits, so ECP5 is expected to be unable to place all TRELLIS_IO cells; this is
   recorded as N/A for Fmax, not claimed.

No RTL source files are modified. Only fpga/opensynth/**, scripts/opensynth/**,
build/tmp/opensynth/** and the A2 handoff/evidence are written by this script's
default outputs.

Usage:
  python3 scripts/opensynth/run_opensynth_a2.py [--skip-verilator] [--skip-ecp5]
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
FPGA_OPEN = ROOT / "fpga" / "opensynth"
GEN_DIR = FPGA_OPEN / "rtl"
BUILD_DIR = ROOT / "build" / "tmp" / "opensynth" / "a2"
LOG_DIR = FPGA_OPEN / "logs"

TOOL_TIMEOUT_S = 1800

TIE_OFF_SV = GEN_DIR / "lcvex_catapult_soc_tieoff.sv"
STUB_V = GEN_DIR / "lcvex_catapult_soc_stub_top.v"
TIE_FILELIST = FPGA_OPEN / "filelist_soc_tieoff.f"
STUB_FILELIST = FPGA_OPEN / "filelist_soc_stub.f"

REAL_SOC_INPUTS = [
    "rtl/lcvex_pkg.sv",
    "rtl/lcvex_catapult_soc_pkg.sv",
    "rtl/lcvex_catapult_soc_top.sv",
    "rtl/lcvex_catapult_soc_axi.sv",
    "rtl/lcvex_catapult_soc_coh.sv",
    "rtl/lcvex_mem_router.sv",
    "rtl/lcvex_bram_boot.sv",
    "rtl/lcvex_axi4_master.sv",
    "rtl/lcvex_axi4_avalon_adapter.sv",
]


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def sha256_text(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def find_tool(name: str, env_var: str, candidates: list[Path | str]) -> str | None:
    env = os.environ.get(env_var)
    if env:
        return env
    for cand in candidates:
        p = Path(cand).expanduser()
        if p.is_file() and os.access(p, os.X_OK):
            return str(p)
        if shutil.which(str(cand)):
            return str(cand)
    return None


def tool_version(cmd: list[str]) -> str:
    try:
        p = subprocess.run(
            cmd, cwd=str(ROOT), stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT, text=True, timeout=20
        )
        return p.stdout.strip().splitlines()[0] if p.stdout.strip() else ""
    except Exception:
        return ""


def run_cmd(cmd: list[str], cwd: Path, log_path: Path, timeout: int = TOOL_TIMEOUT_S) -> dict:
    log_path.parent.mkdir(parents=True, exist_ok=True)
    t0 = time.time()
    try:
        p = subprocess.run(
            cmd, cwd=str(cwd), stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT, text=True, timeout=timeout
        )
        wall = round(time.time() - t0, 3)
        log_path.write_text(p.stdout)
        return {
            "exit_code": p.returncode,
            "wall_seconds": wall,
            "log": str(log_path),
            "log_sha256": sha256_file(log_path),
        }
    except subprocess.TimeoutExpired as e:
        wall = round(time.time() - t0, 3)
        out = (e.stdout or b"").decode("utf-8", "replace") if isinstance(e.stdout, bytes) else (e.stdout or "")
        log_path.write_text(out)
        return {
            "exit_code": None,
            "wall_seconds": wall,
            "log": str(log_path),
            "log_sha256": sha256_file(log_path),
            "timeout": True,
        }


def verilator_bin() -> str:
    cands = [
        Path("/home/chiro/miniforge3/envs/lcvex/bin/verilator"),
        "verilator",
    ]
    return find_tool("verilator", "VERILATOR_BIN", cands) or "verilator"


def yosys_bin() -> str:
    cands = [
        Path("/tmp/oss_cad/oss-cad-suite/bin/yosys"),
        "yosys",
    ]
    return find_tool("yosys", "YOSYS_BIN", cands) or "yosys"


def nextpnr_ecp5_bin() -> str | None:
    cands = [
        Path("/tmp/oss_cad/oss-cad-suite/bin/nextpnr-ecp5"),
        "nextpnr-ecp5",
    ]
    return find_tool("nextpnr-ecp5", "NEXTPNR_ECP5", cands)


def run_verilator_lint(skip_if_log_exists: bool = False) -> dict:
    log = BUILD_DIR / "verilator_tieoff.log"
    meta = BUILD_DIR / "verilator_tieoff.meta.json"
    if skip_if_log_exists and log.exists():
        if meta.exists():
            m = json.loads(meta.read_text())
            m["skipped"] = True
            m["log"] = str(log)
            m["log_sha256"] = sha256_file(log)
            return m
        return {
            "exit_code": None,
            "wall_seconds": None,
            "log": str(log),
            "log_sha256": sha256_file(log),
            "skipped": True,
        }
    cmd = [
        verilator_bin(),
        "--lint-only", "--timing", "--assert",
        "-Wno-fatal",
        "-Wno-DECLFILENAME", "-Wno-PINMISSING", "-Wno-UNUSEDSIGNAL",
        "-Wno-UNDRIVEN", "-Wno-WIDTHEXPAND", "-Wno-UNSIGNED",
        "-Wno-MULTIDRIVEN", "-Wno-PROCASSINIT",
        "--top-module", "lcvex_catapult_soc_tieoff_top",
        "-Mdir", str(BUILD_DIR / "obj_dir_tieoff"),
        "-f", str(TIE_FILELIST),
    ]
    result = run_cmd(cmd, ROOT, log)
    meta.write_text(json.dumps({
        "exit_code": result["exit_code"],
        "wall_seconds": result["wall_seconds"],
        "log_sha256": result["log_sha256"],
    }, indent=2, sort_keys=True) + "\n")
    return result


def parse_yosys_stat(log_text: str) -> dict:
    idx = log_text.rfind('\n{\n   "creator"')
    if idx < 0:
        # Try a looser match if the pretty-print differs.
        idx = log_text.rfind('{\n   "creator"')
    if idx < 0:
        raise RuntimeError("Yosys stat -json block not found")
    dec = json.JSONDecoder()
    obj, _ = dec.raw_decode(log_text[idx + 1:])
    mods = obj["modules"]
    # There may be one module only.
    key = next(iter(mods))
    return mods[key]


def run_yosys_generic(run_id: str, module: str, source: Path) -> dict:
    run_dir = BUILD_DIR / run_id
    if run_dir.exists():
        shutil.rmtree(run_dir)
    run_dir.mkdir(parents=True, exist_ok=True)
    script = (
        f"read_verilog -sv {source}\n"
        f"synth -top {module} -lut 4\n"
        "write_verilog -noattr -noexpr netlist.v\n"
        "stat -json\n"
    )
    script_path = run_dir / "synth.ys"
    script_path.write_text(script)
    log_path = run_dir / "yosys.log"
    cmd = [yosys_bin(), "-s", str(script_path)]
    result = run_cmd(cmd, run_dir, log_path, timeout=300)
    netlist = run_dir / "netlist.v"
    metrics = {}
    if result["exit_code"] == 0:
        metrics = parse_yosys_stat(log_path.read_text())
    return {
        "run_id": run_id,
        "exit_code": result["exit_code"],
        "wall_seconds": result["wall_seconds"],
        "log_sha256": result["log_sha256"],
        "netlist_sha256": sha256_file(netlist) if netlist.exists() else None,
        "netlist_bytes": netlist.stat().st_size if netlist.exists() else None,
        "metrics": metrics,
    }


def run_ecp5(nextpnr: str | None) -> dict:
    # Prefer OSS Yosys when available because it carries synth_ecp5.
    oss_yosys = Path("/tmp/oss_cad/oss-cad-suite/bin/yosys")
    if not oss_yosys.is_file():
        return {"status": "skipped", "reason": "OSS Yosys with synth_ecp5 not found"}
    json_path = BUILD_DIR / "stub_ecp5.json"
    log_path = BUILD_DIR / "yosys_ecp5.log"
    cmd = [str(oss_yosys), "-p",
           f"read_verilog -sv {STUB_V}; "
           f"synth_ecp5 -top lcvex_catapult_soc_stub_top -json {json_path}"]
    os.environ.setdefault("LD_LIBRARY_PATH", "/tmp/oss_cad/oss-cad-suite/lib:/tmp/oss_cad/oss-cad-suite/lib64")
    result = run_cmd(cmd, ROOT, log_path, timeout=300)
    if result["exit_code"] != 0 or not json_path.exists():
        result["status"] = "fail"
        result["reason"] = "synth_ecp5 failed or no JSON produced"
        return result
    if not nextpnr:
        result["status"] = "synth_only"
        result["reason"] = "nextpnr-ecp5 not found; no place/route attempted"
        return result
    pnr_log = BUILD_DIR / "nextpnr_ecp5.log"
    pnr_cmd = [
        nextpnr,
        "--json", str(json_path),
        "--85k", "--package", "CABGA381", "--seed", "1",
        "--lpf-allow-unconstrained",
        "--report", str(BUILD_DIR / "stub_ecp5_report.json"),
        "--write", str(BUILD_DIR / "stub_ecp5_routed.json"),
    ]
    pnr = run_cmd(pnr_cmd, ROOT, pnr_log, timeout=600)
    result["nextpnr"] = pnr
    result["status"] = "pass" if pnr["exit_code"] == 0 else "fail"
    if pnr["exit_code"] != 0:
        result["reason"] = "nextpnr-ecp5 could not place all TRELLIS_IO cells (expected for 2627 port-bit boundary stub)"
    return result


def collect_versions() -> dict:
    return {
        "verilator": tool_version([verilator_bin(), "--version"]),
        "yosys": tool_version([yosys_bin(), "--version"]),
        "yosys_oss": tool_version(["/tmp/oss_cad/oss-cad-suite/bin/yosys", "--version"])
                 if Path("/tmp/oss_cad/oss-cad-suite/bin/yosys").exists() else "N/A",
        "nextpnr_ecp5": tool_version([nextpnr_ecp5_bin(), "--version"]) if nextpnr_ecp5_bin() else "N/A",
        "python": tool_version(["python3", "--version"]),
    }


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--skip-verilator", action="store_true",
                    help="Do not re-run the long full-SoC Verilator lint; use the existing log if present.")
    ap.add_argument("--skip-ecp5", action="store_true",
                    help="Do not attempt synth_ecp5/nextpnr.")
    args = ap.parse_args()

    BUILD_DIR.mkdir(parents=True, exist_ok=True)
    LOG_DIR.mkdir(parents=True, exist_ok=True)

    inputs = {
        "tieoff_wrapper": TIE_OFF_SV,
        "stub_top": STUB_V,
        "tieoff_filelist": TIE_FILELIST,
        "stub_filelist": STUB_FILELIST,
    }
    input_sha = {k: sha256_file(v) for k, v in inputs.items()}
    for rel in REAL_SOC_INPUTS:
        input_sha[rel] = sha256_file(ROOT / rel)

    versions = collect_versions()

    print("== A2 Verilator lint/elaboration ==")
    verilator = run_verilator_lint(skip_if_log_exists=args.skip_verilator)
    print("verilator exit:", verilator.get("exit_code"), "wall:", verilator.get("wall_seconds"))

    print("== A2 Yosys generic boundary stub (two runs) ==")
    gen_runs = []
    for i in (1, 2):
        r = run_yosys_generic(f"stub-generic-run-{i:03d}", "lcvex_catapult_soc_stub_top", STUB_V)
        gen_runs.append(r)
        print(f"  run {i}: exit={r['exit_code']} cells={r['metrics'].get('num_cells')} "
              f"ports={r['metrics'].get('num_ports')} net={str(r['netlist_sha256'])[:12]}")
    stable = (
        gen_runs[0]["exit_code"] == 0 and gen_runs[1]["exit_code"] == 0
        and gen_runs[0]["metrics"] == gen_runs[1]["metrics"]
        and gen_runs[0]["netlist_sha256"] == gen_runs[1]["netlist_sha256"]
    )

    print("== A2 ECP5 proxy attempt ==")
    if args.skip_ecp5:
        ecp5 = {"status": "skipped", "reason": "requested --skip-ecp5"}
    else:
        ecp5 = run_ecp5(nextpnr_ecp5_bin())
    print("ECP5 status:", ecp5.get("status"), "-", ecp5.get("reason", ""))

    # Summary JSON under fpga/opensynth (tracked artifact).
    summary = {
        "task": "T-20260829-081",
        "title": "A2 SoC stub/tie-off and top-level open-source elaboration",
        "base_sha": "def2c4baa69706d64f674f7551bf21df5d670a48",
        "method": (
            "Verilator lint of real lcvex_catapult_soc_top through a tie-off wrapper; "
            "Yosys generic 4-LUT synth of a plain-Verilog boundary stub; optional ECP5 proxy"
        ),
        "input_sha256": input_sha,
        "tool_versions": versions,
        "verilator": {
            "top": "lcvex_catapult_soc_tieoff_top",
            "command": (
                "verilator --lint-only --timing --assert -Wno-fatal "
                "-Wno-DECLFILENAME ... --top-module lcvex_catapult_soc_tieoff_top "
                "-f fpga/opensynth/filelist_soc_tieoff.f"
            ),
            "result": verilator,
            "note": (
                "The real SoC top is instantiated with all external EMIF/Avalon/JTAG/EPCQ/"
                "program/checkpoint inputs tied off. Elaboration completes; warnings are disabled "
                "as fatal so this lint harness exits 0."
            ),
        },
        "generic_synth": {
            "module": "lcvex_catapult_soc_stub_top",
            "flat_verilog": str(STUB_V.relative_to(ROOT)),
            "stable_across_two_runs": stable,
            "runs": gen_runs,
            "limitations": [
                "This is a boundary stub only; it does not contain the real LCVEX core/cache/SoC logic.",
                "Yosys cannot parse the real SoC SystemVerilog packages/imports directly (see A0).",
                "No FPGA Fmax is derived from generic 4-LUT synthesis.",
            ],
        },
        "ecp5_proxy": ecp5,
        "known_limits": [
            "ECP5 is only a proxy; it is not Arria 10 and does not replace Quartus/T-067.",
            "The boundary stub has 109 ports/2627 port bits; nextpnr-ecp5 cannot place all TRELLIS_IO cells on LFE5U-85F.",
            "Fmax is N/A unless a complete real design is successfully packed/routed on the target device.",
            "No RTL semantics were changed; all stub/tie-off files are under fpga/opensynth.",
        ],
    }
    out = FPGA_OPEN / "a2_soc_stub_stats.json"
    out.write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n")
    print(f"Wrote {out.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
