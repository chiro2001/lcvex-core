#!/usr/bin/env bash
set -u
REPO=/home/chiro/projects/mycpu/lcvex-wt-T-20260829-090
cd "$REPO"
export TMPDIR="$REPO/tmp_build"
V=/home/chiro/miniforge3/envs/lcvex/bin/verilator
start=$(date +%s.%N)
timeout 300 "$V" --binary --timing --assert -j 2 --top-module lcvex_c2_dualcore_tb \
  -Mdir tmp_build/dual_default -o lcvex_c2_dualcore_tb \
  -f rtl/filelist.f rtl/lcvex_cluster_pkg.sv rtl/lcvex_l2_cluster.sv rtl/lcvex_core_wrap.sv rtl/lcvex_cluster_top.sv tb/sv/lcvex_c2_dualcore_tb.sv \
  > diag/verilator_stuck/logs/dual_default.log 2> diag/verilator_stuck/logs/dual_default.err
rc=$?
end=$(date +%s.%N)
el=$(awk -v s="$start" -v e="$end" 'BEGIN { printf "%.3f", e-s }')
echo "dual_default rc=$rc wall=${el}s $(date +%H:%M:%S)" | tee diag/verilator_stuck/logs/dual_default.time
