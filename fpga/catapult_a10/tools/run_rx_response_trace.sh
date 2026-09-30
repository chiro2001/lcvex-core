#!/usr/bin/env bash
# T-20260920-013: vendor-timed CPU-originated UART DATA response trace.
set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
PLATFORM_DIR="$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)"
REPO_DIR="$(CDPATH= cd -- "$PLATFORM_DIR/../.." && pwd)"
TASK_ID="T-20260920-013"
OUT_DIR="${LCVEX_RX_RESPONSE_TRACE_DIR:-$REPO_DIR/build/agents/$TASK_ID}"
BOOT_DIR="$OUT_DIR/boot"
OBJ_DIR="$OUT_DIR/iverilog-obj"
VERI_DIR="$OUT_DIR/verilator-obj"
LOCK="/home/chiro/projects/.resource-locks/resource-lock"
MODE="${1:---focused}"

case "$MODE" in
  --focused|--verilator|--verilator-locked) ;;
  *) echo "usage: $0 [--focused|--verilator]" >&2; exit 2 ;;
esac

mkdir -p "$OUT_DIR" "$BOOT_DIR" "$OBJ_DIR"
cd "$REPO_DIR"

if [[ "$MODE" == "--verilator" ]]; then
  set +e
  "$LOCK" run local lcvex "$TASK_ID" rx_rtl_trace \
      --min-local-available-mib "${LCVEX_MIN_LOCAL_AVAILABLE_MIB:-8192}" \
      --meta mode=verilator --meta lane=hardware-response -- \
      "$0" --verilator-locked
  rc=$?
  set -e
  if [[ $rc -eq 75 ]]; then
    echo "RX_RESPONSE_TRACE_DEFERRED resource-lock=75"
  fi
  exit "$rc"
fi

echo "RX_RESPONSE_TRACE_TEST"
echo "task=$TASK_ID"
echo "source_sha=$(git rev-parse HEAD)"
echo "output=$OUT_DIR"

LCVEX_BOOT_BUILD_DIR="$BOOT_DIR" \
  bash fpga/catapult_a10/boot/build.sh > "$OUT_DIR/boot-build.log" 2>&1
cat "$OUT_DIR/boot-build.log"
BOOT_HEX="$BOOT_DIR/boot.hex"

STATUS_SOURCES=(
  rtl/lcvex_pkg.sv
  rtl/lcvex_catapult_soc_pkg.sv
  rtl/lcvex_catapult_soc_top.sv
  tb/sv/lcvex_catapult_soc_status_tb.sv
)

iverilog -g2012 -s lcvex_catapult_soc_status_tb \
  -o "$OBJ_DIR/status.vvp" "${STATUS_SOURCES[@]}" \
  > "$OUT_DIR/status-iverilog-build.log" 2>&1
vvp "$OBJ_DIR/status.vvp" > "$OUT_DIR/status-iverilog-run.log" 2>&1
cat "$OUT_DIR/status-iverilog-build.log"
cat "$OUT_DIR/status-iverilog-run.log"
grep -Fq "CATAPULT_STATUS_OBSERVABILITY_TEST PASS" \
  "$OUT_DIR/status-iverilog-run.log"

iverilog -g2012 -s lcvex_catapult_soc_rx_observer_tb \
  -o "$OBJ_DIR/observer.vvp" \
  rtl/lcvex_pkg.sv rtl/lcvex_catapult_soc_pkg.sv \
  rtl/lcvex_catapult_soc_top.sv \
  tb/sv/lcvex_catapult_soc_rx_observer_tb.sv \
  > "$OUT_DIR/observer-iverilog-build.log" 2>&1
vvp "$OBJ_DIR/observer.vvp" > "$OUT_DIR/observer-iverilog-run.log" 2>&1
cat "$OUT_DIR/observer-iverilog-build.log"
cat "$OUT_DIR/observer-iverilog-run.log"
grep -Fq "RX_OBSERVER_UNIT PASS" "$OUT_DIR/observer-iverilog-run.log"

if [[ "$MODE" == "--verilator-locked" ]]; then
  mkdir -p "$VERI_DIR" "$OUT_DIR/tmp"
  export TMPDIR="${LCVEX_RX_RESPONSE_TRACE_TMPDIR:-$OUT_DIR/tmp}"
  if [[ -n "${VERILATOR_BIN:-}" ]]; then
    read -r -a verilator_command <<< "$VERILATOR_BIN"
  elif command -v verilator >/dev/null 2>&1; then
    verilator_command=(verilator)
  elif command -v conda >/dev/null 2>&1 &&
       conda env list | awk '{print $1}' | grep -qx lcvex; then
    verilator_command=(conda run --no-capture-output -n lcvex verilator)
  else
    echo "RX_RESPONSE_TRACE_FAIL TOOL_MISSING=verilator" >&2
    exit 127
  fi
  "${verilator_command[@]}" --version | tee "$OUT_DIR/verilator-version.log"
  "${verilator_command[@]}" \
    --binary --timing --assert -j "${VERILATOR_JOBS:-1}" \
    -Wall -Wno-fatal -Wno-DECLFILENAME -Wno-PINMISSING \
    -Wno-UNUSEDSIGNAL -Wno-UNDRIVEN -Wno-WIDTHEXPAND \
    --top-module lcvex_catapult_soc_rx_response_trace_tb \
    -Mdir "$VERI_DIR" -o lcvex_catapult_soc_rx_response_trace_tb \
    "-GBOOT_IMAGE=\"$BOOT_HEX\"" \
    -f fpga/catapult_a10/tb/filelist_rx_response_trace.f \
    > "$OUT_DIR/verilator-build.log" 2>&1
  "$VERI_DIR/lcvex_catapult_soc_rx_response_trace_tb" \
    > "$OUT_DIR/verilator-run.log" 2>&1
  cat "$OUT_DIR/verilator-build.log"
  cat "$OUT_DIR/verilator-run.log"
  grep -Fq "RX_RESPONSE_TRACE PASS" "$OUT_DIR/verilator-run.log"
  echo "RX_RESPONSE_TRACE_VERILATOR_PASS"
  exit 0
fi

# Icarus is intentionally limited to the status contract and the existing
# focused vendor Avalon bridge test.  The full SoC response trace uses the
# Verilator path above because this RTL contains SVA/advanced SV constructs
# outside Icarus' supported subset.
BRIDGE_OBJ="$OBJ_DIR/jtag-bridge.vvp"
iverilog -g2012 \
  -P lcvex_jtag_uart_bridge_tb.VENDOR_TIMING=1 \
  -s lcvex_jtag_uart_bridge_tb -o "$BRIDGE_OBJ" \
  rtl/lcvex_pkg.sv rtl/lcvex_catapult_soc_pkg.sv \
  rtl/lcvex_catapult_soc_top.sv tb/sv/lcvex_jtag_uart_model.sv \
  tb/sv/lcvex_jtag_uart_bridge_tb.sv \
  > "$OUT_DIR/bridge-iverilog-build.log" 2>&1
vvp "$BRIDGE_OBJ" > "$OUT_DIR/bridge-iverilog-run.log" 2>&1
cat "$OUT_DIR/bridge-iverilog-build.log"
cat "$OUT_DIR/bridge-iverilog-run.log"
grep -Fq "JTAG_UART_TEST PASS" "$OUT_DIR/bridge-iverilog-run.log"
echo "RX_RESPONSE_TRACE_FOCUSED_PASS"
