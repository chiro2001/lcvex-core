#!/usr/bin/env bash
# B25: Verilator 64 KiB BRAM resident-monitor system smoke.
set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
PLATFORM_DIR="$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)"
REPO_DIR="$(CDPATH= cd -- "$PLATFORM_DIR/../.." && pwd)"
OUT_DIR="${LCVEX_SOC_SMOKE_DIR:-$REPO_DIR/build/agents/T-20260907-037/soc-smoke}"

cd "$REPO_DIR"
bash fpga/catapult_a10/boot/build.sh

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
export TMPDIR="${LCVEX_SOC_SMOKE_TMPDIR:-$OUT_DIR/tmp}"
mkdir -p "$TMPDIR"
echo "LCVEX_CATAPULT_A10_B25_SOC_SMOKE"
echo "repo=$REPO_DIR"
echo "output=$OUT_DIR"
echo "verilator_command=$VERILATOR_BIN --version"
$VERILATOR_BIN --version

verilator_params=()
if [[ "${LCVEX_SOC_SMOKE_VENDOR_TIMING:-0}" == "1" ]]; then
    verilator_params+=(
        -GJTAG_VENDOR_TIMING=1
        -GA64_FP_SIMD=0
    )
    echo "jtag_model=quartus-21.4-registered-timing"
    echo "a64_fp_simd=0"
else
    echo "jtag_model=behavioral"
fi

$VERILATOR_BIN \
    --binary --timing --assert \
    -j "${VERILATOR_JOBS:-1}" \
    -Wall -Wno-fatal \
    -Wno-DECLFILENAME -Wno-PINMISSING -Wno-UNUSEDSIGNAL \
    -Wno-UNDRIVEN -Wno-WIDTHEXPAND \
    "${verilator_params[@]}" \
    --top-module lcvex_catapult_soc_tb \
    -Mdir "$OUT_DIR/obj_dir" -o lcvex_catapult_soc_tb \
    -f fpga/catapult_a10/tb/filelist_soc.f

set +e
"$OUT_DIR/obj_dir/lcvex_catapult_soc_tb" > "$OUT_DIR/smoke.log" 2>&1
status=$?
set -e
cat "$OUT_DIR/smoke.log"
if [[ $status -eq 0 ]]; then
    python3 fpga/catapult_a10/tools/parse_microbench.py \
        --mode microbench --input "$OUT_DIR/smoke.log"
    python3 fpga/catapult_a10/tools/parse_microbench.py \
        --mode selfcheck --input "$OUT_DIR/smoke.log"
    echo "LCVEX_CATAPULT_A10_B25_SOC_SMOKE_PASS"
else
    echo "LCVEX_CATAPULT_A10_B25_SOC_SMOKE_FAIL exit=$status"
fi
exit $status
