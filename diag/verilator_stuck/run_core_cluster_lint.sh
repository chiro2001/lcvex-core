#!/usr/bin/env bash
set -u
REPO=/home/chiro/projects/mycpu/lcvex-wt-T-20260829-090
cd "$REPO"
export TMPDIR="$REPO/tmp_build"
V=/home/chiro/miniforge3/envs/lcvex/bin/verilator
MC="rtl/lcvex_pkg.sv rtl/lcvex_fp_state.sv rtl/lcvex_fp_scalar.sv rtl/lcvex_neon_fp.sv rtl/lcvex_neon_int.sv rtl/lcvex_alu.sv rtl/lcvex_muldiv.sv rtl/lcvex_decode.sv rtl/lcvex_mmu.sv rtl/lcvex_core.sv rtl/lcvex_mem_ram.sv rtl/lcvex_mem_arb.sv rtl/lcvex_cluster_pkg.sv rtl/lcvex_core_wrap.sv rtl/lcvex_cluster_top.sv"
C2EXTRA="rtl/lcvex_l1_coherence.sv rtl/lcvex_l2_cluster.sv"
run() {
  name="$1"; shift
  start=$(date +%s.%N)
  timeout 1800 "$V" "$@" > "diag/verilator_stuck/logs/$name.log" 2> "diag/verilator_stuck/logs/$name.err"
  rc=$?
  end=$(date +%s.%N)
  el=$(awk -v s="$start" -v e="$end" 'BEGIN { printf "%.3f", e-s }')
  echo "$name rc=$rc wall=${el}s $(date +%H:%M:%S)"
  echo "$name rc=$rc wall=${el}s" >> diag/verilator_stuck/logs/core_cluster_lint.times
}
: > diag/verilator_stuck/logs/core_cluster_lint.times
# single core top
run core-min-noassert --lint-only --no-assert --no-timing -Wno-fatal --top-module lcvex_core $MC
run core-min-assert --lint-only --timing --assert -Wno-fatal --top-module lcvex_core $MC
# C1 shell (no coherence)
run cluster1-noassert --lint-only --no-assert --no-timing -Wno-fatal --top-module lcvex_cluster_top -GCORE_COUNT=1 $MC
# C1 shell dual
run cluster2-noassert --lint-only --no-assert --no-timing -Wno-fatal --top-module lcvex_cluster_top -GCORE_COUNT=2 $MC
# C2 coherent shell dual (default MEM_DEPTH 65536 => MEM_LINES 1024)
run cluster2-coh-noassert --lint-only --no-assert --no-timing -Wno-fatal --top-module lcvex_cluster_top -GCORE_COUNT=2 -GCOHERENCE_ENABLE=1 $MC $C2EXTRA
run cluster2-coh-assert --lint-only --timing --assert -Wno-fatal --top-module lcvex_cluster_top -GCORE_COUNT=2 -GCOHERENCE_ENABLE=1 $MC $C2EXTRA
