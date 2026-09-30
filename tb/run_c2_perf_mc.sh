#!/usr/bin/env bash
# Build and run the C2 dual-core performance workload TB.
# Usage: VERILATOR_BIN=/path/to/verilator tb/run_c2_perf_mc.sh
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO"

V="${VERILATOR_BIN:-verilator}"
if ! command -v "$V" >/dev/null 2>&1; then
    echo "error: verilator not found; set VERILATOR_BIN" >&2
    exit 2
fi
JOBS="${VERILATOR_JOBS:-1}"
MDIR="${MC_PERF_BUILD_DIR:-build/c2_perf_mc}"

mkdir -p "$MDIR"
"$V" --binary --timing --assert -j "$JOBS" \
    --top-module lcvex_c2_perf_mc_tb \
    -Mdir "$MDIR" -o lcvex_c2_perf_mc_tb \
    -f rtl/filelist.f \
    rtl/lcvex_cluster_pkg.sv rtl/lcvex_l2_cluster.sv \
    rtl/lcvex_core_wrap.sv rtl/lcvex_cluster_top.sv \
    tb/sv/lcvex_c2_perf_mc_tb.sv \
    -Wno-fatal -Wno-MODDUP -Wno-IMPLICITSTATIC -Wno-UNUSEDPARAM \
    -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNUSEDSIGNAL -Wno-SYNCASYNCNET

./"$MDIR"/lcvex_c2_perf_mc_tb
