#!/usr/bin/env bash
set -u
REPO=/home/chiro/projects/mycpu/lcvex-wt-T-20260829-090
cd "$REPO"
export TMPDIR="$REPO/tmp_build"
V=/home/chiro/miniforge3/envs/lcvex/bin/verilator
run() {
  name="$1"; shift
  start=$(date +%s.%N)
  timeout 300 "$V" "$@" > "diag/verilator_stuck/logs/$name.log" 2> "diag/verilator_stuck/logs/$name.err"
  rc=$?
  end=$(date +%s.%N)
  el=$(awk -v s="$start" -v e="$end" 'BEGIN { printf "%.3f", e-s }')
  echo "$name rc=$rc wall=${el}s $(date +%H:%M:%S)"
  echo "$name rc=$rc wall=${el}s" >> diag/verilator_stuck/logs/l2_scale.times
}
: > diag/verilator_stuck/logs/l2_scale.times
run l2-16-wf --lint-only --no-assert --no-timing -Wno-fatal --top-module lcvex_l2_cluster -GMEM_LINES=16 rtl/lcvex_pkg.sv rtl/lcvex_cluster_pkg.sv rtl/lcvex_l2_cluster.sv
run l2-256-wf --lint-only --no-assert --no-timing -Wno-fatal --top-module lcvex_l2_cluster -GMEM_LINES=256 rtl/lcvex_pkg.sv rtl/lcvex_cluster_pkg.sv rtl/lcvex_l2_cluster.sv
run l2-1024-wf --lint-only --no-assert --no-timing -Wno-fatal --top-module lcvex_l2_cluster -GMEM_LINES=1024 rtl/lcvex_pkg.sv rtl/lcvex_cluster_pkg.sv rtl/lcvex_l2_cluster.sv
run l2-1024-wf-assert --lint-only --timing --assert -Wno-fatal --top-module lcvex_l2_cluster -GMEM_LINES=1024 rtl/lcvex_pkg.sv rtl/lcvex_cluster_pkg.sv rtl/lcvex_l2_cluster.sv
