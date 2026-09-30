#!/usr/bin/env bash
set -u
REPO=/home/chiro/projects/mycpu/lcvex-wt-T-20260829-090
cd "$REPO"
export TMPDIR="$REPO/tmp_build"
V=/home/chiro/miniforge3/envs/lcvex/bin/verilator
run() {
  name="$1"; shift
  start=$(date +%s.%N)
  timeout 300 "$V" --lint-only --no-assert --no-timing -Wno-fatal "$@" > "diag/verilator_stuck/logs/$name.log" 2> "diag/verilator_stuck/logs/$name.err"
  rc=$?
  end=$(date +%s.%N)
  el=$(awk -v s="$start" -v e="$end" 'BEGIN { printf "%.3f", e-s }')
  echo "$name rc=$rc wall=${el}s"
  echo "$name rc=$rc wall=${el}s" >> diag/verilator_stuck/logs/module_times
}
: > diag/verilator_stuck/logs/module_times
run decode --top-module lcvex_decode rtl/lcvex_pkg.sv rtl/lcvex_decode.sv &
run fp_scalar --top-module lcvex_fp_scalar rtl/lcvex_pkg.sv rtl/lcvex_fp_scalar.sv &
run neon_fp --top-module lcvex_neon_fp rtl/lcvex_pkg.sv rtl/lcvex_neon_fp.sv &
run neon_int --top-module lcvex_neon_int rtl/lcvex_pkg.sv rtl/lcvex_neon_int.sv &
run fp_state --top-module lcvex_fp_state rtl/lcvex_pkg.sv rtl/lcvex_fp_state.sv &
run mmu --top-module lcvex_mmu rtl/lcvex_pkg.sv rtl/lcvex_mmu.sv &
run alu --top-module lcvex_alu rtl/lcvex_pkg.sv rtl/lcvex_alu.sv &
run muldiv --top-module lcvex_muldiv rtl/lcvex_pkg.sv rtl/lcvex_muldiv.sv &
wait
