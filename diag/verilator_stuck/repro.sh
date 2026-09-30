#!/usr/bin/env bash
# T-20260829-090 minimal reproducible diagnostic commands.
# Usage:
#   TIMEOUT=300 bash diag/verilator_stuck/repro.sh fp_scalar-default
#   TIMEOUT=300 bash diag/verilator_stuck/repro.sh fp_scalar-O0
#   TIMEOUT=600 bash diag/verilator_stuck/repro.sh core-default
#   TIMEOUT=600 bash diag/verilator_stuck/repro.sh dual-default
set -u
REPO=/home/chiro/projects/mycpu/lcvex-wt-T-20260829-090
cd "$REPO"
export TMPDIR="$REPO/tmp_build"
V=/home/chiro/miniforge3/envs/lcvex/bin/verilator
MC_CORE="rtl/lcvex_pkg.sv rtl/lcvex_fp_state.sv rtl/lcvex_fp_scalar.sv rtl/lcvex_neon_fp.sv rtl/lcvex_neon_int.sv rtl/lcvex_alu.sv rtl/lcvex_muldiv.sv rtl/lcvex_decode.sv rtl/lcvex_mmu.sv rtl/lcvex_core.sv"
MC_CLUSTER="$MC_CORE rtl/lcvex_mem_ram.sv rtl/lcvex_mem_arb.sv rtl/lcvex_cluster_pkg.sv rtl/lcvex_core_wrap.sv rtl/lcvex_cluster_top.sv"
C2EXTRA="rtl/lcvex_l1_coherence.sv rtl/lcvex_l2_cluster.sv"

run() {
  name="$1"; shift
  mkdir -p diag/verilator_stuck/logs
  start=$(date +%s.%N)
  timeout "${TIMEOUT:-300}" "$V" "$@" \
    > "diag/verilator_stuck/logs/$name.log" 2> "diag/verilator_stuck/logs/$name.err"
  rc=$?
  end=$(date +%s.%N)
  el=$(awk -v s="$start" -v e="$end" 'BEGIN { printf "%.3f", e-s }')
  echo "$name rc=$rc wall=${el}s"
}

case "${1:-}" in
  fp_scalar-default)
    run fp_scalar-default --lint-only --no-assert --no-timing -Wno-fatal \
      --top-module lcvex_fp_scalar rtl/lcvex_pkg.sv rtl/lcvex_fp_scalar.sv
    ;;
  fp_scalar-O0)
    run fp_scalar-O0 --lint-only --no-assert --no-timing -O0 -Wno-fatal \
      --top-module lcvex_fp_scalar rtl/lcvex_pkg.sv rtl/lcvex_fp_scalar.sv
    ;;
  core-default)
    run core-default --lint-only --no-assert --no-timing -Wno-fatal \
      --top-module lcvex_core $MC_CORE
    ;;
  core-O0)
    run core-O0 --lint-only --no-assert --no-timing -O0 -Wno-fatal \
      --top-module lcvex_core $MC_CORE
    ;;
  cluster2-nofp)
    run cluster2-nofp --lint-only --no-assert --no-timing -Wno-fatal \
      --top-module lcvex_cluster_top -GCORE_COUNT=2 \
      rtl/lcvex_pkg.sv rtl/lcvex_fp_state.sv diag/verilator_stuck/stubs/lcvex_fp_scalar_stub.sv \
      rtl/lcvex_neon_fp.sv rtl/lcvex_neon_int.sv rtl/lcvex_alu.sv rtl/lcvex_muldiv.sv \
      rtl/lcvex_decode.sv rtl/lcvex_mmu.sv rtl/lcvex_core.sv rtl/lcvex_mem_ram.sv \
      rtl/lcvex_mem_arb.sv rtl/lcvex_cluster_pkg.sv rtl/lcvex_core_wrap.sv rtl/lcvex_cluster_top.sv
    ;;
  dual-O0)
    run dual-O0 --binary --timing --assert -O0 -Wno-fatal -Wno-UNOPTFLAT \
      -j 2 --top-module lcvex_c2_dualcore_tb -Mdir tmp_build/dual_O0 \
      -o lcvex_c2_dualcore_tb \
      -f rtl/filelist.f rtl/lcvex_cluster_pkg.sv rtl/lcvex_l2_cluster.sv \
      rtl/lcvex_core_wrap.sv rtl/lcvex_cluster_top.sv tb/sv/lcvex_c2_dualcore_tb.sv
    ;;
  dual-default)
    run dual-default --binary --timing --assert -j 2 \
      --top-module lcvex_c2_dualcore_tb -Mdir tmp_build/dual_default \
      -o lcvex_c2_dualcore_tb \
      -f rtl/filelist.f rtl/lcvex_cluster_pkg.sv rtl/lcvex_l2_cluster.sv \
      rtl/lcvex_core_wrap.sv rtl/lcvex_cluster_top.sv tb/sv/lcvex_c2_dualcore_tb.sv
    ;;
  *)
    echo "usage: $0 {fp_scalar-default|fp_scalar-O0|core-default|core-O0|cluster2-nofp|dual-O0|dual-default}"
    exit 2
    ;;
esac
