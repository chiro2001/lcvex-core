#!/usr/bin/env bash
# B5-SoC/Boot: Verilator lint for the Catapult A10 SoC top (L0).
set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
PLATFORM_DIR="$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)"
REPO_DIR="$(CDPATH= cd -- "$PLATFORM_DIR/../.." && pwd)"
OUT_DIR="${LCVEX_SOC_LINT_DIR:-$REPO_DIR/build/agents/T-20260828-065/lint_soc}"

cd "$REPO_DIR"

VERILATOR_BIN="${VERILATOR_BIN:-verilator}"
if ! command -v "$VERILATOR_BIN" >/dev/null 2>&1; then
    if command -v conda >/dev/null 2>&1 && conda env list | awk '{print $1}' | grep -qx lcvex; then
        VERILATOR_BIN="conda run --no-capture-output -n lcvex verilator"
    fi
fi
if ! command -v "$VERILATOR_BIN" >/dev/null 2>&1 && [[ "$VERILATOR_BIN" != conda* ]]; then
    echo "TOOL_MISSING command=verilator"
    echo "TOOL_MISSING_REASON=Verilator is not present in PATH"
    exit 127
fi

mkdir -p "$OUT_DIR"
echo "LCVEX_CATAPULT_A10_SOC_LINT"
echo "repo=$REPO_DIR"
echo "output=$OUT_DIR"
$VERILATOR_BIN --version

$VERILATOR_BIN \
    --lint-only --timing --assert \
    -Wall -Wno-fatal \
    -Wno-DECLFILENAME -Wno-PINMISSING -Wno-UNUSEDSIGNAL \
    -Wno-UNDRIVEN -Wno-WIDTHEXPAND -Wno-UNSIGNED -Wno-PROCASSINIT \
    --top-module lcvex_catapult_soc_top \
    -Mdir "$OUT_DIR/obj_dir" \
    -f fpga/catapult_a10/tb/filelist_soc.f \
    > "$OUT_DIR/lint.log" 2>&1
status=$?
cat "$OUT_DIR/lint.log"
if [[ $status -eq 0 ]]; then
    echo "LCVEX_CATAPULT_A10_SOC_LINT_PASS"
else
    echo "LCVEX_CATAPULT_A10_SOC_LINT_FAIL exit=$status"
fi
exit $status
