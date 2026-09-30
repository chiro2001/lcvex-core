#!/usr/bin/env bash
# B25 JTAG-UART: registered Quartus-IP timing at the bridge and full SoC.
set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
PLATFORM_DIR="$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)"
REPO_DIR="$(CDPATH= cd -- "$PLATFORM_DIR/../.." && pwd)"
OUT_DIR="${LCVEX_JTAG_VENDOR_DIR:-$REPO_DIR/build/agents/T-20260920-001/jtag-vendor}"
MODE="${1:---all}"

case "$MODE" in
    --all|--focused-only|--soc-only) ;;
    *)
        echo "usage: $0 [--all|--focused-only|--soc-only]" >&2
        exit 2
        ;;
esac

mkdir -p "$OUT_DIR"
cd "$REPO_DIR"

common_sources=(
    rtl/lcvex_pkg.sv
    rtl/lcvex_catapult_soc_pkg.sv
    rtl/lcvex_catapult_soc_top.sv
    tb/sv/lcvex_jtag_uart_model.sv
    tb/sv/lcvex_jtag_uart_bridge_tb.sv
)
status_sources=(
    rtl/lcvex_pkg.sv
    rtl/lcvex_catapult_soc_pkg.sv
    rtl/lcvex_catapult_soc_top.sv
    tb/sv/lcvex_catapult_soc_status_tb.sv
)
irq_sources=(
    tb/sv/lcvex_jtag_uart_model.sv
    tb/sv/lcvex_jtag_uart_irq_tb.sv
)
generated_irq_sources=(
    fpga/catapult_a10/jtag_uart/jtag_uart_std_altera_avalon_jtag_uart_1910_zesttkq.v
    tb/sv/lcvex_jtag_uart_generated_irq_tb.sv
)

echo "JTAG_UART_VENDOR_TIMING_TEST"
echo "source_sha=$(git rev-parse HEAD)"
echo "output=$OUT_DIR"
echo "mode=$MODE"

vendor_ip="fpga/catapult_a10/jtag_uart/jtag_uart_std_altera_avalon_jtag_uart_1910_zesttkq.v"
echo "vendor_ip_sha256=$(sha256sum "$vendor_ip" | awk '{print $1}')"
grep -Fq 'av_waitrequest <= ~(av_chipselect & (~av_write_n | ~av_read_n) & av_waitrequest);' "$vendor_ip"
grep -Fq 'if (av_chipselect & ~av_read_n & av_waitrequest)' "$vendor_ip"
grep -Fq 'read_0 <= ~av_address;' "$vendor_ip"
grep -Fq "fifo_AF <= (7'h40 - {rfifo_full,rfifo_used}) <= 63;" "$vendor_ip"
grep -Fq "assign fifo_rd = (av_chipselect & ~av_read_n & av_waitrequest & ~av_address) ? ~fifo_EF : 1'b0;" "$vendor_ip"
if [[ "$(grep -Fc 'lpm_showahead = "OFF"' "$vendor_ip")" -ne 2 ]]; then
    echo "JTAG_UART_VENDOR_TIMING_TEST_FAIL showahead-anchor-count" >&2
    exit 1
fi
echo "JTAG_UART_VENDOR_SOURCE_ANCHORS_PASS"

if [[ "$MODE" != "--soc-only" ]]; then
    if ! command -v iverilog >/dev/null 2>&1 || ! command -v vvp >/dev/null 2>&1; then
        echo "JTAG_UART_VENDOR_TIMING_TEST_FAIL TOOL_MISSING=iverilog-or-vvp" >&2
        exit 127
    fi
    iverilog -V 2>&1 | sed -n '1p'
    iverilog -g2012 \
        -P lcvex_jtag_uart_bridge_tb.VENDOR_TIMING=1 \
        -s lcvex_jtag_uart_bridge_tb \
        -o "$OUT_DIR/vendor-iverilog.vvp" \
        "${common_sources[@]}" \
        > "$OUT_DIR/iverilog-build.log" 2>&1
    vvp "$OUT_DIR/vendor-iverilog.vvp" \
        > "$OUT_DIR/iverilog-run.log" 2>&1
    cat "$OUT_DIR/iverilog-build.log"
    cat "$OUT_DIR/iverilog-run.log"
    grep -Fq "vendor_timing=1" "$OUT_DIR/iverilog-run.log"
    grep -Fq "JTAG_UART_TEST PASS" "$OUT_DIR/iverilog-run.log"
    iverilog -g2012 \
        -s lcvex_jtag_uart_irq_tb \
        -o "$OUT_DIR/irq-iverilog.vvp" \
        "${irq_sources[@]}" \
        > "$OUT_DIR/irq-iverilog-build.log" 2>&1
    vvp "$OUT_DIR/irq-iverilog.vvp" \
        > "$OUT_DIR/irq-iverilog-run.log" 2>&1
    cat "$OUT_DIR/irq-iverilog-build.log"
    cat "$OUT_DIR/irq-iverilog-run.log"
    grep -Fq "JTAG_UART_IRQ_MODEL_TEST PASS" "$OUT_DIR/irq-iverilog-run.log"
    iverilog -g2012 \
        -s lcvex_jtag_uart_generated_irq_tb \
        -o "$OUT_DIR/generated-irq-iverilog.vvp" \
        "${generated_irq_sources[@]}" \
        > "$OUT_DIR/generated-irq-iverilog-build.log" 2>&1
    vvp "$OUT_DIR/generated-irq-iverilog.vvp" \
        > "$OUT_DIR/generated-irq-iverilog-run.log" 2>&1
    cat "$OUT_DIR/generated-irq-iverilog-build.log"
    cat "$OUT_DIR/generated-irq-iverilog-run.log"
    grep -Fq "GENERATED_JTAG_UART_RX_IRQ_TEST PASS" \
        "$OUT_DIR/generated-irq-iverilog-run.log"
    iverilog -g2012 \
        -s lcvex_catapult_soc_status_tb \
        -o "$OUT_DIR/status-iverilog.vvp" \
        "${status_sources[@]}" \
        > "$OUT_DIR/status-iverilog-build.log" 2>&1
    vvp "$OUT_DIR/status-iverilog.vvp" \
        > "$OUT_DIR/status-iverilog-run.log" 2>&1
    cat "$OUT_DIR/status-iverilog-build.log"
    cat "$OUT_DIR/status-iverilog-run.log"
    grep -Fq "CATAPULT_STATUS_OBSERVABILITY_TEST PASS" \
        "$OUT_DIR/status-iverilog-run.log"

    if [[ -n "${VERILATOR_BIN:-}" ]]; then
        read -r -a verilator_command <<< "$VERILATOR_BIN"
    elif command -v verilator >/dev/null 2>&1; then
        verilator_command=(verilator)
    elif command -v conda >/dev/null 2>&1 && conda env list | awk '{print $1}' | grep -qx lcvex; then
        verilator_command=(conda run --no-capture-output -n lcvex verilator)
    else
        echo "JTAG_UART_VENDOR_TIMING_TEST_FAIL TOOL_MISSING=verilator" >&2
        exit 127
    fi
    mkdir -p "$OUT_DIR/verilator-obj" "$OUT_DIR/irq-verilator-obj" \
        "$OUT_DIR/status-verilator-obj" \
        "$OUT_DIR/tmp"
    export TMPDIR="${LCVEX_JTAG_VENDOR_TMPDIR:-$OUT_DIR/tmp}"
    "${verilator_command[@]}" --version
    "${verilator_command[@]}" \
        --binary --timing --assert \
        -j "${VERILATOR_JOBS:-1}" \
        -Wall -Wno-fatal -Wno-DECLFILENAME -Wno-PINMISSING \
        -Wno-UNUSEDSIGNAL -Wno-UNDRIVEN -Wno-WIDTHEXPAND \
        -GVENDOR_TIMING=1 \
        --top-module lcvex_jtag_uart_bridge_tb \
        -Mdir "$OUT_DIR/verilator-obj" -o lcvex_jtag_uart_bridge_tb \
        "${common_sources[@]}" \
        > "$OUT_DIR/verilator-build.log" 2>&1
    "$OUT_DIR/verilator-obj/lcvex_jtag_uart_bridge_tb" \
        > "$OUT_DIR/verilator-run.log" 2>&1
    cat "$OUT_DIR/verilator-build.log"
    cat "$OUT_DIR/verilator-run.log"
    grep -Fq "vendor_timing=1" "$OUT_DIR/verilator-run.log"
    grep -Fq "JTAG_UART_TEST PASS" "$OUT_DIR/verilator-run.log"
    "${verilator_command[@]}" \
        --binary --timing --assert \
        -j "${VERILATOR_JOBS:-1}" \
        -Wall -Wno-fatal -Wno-DECLFILENAME -Wno-PINMISSING \
        -Wno-UNUSEDSIGNAL -Wno-UNDRIVEN -Wno-WIDTHEXPAND \
        --top-module lcvex_jtag_uart_irq_tb \
        -Mdir "$OUT_DIR/irq-verilator-obj" -o lcvex_jtag_uart_irq_tb \
        "${irq_sources[@]}" \
        > "$OUT_DIR/irq-verilator-build.log" 2>&1
    "$OUT_DIR/irq-verilator-obj/lcvex_jtag_uart_irq_tb" \
        > "$OUT_DIR/irq-verilator-run.log" 2>&1
    cat "$OUT_DIR/irq-verilator-build.log"
    cat "$OUT_DIR/irq-verilator-run.log"
    grep -Fq "JTAG_UART_IRQ_MODEL_TEST PASS" "$OUT_DIR/irq-verilator-run.log"
    "${verilator_command[@]}" \
        --binary --timing --assert \
        -j "${VERILATOR_JOBS:-1}" \
        -Wall -Wno-fatal -Wno-DECLFILENAME -Wno-PINMISSING \
        -Wno-UNUSEDSIGNAL -Wno-UNDRIVEN -Wno-WIDTHEXPAND \
        --top-module lcvex_catapult_soc_status_tb \
        -Mdir "$OUT_DIR/status-verilator-obj" \
        -o lcvex_catapult_soc_status_tb \
        "${status_sources[@]}" \
        > "$OUT_DIR/status-verilator-build.log" 2>&1
    "$OUT_DIR/status-verilator-obj/lcvex_catapult_soc_status_tb" \
        > "$OUT_DIR/status-verilator-run.log" 2>&1
    cat "$OUT_DIR/status-verilator-build.log"
    cat "$OUT_DIR/status-verilator-run.log"
    grep -Fq "CATAPULT_STATUS_OBSERVABILITY_TEST PASS" \
        "$OUT_DIR/status-verilator-run.log"
    echo "JTAG_UART_VENDOR_FOCUSED_PASS"
fi

if [[ "$MODE" != "--focused-only" ]]; then
    set +e
    LCVEX_SOC_SMOKE_VENDOR_TIMING=1 \
    LCVEX_SOC_SMOKE_DIR="$OUT_DIR/soc" \
    VERILATOR_JOBS="${VERILATOR_JOBS:-1}" \
        bash fpga/catapult_a10/tools/run_soc_smoke.sh \
        > "$OUT_DIR/soc-wrapper.log" 2>&1
    soc_rc=$?
    set -e
    cat "$OUT_DIR/soc-wrapper.log"
    if [[ $soc_rc -ne 0 ]]; then
        echo "JTAG_UART_VENDOR_TIMING_TEST_FAIL soc_exit=$soc_rc" >&2
        exit "$soc_rc"
    fi
    grep -Fq "SOC_B25_VENDOR_EMPTY_POLLS reads=262144" \
        "$OUT_DIR/soc/smoke.log"
    grep -Fq "SOC_B25_ALL_PASS" "$OUT_DIR/soc/smoke.log"
    echo "JTAG_UART_VENDOR_SOC_PASS"
fi

echo "JTAG_UART_VENDOR_TIMING_TEST_PASS"
