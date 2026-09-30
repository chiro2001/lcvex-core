#!/usr/bin/env bash
# Offline SV lint for the Catapult A10 B0+ platform skeleton.
set -u

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
PLATFORM_DIR="$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)"
REPO_DIR="$(CDPATH= cd -- "$PLATFORM_DIR/../.." && pwd)"
OUT_DIR="${LCVEX_SKELETON_LINT_DIR:-$REPO_DIR/build/agents/T-20260827-062/lint}"

VERILATOR_BIN="${VERILATOR_BIN:-verilator}"
if ! command -v "$VERILATOR_BIN" >/dev/null 2>&1; then
    if command -v conda >/dev/null 2>&1 && conda env list | awk '{print $1}' | grep -qx lcvex; then
        VERILATOR_BIN="conda run --no-capture-output -n lcvex verilator"
    fi
fi
if ! command -v "$VERILATOR_BIN" >/dev/null 2>&1 && [[ "$VERILATOR_BIN" != conda* ]]; then
    echo "TOOL_MISSING command=verilator"
    echo "TOOL_MISSING_REASON=Verilator is not present in PATH (LCVEX_SKELETON_LINT_DIR=$OUT_DIR)"
    exit 127
fi

mkdir -p "$OUT_DIR"
echo "LCVEX_CATAPULT_A10_SKELETON_LINT"
echo "platform=$PLATFORM_DIR"
echo "output=$OUT_DIR"
echo "verilator_command=$VERILATOR_BIN --version"
$VERILATOR_BIN --version

# B5: the platform shell instantiates lcvex_catapult_soc_top, so the SoC RTL
# filelist is part of the skeleton lint set.
cd "$REPO_DIR"

# Expected for the skeleton/stub combination:
# - DECLFILENAME: stub file intentionally contains several vendor modules.
# - PROCASSINIT: explicit register power-up values are deliberate (PoC parity).
# - UNUSEDSIGNAL/UNDRIVEN: idle boundary tie-offs and empty vendor stubs.
$VERILATOR_BIN \
    --lint-only \
    --top-module lcvex_catapult_a10_top \
    -Wall \
    -Wno-fatal \
    -Wno-DECLFILENAME \
    -Wno-PROCASSINIT \
    -Wno-UNUSEDSIGNAL \
    -Wno-UNDRIVEN \
    -Wno-WIDTHEXPAND \
    -Mdir "$OUT_DIR/obj_dir" \
    "$PLATFORM_DIR/rtl/lcvex_catapult_a10_reset_gate.sv" \
    "$PLATFORM_DIR/rtl/lcvex_catapult_a10_top.sv" \
    "$PLATFORM_DIR/tb/sv/lcvex_catapult_a10_stub.sv" \
    -f "$REPO_DIR/fpga/catapult_a10/tb/filelist_soc.f" \
    > "$OUT_DIR/lint.log" 2>&1
status=$?
cat "$OUT_DIR/lint.log"
if [[ $status -eq 0 ]]; then
    echo "LCVEX_CATAPULT_A10_SKELETON_LINT_PASS"
else
    echo "LCVEX_CATAPULT_A10_SKELETON_LINT_FAIL exit=$status"
fi
exit $status
