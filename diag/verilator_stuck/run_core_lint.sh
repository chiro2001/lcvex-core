#!/usr/bin/env bash
set -u
REPO=/home/chiro/projects/mycpu/lcvex-wt-T-20260829-090
cd "$REPO"
export TMPDIR="$REPO/tmp_build"
V=/home/chiro/miniforge3/envs/lcvex/bin/verilator
MC="rtl/lcvex_pkg.sv rtl/lcvex_fp_state.sv rtl/lcvex_fp_scalar.sv rtl/lcvex_neon_fp.sv rtl/lcvex_neon_int.sv rtl/lcvex_alu.sv rtl/lcvex_muldiv.sv rtl/lcvex_decode.sv rtl/lcvex_mmu.sv rtl/lcvex_core.sv"
run() {
  name="$1"; shift
  start=$(date +%s.%N)
  timeout 1800 "$V" "$@" > "diag/verilator_stuck/logs/$name.log" 2> "diag/verilator_stuck/logs/$name.err"
  rc=$?
  end=$(date +%s.%N)
  el=$(awk -v s="$start" -v e="$end" 'BEGIN { printf "%.3f", e-s }')
  echo "$name rc=$rc wall=${el}s $(date +%H:%M:%S)"
  echo "$name rc=$rc wall=${el}s" >> diag/verilator_stuck/logs/core_lint.times
}
: > diag/verilator_stuck/logs/core_lint.times
run core-noassert --lint-only --no-assert --no-timing -Wno-fatal --top-module lcvex_core $MC
run core-assert --lint-only --timing --assert -Wno-fatal --top-module lcvex_core $MC
