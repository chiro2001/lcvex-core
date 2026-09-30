#!/usr/bin/env bash
set -u

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
PLATFORM_DIR="$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)"
REPO_DIR="$(CDPATH= cd -- "$PLATFORM_DIR/../.." && pwd)"
OUT_DIR="$REPO_DIR/build/agents/T-20260827-052/qsys-ip-regenerate"
ENV_OUT="$(printenv LCVEX_QSYS_REGEN_DIR 2>/dev/null || true)"
if [[ -n "$ENV_OUT" ]]; then
    OUT_DIR="$ENV_OUT"
fi
IP_GENERATE="$(printenv IP_GENERATE 2>/dev/null || true)"
QSYS_GENERATE="$(printenv QSYS_GENERATE 2>/dev/null || true)"
if [[ -z "$IP_GENERATE" ]]; then IP_GENERATE=ip-generate; fi
if [[ -z "$QSYS_GENERATE" ]]; then QSYS_GENERATE=qsys-generate; fi

mkdir -p "$OUT_DIR"
LOG="$OUT_DIR/regenerate.log"
exec > >(tee "$LOG") 2>&1

echo "LCVEX_CATAPULT_A10_REGENERATE"
echo "platform=$PLATFORM_DIR"
echo "output=$OUT_DIR"
echo "ip_generate=$IP_GENERATE"
echo "qsys_generate=$QSYS_GENERATE"

if ! command -v "$IP_GENERATE" >/dev/null 2>&1; then
    echo "TOOL_MISSING command=$IP_GENERATE"
    echo "TOOL_MISSING_REASON=Quartus Prime Pro/Qsys installation is not present in PATH"
    exit 127
fi
if ! command -v "$QSYS_GENERATE" >/dev/null 2>&1; then
    echo "TOOL_MISSING command=$QSYS_GENERATE"
    echo "TOOL_MISSING_REASON=Quartus Prime Pro/Qsys installation is not present in PATH"
    exit 127
fi

echo "ip_generate_version_command=$IP_GENERATE --version"
"$IP_GENERATE" --version
echo "qsys_generate_version_command=$QSYS_GENERATE --version"
"$QSYS_GENERATE" --version

IP_OUT="$OUT_DIR/ip"
mkdir -p "$IP_OUT"
for ip_file in \
    "$PLATFORM_DIR/qsys/ddr4_bot/ip/Qsys/Qsys_clk_100.ip" \
    "$PLATFORM_DIR/qsys/ddr4_bot/ip/Qsys/Qsys_clk_266.ip" \
    "$PLATFORM_DIR/qsys/ddr4_bot/ip/Qsys/Qsys_emif_bot.ip" \
    "$PLATFORM_DIR/qsys/ddr4_bot/ip/Qsys/Qsys_reset_controller_0.ip"
do
    name="$(basename "$ip_file" .ip)"
    echo "ip_generate_command=$IP_GENERATE --component-file=$ip_file --output-directory=$IP_OUT/$name --file-set=QUARTUS_SYNTH --language=VERILOG"
    mkdir -p "$IP_OUT/$name"
    "$IP_GENERATE" \
        --component-file="$ip_file" \
        --output-directory="$IP_OUT/$name" \
        --file-set=QUARTUS_SYNTH \
        --language=VERILOG
done

QSYS_OUT="$OUT_DIR/qsys"
mkdir -p "$QSYS_OUT"
echo "qsys_generate_command=$QSYS_GENERATE --synthesis=VERILOG --output-directory=$QSYS_OUT $PLATFORM_DIR/qsys/ddr4_bot/Qsys.qsys"
"$QSYS_GENERATE" \
    --synthesis=VERILOG \
    --output-directory="$QSYS_OUT" \
    "$PLATFORM_DIR/qsys/ddr4_bot/Qsys.qsys"

(
    cd "$OUT_DIR" || exit 1
    find . -type f ! -name generated.sha256 -print0 |
        sort -z |
        xargs -0 sha256sum > generated.sha256
)

EXPECTED="$PLATFORM_DIR/qsys/ddr4_bot/Qsys/Qsys_bb.v"
GENERATED="$QSYS_OUT/Qsys_bb.v"
if [[ -f "$GENERATED" ]]; then
    if diff -u "$EXPECTED" "$GENERATED" > "$OUT_DIR/Qsys_bb.diff"; then
        echo "QSYS_INTERFACE_DIFF=identical"
    else
        diff_status=$?
        echo "QSYS_INTERFACE_DIFF=different exit=$diff_status"
    fi
else
    echo "QSYS_INTERFACE_DIFF=not_available generated=$GENERATED"
fi
echo "GENERATED_SHA256=$OUT_DIR/generated.sha256"
echo "LCVEX_CATAPULT_A10_REGENERATE_PASS"
