#!/usr/bin/env python3
"""A1 generic-synth proxy: flatten selected LCVEX RTL, run Yosys/ABC twice,
and emit reproducible stats JSON.

Scope: only fpga/opensynth/** and build/tmp/opensynth/** are written.
No RTL source files are modified.
"""
from __future__ import annotations

import hashlib
import json
import re
import shutil
import subprocess
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
FPGA_OPEN = ROOT / "fpga" / "opensynth"
GEN_DIR = FPGA_OPEN / "generated"
BUILD_DIR = ROOT / "build" / "tmp" / "opensynth"

TOOL_TIMEOUT_S = 300


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def sha256_text(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def tool_versions() -> dict:
    def run(cmd):
        try:
            p = subprocess.run(
                cmd, cwd=str(ROOT), stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT, text=True, timeout=20
            )
            return p.stdout.strip().splitlines()[0] if p.stdout.strip() else ""
        except Exception:
            return ""

    def run_full(cmd):
        try:
            p = subprocess.run(
                cmd, cwd=str(ROOT), stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT, text=True, timeout=20
            )
            return p.stdout.strip()
        except Exception:
            return ""

    abc_out = run_full(["abc", "-x", "-c", "version"])
    (ROOT / "abc.history").unlink(missing_ok=True)
    abc_ver = ""
    for line in abc_out.splitlines():
        if "ABC" in line and ("1." in line or "compiled" in line):
            abc_ver = line.strip()
            break
    if not abc_ver:
        abc_ver = abc_out.strip()
    return {
        "yosys": run(["yosys", "--version"]),
        "abc": abc_ver,
        "python": run(["python3", "--version"]),
    }


def package_body(path: Path) -> str:
    """Return the text between the package declaration and endpackage."""
    text = path.read_text()
    m = re.search(r"package\s+(\w+)\s*;(.*?)\s*endpackage", text, re.S)
    if not m:
        raise RuntimeError(f"cannot extract package body from {path}")
    return m.group(2).strip() + "\n"


def no_import_and_qualifiers(text: str, package_names: list[str]) -> str:
    for pkg in package_names:
        text = re.sub(rf"^\s*import\s+{re.escape(pkg)}\s*::\s*\*\s*;\s*$",
                      "", text, flags=re.M)
        text = text.replace(f"{pkg}::", "")
    return text


def transform_mem_arb(text: str) -> str:
    old_func = """  function automatic logic [$clog2(PORTS)-1:0] prio_sel(input logic [PORTS-1:0] v);
    for (int i = 0; i < PORTS; i++) begin
      if (v[i]) return i[$clog2(PORTS)-1:0];  // 最低索引 = 最高优先级
    end
    return '0;
  endfunction
"""
    new_func = """  function automatic logic [$clog2(PORTS)-1:0] prio_sel(input logic [PORTS-1:0] v);
    logic found;
    begin
      prio_sel = '0;
      found = 1'b0;
      for (int i = 0; i < PORTS; i++) begin
        if (!found && v[i]) begin
          prio_sel = i[$clog2(PORTS)-1:0];  // 最低索引 = 最高优先级
          found = 1'b1;
        end
      end
    end
  endfunction
"""
    if old_func not in text:
        raise RuntimeError("mem_arb prio_sel transform pattern not found")
    text = text.replace(old_func, new_func)

    old_rsp = """  always_comb begin
    rsp_valid = '0;
    rsp       = '{PORTS{'0}};
    if (in_flight && mem_rsp_valid) begin
      rsp_valid[sel_r] = 1'b1;
      rsp[sel_r]       = mem_rsp;
    end
  end
"""
    # PORTS is 3 in this A1 proxy.  The explicit assigns avoid latches in Yosys's
    # handling of arrays of packed structs while preserving the same routing.
    new_rsp = """  assign rsp_valid = (in_flight && mem_rsp_valid) ? (3'b001 << sel_r) : 3'b000;
  assign rsp[0] = (in_flight && mem_rsp_valid && sel_r == 2'd0) ? mem_rsp : '0;
  assign rsp[1] = (in_flight && mem_rsp_valid && sel_r == 2'd1) ? mem_rsp : '0;
  assign rsp[2] = (in_flight && mem_rsp_valid && sel_r == 2'd2) ? mem_rsp : '0;
"""
    if old_rsp not in text:
        raise RuntimeError("mem_arb response transform pattern not found")
    text = text.replace(old_rsp, new_rsp)
    return text


MODULES = {
    "lcvex_axi4_master": {
        "packages": ["rtl/lcvex_axi4_pkg.sv"],
        "source": "rtl/lcvex_axi4_master.sv",
        "top": "lcvex_axi4_master",
        "config": {"ADDR_WIDTH": 64, "DATA_WIDTH": 128, "ID_WIDTH": 4, "MAX_BURST_LEN": 16},
        "transforms": [],
    },
    "lcvex_mem_delay": {
        "packages": ["rtl/lcvex_pkg.sv"],
        "source": "rtl/lcvex_mem_delay.sv",
        "top": "lcvex_mem_delay",
        "config": {"DELAY_MODE": 1, "RAND_MAX": 4, "SEED": "8'hA5"},
        "transforms": [
            ("parameter int DELAY_MODE = 0", "parameter int DELAY_MODE = 1"),
        ],
    },
    "lcvex_mem_arb": {
        "packages": ["rtl/lcvex_pkg.sv"],
        "source": "rtl/lcvex_mem_arb.sv",
        "top": "lcvex_mem_arb",
        "config": {"PORTS": 3},
        "transforms": [("__MEM_ARB__", "__MEM_ARB__")],  # handled specially
    },
}


def flatten_module(name: str, cfg: dict) -> Path:
    pkg_texts = [package_body(ROOT / p) for p in cfg["packages"]]
    mod_text = (ROOT / cfg["source"]).read_text()
    package_names = [Path(p).stem for p in cfg["packages"]]
    # package stem for lcvex_axi4_pkg is lcvex_axi4_pkg, correct.
    mod_text = no_import_and_qualifiers(mod_text, package_names)

    if name == "lcvex_mem_arb":
        mod_text = transform_mem_arb(mod_text)
    else:
        for old, new in cfg.get("transforms", []):
            if old not in mod_text:
                raise RuntimeError(f"{name}: transform pattern not found: {old}")
            mod_text = mod_text.replace(old, new)

    header = (
        "// Generated by scripts/opensynth/run_opensynth_a1.py\n"
        f"// Source packages: {', '.join(cfg['packages'])}\n"
        f"// Source module: {cfg['source']}\n"
        "// This is a flat/opened Yosys-readable proxy view. RTL semantics are not changed.\n"
    )
    text = header + "\n".join(pkg_texts) + "\n" + mod_text
    out = GEN_DIR / f"{name}_flat.v"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(text)
    return out


def parse_stat(log_text: str) -> dict:
    # The Yosys JSON block begins with a line that is exactly '{' followed by
    # an indented "creator" key.
    idx = log_text.rfind('\n{\n   "creator"')
    if idx < 0:
        raise RuntimeError("stat -json block not found in Yosys log")
    dec = json.JSONDecoder()
    obj, _ = dec.raw_decode(log_text[idx + 1:])
    return obj


def extract_metrics(log_text: str, module: str) -> dict:
    stat = parse_stat(log_text)
    mod_stat = stat["modules"][f"\\{module}"]
    cells = mod_stat.get("num_cells_by_type", {})
    lut = int(cells.get("$lut", 0))
    ff = sum(int(v) for k, v in cells.items() if k.startswith("$_DFF"))
    abc_matches = re.findall(r"ABC RESULTS:\s+\$lut cells:\s+(\d+)", log_text)
    abc_lut = int(abc_matches[-1]) if abc_matches else None
    return {
        "num_wires": mod_stat.get("num_wires"),
        "num_wire_bits": mod_stat.get("num_wire_bits"),
        "num_ports": mod_stat.get("num_ports"),
        "num_port_bits": mod_stat.get("num_port_bits"),
        "num_memories": mod_stat.get("num_memories", 0),
        "num_memory_bits": mod_stat.get("num_memory_bits", 0),
        "num_cells": mod_stat.get("num_cells"),
        "num_cells_by_type": cells,
        "lut4": lut,
        "dff": ff,
        "ram_bits": mod_stat.get("num_memory_bits", 0),
        "dsp": "N/A",
        "area": "N/A",
        "abc_report_lut": abc_lut,
    }


def run_yosys(flat: Path, module: str, cfg: dict, run_dir: Path) -> dict:
    run_dir.mkdir(parents=True, exist_ok=True)
    script = (
        f"read_verilog -sv {flat}\n"
        f"synth -top {module} -lut 4\n"
        "write_verilog -noattr -noexpr netlist.v\n"
        "stat -json\n"
    )
    script_path = run_dir / "synth.ys"
    script_path.write_text(script)
    cmd = ["yosys", "-s", str(script_path)]
    t0 = time.time()
    p = subprocess.run(
        cmd, cwd=str(run_dir), stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT, text=True, timeout=TOOL_TIMEOUT_S
    )
    wall = time.time() - t0
    log = run_dir / "yosys.log"
    log.write_text(p.stdout)
    if p.returncode != 0:
        raise RuntimeError(
            f"Yosys failed for {module} rc={p.returncode}\n{p.stdout[-4000:]}"
        )
    netlist = run_dir / "netlist.v"
    return {
        "exit_code": p.returncode,
        "wall_seconds": round(wall, 3),
        "yosys_log_sha256": sha256_file(log),
        "netlist_sha256": sha256_file(netlist),
        "netlist_bytes": netlist.stat().st_size,
        "metrics": extract_metrics(p.stdout, module),
    }


def main() -> int:
    (ROOT / "abc.history").unlink(missing_ok=True)
    GEN_DIR.mkdir(parents=True, exist_ok=True)
    BUILD_DIR.mkdir(parents=True, exist_ok=True)
    versions = tool_versions()
    all_runs = {}
    for name, cfg in MODULES.items():
        flat = flatten_module(name, cfg)
        cfg["flat"] = str(flat.relative_to(ROOT))
        cfg["source_sha256"] = {
            str(p): sha256_file(ROOT / p) for p in cfg["packages"] + [cfg["source"]]
        }
        cfg["flat_sha256"] = sha256_file(flat)
        cfg["tool"] = versions
        runs = []
        for i in (1, 2):
            run_dir = BUILD_DIR / name / f"run-{i:03d}"
            if run_dir.exists():
                shutil.rmtree(run_dir)
            run = run_yosys(flat, name, cfg, run_dir)
            run["run_id"] = f"owner-{name}-run{i:02d}"
            per_run = run_dir / "run.json"
            per_run.write_text(json.dumps(run, indent=2, sort_keys=True) + "\n")
            runs.append(run)
            print(f"{name} run {i}: LUT={run['metrics']['lut4']} "
                  f"FF={run['metrics']['dff']} net={run['netlist_sha256'][:12]}")
        stable = (
            runs[0]["metrics"] == runs[1]["metrics"]
            and runs[0]["netlist_sha256"] == runs[1]["netlist_sha256"]
        )
        all_runs[name] = {
            "top": cfg["top"],
            "config": cfg["config"],
            "source_files": cfg["packages"] + [cfg["source"]],
            "source_sha256": cfg["source_sha256"],
            "flat_file": cfg["flat"],
            "flat_sha256": cfg["flat_sha256"],
            "tool": versions,
            "stable_across_two_runs": stable,
            "runs": runs,
        }
    summary = {
        "task": "T-20260829-080",
        "title": "A1 generic Yosys/ABC synthesis proxy for LCVEX RTL",
        "workspace": str(ROOT),
        "base_sha": "3d717e763209923f5ddaedeeeafa9d0b9985ba6c",
        "toolchain": versions,
        "method": "Yosys read_verilog -sv flat view; synth -top <module> -lut 4; write_verilog; stat -json",
        "limitations": [
            "Generic 4-LUT mapping is not an FPGA architectural resource report.",
            "LUT/FF are synth proxy counts, not Arria 10/ECP5 vendor results.",
            "RAM/DSP/area are N/A: no device memory/DSP mapping was performed.",
            "DO NOT use ABC delay as Fmax.",
            "lcvex_l2 and lcvex_core not run in this task (see handoff for blockers).",
        ],
        "modules": all_runs,
    }
    out = FPGA_OPEN / "a1_generic_synth_stats.json"
    out.write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n")
    print(f"Wrote {out.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
