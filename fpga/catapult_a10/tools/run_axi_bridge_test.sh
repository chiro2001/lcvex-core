#!/usr/bin/env bash
# B25 focused regression for the M1-B to AXI line-fill bridge.
set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
PLATFORM_DIR="$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)"
REPO_DIR="$(CDPATH= cd -- "$PLATFORM_DIR/../.." && pwd)"
OUT_DIR="${LCVEX_AXI_BRIDGE_TEST_DIR:-$REPO_DIR/build/agents/T-20260907-037/axi-bridge}"

cd "$REPO_DIR"
mkdir -p "$OUT_DIR/obj_dir" "$OUT_DIR/tmp"
export TMPDIR="${LCVEX_AXI_BRIDGE_TEST_TMPDIR:-$OUT_DIR/tmp}"

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

echo "LCVEX_CATAPULT_SOC_AXI_BRIDGE_TEST"
echo "output=$OUT_DIR"
$VERILATOR_BIN --version
$VERILATOR_BIN \
    --binary --timing --assert -Wall -Wno-fatal \
    -Wno-PROCASSINIT -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM -Wno-WIDTHEXPAND \
    -j "${VERILATOR_JOBS:-1}" \
    --top-module lcvex_catapult_soc_axi_bridge_tb \
    -Mdir "$OUT_DIR/obj_dir" -o lcvex_catapult_soc_axi_bridge_tb \
    rtl/lcvex_pkg.sv rtl/lcvex_axi4_pkg.sv \
    rtl/lcvex_catapult_soc_axi.sv \
    tb/sv/lcvex_catapult_soc_axi_bridge_tb.sv

"$OUT_DIR/obj_dir/lcvex_catapult_soc_axi_bridge_tb"
echo "LCVEX_CATAPULT_SOC_AXI_BRIDGE_TEST_PASS"
