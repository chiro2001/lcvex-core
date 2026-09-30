#!/usr/bin/env python3
"""F0 performance/cache configuration matrix runner.

This script is the reproducible entry point for the PE-F0 baseline matrix.
It builds Verilator runners for the requested cache/delay configurations (one
heavy build at a time), builds baremetal perf images, runs the selected P-line
workloads, and writes per-run JSON plus a matrix aggregate.

Usage:
  python3 scripts/run_perf_matrix.py --workloads alu_latency,ctrl_branch,mem_seq \
      --configs nocache_d0,l1i_d0,l1id_l2_d0 --skip-build
  python3 scripts/run_perf_matrix.py --configs all --workloads all
"""

import argparse
import csv
import hashlib
import json
import os
import shutil
import subprocess
import sys

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
COMMIT_DIGEST_SCHEMA = "lcvex-commit-digest-v2-active-payload"


def measurement_source_sha() -> str:
    r = subprocess.run(["git", "-C", REPO, "rev-parse", "HEAD"],
                       capture_output=True, text=True, check=True)
    return r.stdout.strip()


def require_clean_source() -> None:
    r = subprocess.run(["git", "-C", REPO, "status", "--porcelain"],
                       capture_output=True, text=True, check=True)
    if r.stdout.strip():
        raise SystemExit("measurement source must be a clean Git worktree")


def source_sha(name: str) -> str:
    """Hash the source inputs used to build one perf workload image."""
    base = name[2:] if name.startswith("t_") else name
    base = base[:-2] if base.endswith(".c") else base
    rels = [
        f"baremetal/perf/t_{base}.c",
        "baremetal/perf/perf_common.h",
        "baremetal/tests.h",
        "baremetal/microbench_main.c",
        "baremetal/startup_mb.s",
        "baremetal/link.ld",
        "scripts/build-microbench.sh",
        "Makefile",
        "sim/microbench/commit_digest.h",
        "sim/microbench/microbench_runner.cc",
        "sim/microbench/perf_runner.py",
    ]
    h = hashlib.sha256()
    for rel in sorted(rels):
        path = os.path.join(REPO, rel)
        if os.path.isfile(path):
            h.update(rel.encode("utf-8"))
            h.update(b"\0")
            with open(path, "rb") as f:
                h.update(f.read())
            h.update(b"\0")
    return h.hexdigest()

BASE_CONFIGS = {
    "nocache_d0": {"I": 0, "D": 0, "L2": 0, "delay": 0},
    "l1i_d0": {"I": 1, "D": 0, "L2": 0, "delay": 0},
    "l1d_d0": {"I": 0, "D": 1, "L2": 0, "delay": 0},
    "l1id_d0": {"I": 1, "D": 1, "L2": 0, "delay": 0},
    "l1id_l2_d0": {"I": 1, "D": 1, "L2": 1, "delay": 0},
    "nocache_d1": {"I": 0, "D": 0, "L2": 0, "delay": 1},
    "nocache_d2": {"I": 0, "D": 0, "L2": 0, "delay": 2},
    "fullcache_d1": {"I": 1, "D": 1, "L2": 1, "delay": 1},
    "fullcache_d2": {"I": 1, "D": 1, "L2": 1, "delay": 2},
}

# F1c measures each cache/delay point as an off/on pair.  Keep the historical
# base definitions above for explicit compatibility, but every canonical
# matrix identity includes the FIFO mode so runner paths can never alias.
MATRIX_BASE_CONFIGS = [
    "nocache_d0", "l1i_d0", "l1id_l2_d0", "nocache_d1",
    "nocache_d2", "fullcache_d1", "fullcache_d2",
]
FIFO_CONFIGS = {"f0": 0, "f1a": 1}
CONFIGS = {}
for _base_name, _base_cfg in BASE_CONFIGS.items():
    for _fifo_name, _fifo_enable in FIFO_CONFIGS.items():
        _cfg_name = f"{_base_name}_{_fifo_name}"
        CONFIGS[_cfg_name] = {
            **_base_cfg,
            "base_config": _base_name,
            "fifo": _fifo_name,
            "fetch_fifo_enable": _fifo_enable,
        }

ALL_WORKLOADS = [
    "alu_latency", "alu_ilp", "ctrl_branch", "muldiv",
    "mem_seq", "mem_random", "mem_ldst",
    "fp_scalar", "fp_fp16", "neon_vect",
    "kernel_crc", "kernel_hash", "kernel_matmul", "kernel_sort",
]


def sh(args: list, **kwargs):
    print("+", " ".join(args), flush=True)
    return subprocess.run(args, cwd=REPO, **kwargs)


def expand_configs(spec: str) -> list:
    names = []
    for item in spec.split(","):
        item = item.strip()
        if not item:
            continue
        if item == "all":
            bases = MATRIX_BASE_CONFIGS
            names.extend(f"{base}_{fifo}" for base in bases
                         for fifo in FIFO_CONFIGS)
        elif item in BASE_CONFIGS:
            names.extend(f"{item}_{fifo}" for fifo in FIFO_CONFIGS)
        elif item in CONFIGS:
            names.append(item)
        else:
            raise SystemExit(f"unknown config {item}")
    return names


def build_workload(name: str) -> str:
    out = f"build/microbench/perf_{name}.bin"
    r = sh(["make", "perf-build", f"PERF_NAME={name}"])
    if r.returncode != 0:
        raise RuntimeError(f"perf build failed for {name}")
    return out


def build_runner(cfg: str, measurement_sha: str) -> str:
    c = CONFIGS[cfg]
    d = f"build/microbench_runner_{cfg}"
    exe = os.path.join(d, "microbench_runner")
    manifest = os.path.join(d, "runner_manifest.json")
    if os.path.isfile(exe) and os.path.isfile(manifest):
        try:
            with open(manifest, "r", encoding="utf-8") as f:
                old = json.load(f)
            if (old.get("measurement_source_sha") == measurement_sha and
                    old.get("config") == cfg and
                    old.get("cache_config") == c):
                return exe
        except (OSError, json.JSONDecodeError):
            pass
    os.makedirs(d, exist_ok=True)
    r = sh([
        "make", "VERILATOR_JOBS=1",
        f"PERF_RUNNER_DIR={d}",
        f"PERF_I_L1={c['I']}",
        f"PERF_D_L1={c['D']}",
        f"PERF_L2={c['L2']}",
        f"PERF_MEM_DELAY_MODE={c['delay']}",
        f"PERF_FETCH_FIFO_ENABLE={c['fetch_fifo_enable']}",
        "microbench-build-config",
    ])
    if r.returncode != 0:
        raise RuntimeError(f"runner build failed for {cfg}")
    with open(manifest, "w", encoding="utf-8") as f:
        json.dump({"config": cfg, "cache_config": c,
                   "measurement_source_sha": measurement_sha}, f,
                  indent=2, ensure_ascii=False)
        f.write("\n")
    return exe


def run_one(exe: str, workload: str, cfg: str, out_dir: str,
            max_cycles: int, measurement_sha: str) -> dict:
    image = f"build/microbench/perf_{workload}.bin"
    os.makedirs(out_dir, exist_ok=True)
    out = os.path.join(out_dir, f"{workload}.json")
    c = CONFIGS[cfg]
    source = source_sha(workload)
    with open(os.devnull, "w", encoding="utf-8") as devnull:
        r = subprocess.run([
            "python3", "sim/microbench/perf_runner.py",
            "--runner", exe,
            "--image", image,
            "--name", workload,
            "--max-cycles", str(max_cycles),
            "--git-sha", measurement_sha,
            "--measurement-source-sha", measurement_sha,
            "--source-sha", source,
            "--param", f"BASE_CONFIG={c['base_config']}",
            "--param", f"I_L1={c['I']}",
            "--param", f"D_L1={c['D']}",
            "--param", f"L2={c['L2']}",
            "--param", f"MEM_DELAY_MODE={c['delay']}",
            "--param", f"FETCH_FIFO_ENABLE={c['fetch_fifo_enable']}",
            "--param", "FETCH_FIFO_DEPTH=2",
            "--param", f"FIFO_VARIANT={c['fifo']}",
            "--out", out,
        ], cwd=REPO, stdout=devnull, stderr=subprocess.PIPE, text=True)
    if r.returncode != 0:
        print(f"WARN: run failed for {cfg}/{workload}", file=sys.stderr)
    if not os.path.isfile(out):
        return {
            "name": workload,
            "config": cfg,
            "cache_config": CONFIGS[cfg],
            "measurement_source_sha": measurement_sha,
            "status": "error",
            "returncode": r.returncode,
            "error": r.stderr.strip(),
        }
    with open(out, "r", encoding="utf-8") as f:
        data = json.load(f)
    if data.get("commit_digest_schema") != COMMIT_DIGEST_SCHEMA:
        data["status"] = "error"
        data["returncode"] = 2
        data["error"] = (
            "commit digest schema mismatch: expected "
            f"{COMMIT_DIGEST_SCHEMA}, got "
            f"{data.get('commit_digest_schema')!r}"
        )
        data["provenance_error"] = "digest_schema_mismatch"
    data["config"] = cfg
    data["cache_config"] = CONFIGS[cfg]
    data["measurement_source_sha"] = measurement_sha
    return data


def aggregate_existing(out_root: str, cfg_names: list, workloads: list,
                       measurement_sha: str) -> list:
    rows = []
    for cfg in cfg_names:
        for wl in workloads:
            path = os.path.join(out_root, cfg, f"{wl}.json")
            if not os.path.isfile(path):
                print(f"WARN: missing {path}", file=sys.stderr)
                continue
            with open(path, "r", encoding="utf-8") as f:
                row = json.load(f)
            if row.get("commit_digest_schema") != COMMIT_DIGEST_SCHEMA:
                raise SystemExit(
                    "digest schema mismatch in aggregate input "
                    f"{path}: expected {COMMIT_DIGEST_SCHEMA}, got "
                    f"{row.get('commit_digest_schema')!r}"
                )
            row["config"] = cfg
            row["cache_config"] = CONFIGS[cfg]
            row["measurement_source_sha"] = row.get("measurement_source_sha",
                                                     measurement_sha)
            rows.append(row)
    return rows


def require_digest_schema(rows: list[dict]) -> None:
    """Reject mixed/legacy digest contracts before writing a matrix."""
    invalid = [
        f"{row.get('config')}/{row.get('name')}:"
        f"{row.get('commit_digest_schema')!r}"
        for row in rows
        if row.get("commit_digest_schema") != COMMIT_DIGEST_SCHEMA
    ]
    if invalid:
        raise SystemExit(
            "digest schema provenance mismatch; expected "
            f"{COMMIT_DIGEST_SCHEMA}: " + ", ".join(invalid[:8])
        )


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--configs", default=",".join(MATRIX_BASE_CONFIGS))
    ap.add_argument("--workloads", default="alu_latency,ctrl_branch,mem_seq,kernel_crc")
    ap.add_argument("--max-cycles", type=int, default=5000000)
    ap.add_argument("--skip-build", action="store_true")
    ap.add_argument("--out-dir", default="build/perf_matrix")
    ap.add_argument("--cgroup", action="store_true",
                    help="wrap heavy Verilator builds in systemd-run MemoryMax=15G/MemorySwapMax=0")
    ap.add_argument("--aggregate-only", action="store_true",
                    help="do not build/run; aggregate existing per-run JSON files")
    ap.add_argument("--artifact-dir", default="",
                    help="optional directory for a copy of matrix.json/matrix.csv")
    args = ap.parse_args()

    require_clean_source()
    measurement_sha = measurement_source_sha()
    cfg_names = expand_configs(args.configs)
    workloads = []
    for item in args.workloads.split(","):
        item = item.strip()
        if item == "all":
            workloads.extend(ALL_WORKLOADS)
        elif item:
            workloads.append(item)
    if not workloads:
        raise SystemExit("no workloads")

    out_root = os.path.join(REPO, args.out_dir)
    os.makedirs(out_root, exist_ok=True)
    all_rows = []

    if args.aggregate_only:
        all_rows = aggregate_existing(out_root, cfg_names, workloads,
                                      measurement_sha)
    else:
        if not args.skip_build:
            # Build each identical workload image once, then pair it with every
            # FIFO/cache/delay runner. This prevents accidental image drift
            # between f0 and f1a while avoiding redundant cross-product builds.
            for wl in workloads:
                build_workload(wl)
        for cfg in cfg_names:
            c = CONFIGS[cfg]
            exe = f"build/microbench_runner_{cfg}/microbench_runner"
            if not args.skip_build:
                exe = build_runner(cfg, measurement_sha)
            elif not os.path.isfile(exe):
                print(f"WARN: {exe} missing; skipping cfg {cfg}", file=sys.stderr)
                continue
            for wl in workloads:
                image = f"build/microbench/perf_{wl}.bin"
                if args.skip_build and not os.path.isfile(image):
                    print(f"WARN: {image} missing; skipping {wl}", file=sys.stderr)
                    continue
                run_dir = os.path.join(out_root, cfg)
                row = run_one(exe, wl, cfg, run_dir, args.max_cycles,
                              measurement_sha)
                all_rows.append(row)

    # Aggregate
    require_digest_schema(all_rows)
    agg = {
        "schema": "lcvex-perf-matrix-f1c-v1",
        "commit_digest_schema": COMMIT_DIGEST_SCHEMA,
        "sha": measurement_sha,
        "measurement_source_sha": measurement_sha,
        "provenance": {
            "repository": REPO,
            "measurement_source_sha": measurement_sha,
            "config_identity": "<base_config>_<f0|f1a>",
            "commit_digest_schema": COMMIT_DIGEST_SCHEMA,
            "same_image_per_workload": True,
            "f1b_enabled": False,
        },
        "configs": cfg_names,
        "workloads": workloads,
        "rows": all_rows,
    }
    with open(os.path.join(out_root, "matrix.json"), "w", encoding="utf-8") as f:
        json.dump(agg, f, indent=2, ensure_ascii=False)
        f.write("\n")

    csv_path = os.path.join(out_root, "matrix.csv")
    fields = ["config", "base_config", "fifo", "fetch_fifo_enable",
              "fetch_fifo_depth", "I_L1", "D_L1", "L2", "MEM_DELAY_MODE",
              "measurement_source_sha", "commit_digest_schema", "source_sha256", "image_sha256",
              "name", "status", "cycles", "retired_insn", "ipc",
              "commit_digest", "memory_digest", "committed_memory_effects",
              "stall_if", "fetch_wait", "branch_flush", "mem_stall", "ptw_stall",
              "il1_hit", "il1_miss", "dl1_hit", "dl1_miss", "l2_hit", "l2_miss",
              "arb_req", "ram_req", "fetch_epoch_bumps", "fetch_epoch_final",
              "fetch_fifo_occupancy_max", "fetch_fifo_peak_signal_max",
              "fetch_fifo_push", "fetch_fifo_pop", "fetch_fifo_flush",
              "fetch_stale_drop", "fetch_stale_drain_cycles", "fetch_fifo_overflow"]
    with open(csv_path, "w", encoding="utf-8", newline="") as f:
        w = csv.DictWriter(f, fieldnames=fields, extrasaction="ignore")
        w.writeheader()
        for row in all_rows:
            r = {
                "config": row.get("config"),
                "measurement_source_sha": row.get("measurement_source_sha"),
                "commit_digest_schema": row.get("commit_digest_schema"),
                "source_sha256": row.get("source_sha256", row.get("source_hash")),
                "image_sha256": row.get("image_sha256", row.get("image_hash")),
                "name": row.get("name"),
                "status": row.get("status"),
                "cycles": row.get("cycles"),
                "retired_insn": row.get("retired_insn"),
                "ipc": row.get("ipc"),
            }
            cfg = row.get("cache_config") or {}
            r.update({
                "base_config": cfg.get("base_config"),
                "fifo": cfg.get("fifo"),
                "fetch_fifo_enable": cfg.get("fetch_fifo_enable"),
                "fetch_fifo_depth": 2,
                "I_L1": cfg.get("I"),
                "D_L1": cfg.get("D"),
                "L2": cfg.get("L2"),
                "MEM_DELAY_MODE": cfg.get("delay"),
            })
            stable = row.get("stable_digest") or {}
            r.update({
                "commit_digest": row.get("commit_digest",
                                          stable.get("commit_packet")),
                "memory_digest": row.get("memory_digest",
                                          stable.get("memory_side_effect")),
                "committed_memory_effects": row.get(
                    "committed_memory_effects",
                    stable.get("committed_memory_effects")),
            })
            sc = row.get("stall_cycles") or {}
            r.update({
                "stall_if": sc.get("stall_if"),
                "fetch_wait": sc.get("fetch_wait"),
                "branch_flush": sc.get("branch_flush"),
                "mem_stall": sc.get("mem_stall"),
                "ptw_stall": sc.get("ptw_stall"),
            })
            cache = row.get("cache") or {}
            il1 = cache.get("il1") or {}
            dl1 = cache.get("dl1") or {}
            l2 = cache.get("l2") or {}
            r.update({
                "il1_hit": il1.get("hit", il1.get("read_hit")),
                "il1_miss": il1.get("miss", il1.get("read_miss")),
                "dl1_hit": dl1.get("read_hit"),
                "dl1_miss": dl1.get("read_miss"),
                "l2_hit": l2.get("read_hit"),
                "l2_miss": l2.get("read_miss"),
            })
            req = row.get("requests") or {}
            r.update({"arb_req": req.get("arb"), "ram_req": req.get("ram")})
            fetch = row.get("fetch_fifo") or {}
            r.update({
                "fetch_epoch_bumps": fetch.get("epoch_bumps"),
                "fetch_epoch_final": fetch.get("epoch_final"),
                "fetch_fifo_occupancy_max": fetch.get("occupancy_max"),
                "fetch_fifo_peak_signal_max": fetch.get("peak_signal_max"),
                "fetch_fifo_push": fetch.get("push"),
                "fetch_fifo_pop": fetch.get("pop"),
                "fetch_fifo_flush": fetch.get("flush"),
                "fetch_stale_drop": fetch.get("stale_drop"),
                "fetch_stale_drain_cycles": fetch.get("stale_drain_cycles"),
                "fetch_fifo_overflow": fetch.get("overflow"),
            })
            w.writerow(r)

    if args.artifact_dir:
        artifact_dir = os.path.join(REPO, args.artifact_dir)
        os.makedirs(artifact_dir, exist_ok=True)
        shutil.copyfile(os.path.join(out_root, "matrix.json"),
                        os.path.join(artifact_dir, "f1c_matrix.json"))
        shutil.copyfile(csv_path, os.path.join(artifact_dir, "f1c_matrix.csv"))

    print(f"Wrote {len(all_rows)} rows to {os.path.join(out_root, 'matrix.json')} and {csv_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
