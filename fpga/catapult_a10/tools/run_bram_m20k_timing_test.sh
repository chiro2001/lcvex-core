#!/usr/bin/env bash
# Exercise the SYNTHESIS branch against a clocked altera_syncram timing stub.
set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
PLATFORM_DIR="$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)"
REPO_DIR="$(CDPATH= cd -- "$PLATFORM_DIR/../.." && pwd)"
OUT_DIR="${LCVEX_M20K_TIMING_DIR:-$REPO_DIR/build/agents/T-20260919-001/m20k-timing}"
RTL_SOURCE="${LCVEX_M20K_RTL_SOURCE:-$REPO_DIR/rtl/lcvex_bram_boot.sv}"

if [[ ! -f "$RTL_SOURCE" ]]; then
    echo "BRAM_M20K_TIMING_TEST_FAIL missing_rtl=$RTL_SOURCE" >&2
    exit 2
fi

if [[ -n "${VERILATOR_BIN:-}" ]]; then
    read -r -a verilator_command <<< "$VERILATOR_BIN"
elif command -v verilator >/dev/null 2>&1; then
    verilator_command=(verilator)
elif command -v conda >/dev/null 2>&1 && conda env list | awk '{print $1}' | grep -qx lcvex; then
    verilator_command=(conda run --no-capture-output -n lcvex verilator)
else
    echo "BRAM_M20K_TIMING_TEST_FAIL TOOL_MISSING=verilator" >&2
    exit 127
fi

mkdir -p "$OUT_DIR/obj_dir" "$OUT_DIR/tmp"
export TMPDIR="${LCVEX_M20K_TIMING_TMPDIR:-$OUT_DIR/tmp}"
cd "$REPO_DIR"

echo "BRAM_M20K_TIMING_TEST"
echo "source_sha=$(git rev-parse HEAD)"
echo "output=$OUT_DIR"
echo "rtl_source=$RTL_SOURCE"
echo "rtl_sha256=$(sha256sum "$RTL_SOURCE" | awk '{print $1}')"
"${verilator_command[@]}" --version

set +e
"${verilator_command[@]}" \
    --binary --timing --assert -DSYNTHESIS \
    -j "${VERILATOR_JOBS:-1}" \
    -Wall -Wno-fatal \
    -Wno-DECLFILENAME -Wno-PINMISSING -Wno-PINCONNECTEMPTY \
    -Wno-UNUSEDSIGNAL \
    -Wno-UNDRIVEN -Wno-WIDTHEXPAND -Wno-UNSIGNED -Wno-PROCASSINIT \
    --top-module lcvex_bram_boot_m20k_tb \
    -Mdir "$OUT_DIR/obj_dir" -o lcvex_bram_boot_m20k_tb \
    rtl/lcvex_pkg.sv \
    tb/sv/altera_syncram_sync_stub.sv \
    "$RTL_SOURCE" \
    tb/sv/lcvex_bram_boot_m20k_tb.sv \
    > "$OUT_DIR/verilator-build.log" 2>&1
build_rc=$?
set -e
cat "$OUT_DIR/verilator-build.log"
if [[ $build_rc -ne 0 ]]; then
    echo "BRAM_M20K_TIMING_TEST_FAIL compile_exit=$build_rc" >&2
    exit "$build_rc"
fi

set +e
"$OUT_DIR/obj_dir/lcvex_bram_boot_m20k_tb" > "$OUT_DIR/verilator-run.log" 2>&1
run_rc=$?
set -e
cat "$OUT_DIR/verilator-run.log"
if [[ $run_rc -ne 0 ]]; then
    echo "BRAM_M20K_TIMING_TEST_FAIL run_exit=$run_rc" >&2
    exit "$run_rc"
fi
if ! grep -Fqx "BRAM_M20K_TIMING_TB PASS" "$OUT_DIR/verilator-run.log"; then
    echo "BRAM_M20K_TIMING_TEST_FAIL missing-pass-marker" >&2
    exit 1
fi

echo "BRAM_M20K_TIMING_TEST_PASS"
