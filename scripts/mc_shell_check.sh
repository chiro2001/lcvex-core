#!/usr/bin/env bash
# C1 dual-core shell local L0/L1 check.
#
# This script intentionally does not modify rtl/filelist.f or Makefile.  It
# passes only the files needed by the C1 cluster shell to Verilator on the
# command line, so the single-core filelist and top-level remain untouched.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

MC_RTL_SOURCES="rtl/lcvex_pkg.sv rtl/lcvex_fp_state.sv rtl/lcvex_fp_scalar.sv rtl/lcvex_neon_fp.sv rtl/lcvex_neon_int.sv rtl/lcvex_alu.sv rtl/lcvex_muldiv.sv rtl/lcvex_decode.sv rtl/lcvex_mmu.sv rtl/lcvex_core.sv rtl/lcvex_mem_ram.sv rtl/lcvex_mem_arb.sv rtl/lcvex_cluster_pkg.sv rtl/lcvex_core_wrap.sv rtl/lcvex_cluster_top.sv"

echo "== git diff --check =="
git diff --check

echo "== JSON tool =="
python3 -m json.tool docs/tasks/evidence/T-20260829-079.json >/dev/null

echo "== Verilator lint (CORE_COUNT=1 parameterized top) =="
conda run --no-capture-output -n lcvex verilator --lint-only --no-assert --no-timing \
    --top-module lcvex_cluster_top -GCORE_COUNT=1 \
    $MC_RTL_SOURCES -Wno-fatal

echo "== Verilator lint (CORE_COUNT=2 parameterized top) =="
conda run --no-capture-output -n lcvex verilator --lint-only --no-assert --no-timing \
    --top-module lcvex_cluster_top \
    $MC_RTL_SOURCES -Wno-fatal

echo "mc_shell_check: OK"
