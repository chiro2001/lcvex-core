#!/usr/bin/env bash
# T-20260920-023 logical-immediate behavioral + minimal Quartus regression.
#
# Modes:
#   --behavioral   production decoder + independent reference oracle locally
#   --old-negative fresh GamePC synthesis of functional baseline 1ce74e9c;
#                  success means warning 16788 is reproduced
#   --fixed        fresh GamePC synthesis of the current/selected candidate;
#                  success requires no warning 16788
#
# The remote modes deliberately use a tiny Arria-10 synthesis project.  They
# never invoke fitter, STA, assembler, programmer or any board operation.
set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
PLATFORM_DIR="$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)"
REPO_DIR="$(CDPATH= cd -- "$PLATFORM_DIR/../.." && pwd)"
TB_DIR="$PLATFORM_DIR/tb"
TOOLS_DIR="$PLATFORM_DIR/tools/quartus_logic_imm"
OUT_ROOT="${LCVEX_LOGIC_IMM_OUT_DIR:-$REPO_DIR/build/agents/T-20260920-023}"
REMOTE_ROOT="${LCVEX_LOGIC_IMM_REMOTE_ROOT:-D:/Projects/fpga-altra/lcvex/build/T-20260920-023-b25-logic-imm-quartus-regression}"
REMOTE_HOST="${LCVEX_LOGIC_IMM_REMOTE_HOST:-192.168.101.5}"
OLD_SHA="1ce74e9c81c40812ea93a161d52cad8dda807a0d"

usage() {
    cat >&2 <<'EOF'
usage: run_logic_imm_quartus_regression.sh --behavioral|--old-negative|--fixed

--behavioral    run the local Verilator/reference decoder oracle
--old-negative  stage exact old baseline 1ce74e9c and require fresh warning 16788
--fixed         stage current SOURCE_ROOT and require no fresh warning 16788

Remote modes require invocation under resource-lock's gamepc lease.  The
fixed mode is intended to be rerun on the merged T-024 candidate.
EOF
    exit 2
}

MODE="${1:-}"
case "$MODE" in
    --behavioral|--old-negative|--fixed) ;;
    *) usage ;;
esac

SOURCE_ROOT="${LCVEX_LOGIC_IMM_SOURCE_ROOT:-$REPO_DIR}"
RUN_NAME="${MODE#--}"
RUN_DIR="$OUT_ROOT/$RUN_NAME"
if [[ -e "$RUN_DIR" ]]; then
    echo "LOGIC_IMM_REGRESSION_FAIL stale-local-output=$RUN_DIR" >&2
    exit 1
fi
mkdir -p "$RUN_DIR"

sha256_file() {
    sha256sum "$1" | awk '{print $1}'
}

find_verilator() {
    if [[ -n "${VERILATOR_BIN:-}" ]]; then
        read -r -a VERILATOR_CMD <<< "$VERILATOR_BIN"
    elif command -v verilator >/dev/null 2>&1; then
        VERILATOR_CMD=(verilator)
    elif command -v conda >/dev/null 2>&1 && conda env list 2>/dev/null |
         awk '{print $1}' | grep -qx lcvex; then
        VERILATOR_CMD=(conda run --no-capture-output -n lcvex verilator)
    else
        echo "LOGIC_IMM_REGRESSION_FAIL TOOL_MISSING=verilator" >&2
        exit 127
    fi
}

run_behavioral() {
    local obj_dir="$RUN_DIR/obj_dir"
    local build_log="$RUN_DIR/verilator-build.log"
    local run_log="$RUN_DIR/verilator-run.log"
    mkdir -p "$obj_dir" "$RUN_DIR/tmp"
    find_verilator
    cd "$SOURCE_ROOT"
    {
        echo "LOGIC_IMM_BEHAVIORAL_ORACLE"
        echo "source_root=$SOURCE_ROOT"
        echo "source_sha=$(git -C "$SOURCE_ROOT" rev-parse HEAD)"
        echo "decode_sha256=$(sha256_file "$SOURCE_ROOT/rtl/lcvex_decode.sv")"
        "${VERILATOR_CMD[@]}" --version
    } | tee "$RUN_DIR/metadata.log"
    set +e
    "${VERILATOR_CMD[@]}" \
        --binary --timing --assert -j "${VERILATOR_JOBS:-1}" \
        -Wall -Wno-fatal \
        -Wno-DECLFILENAME -Wno-PINMISSING -Wno-UNUSEDSIGNAL \
        -Wno-UNDRIVEN -Wno-WIDTHEXPAND -Wno-UNSIGNED -Wno-PROCASSINIT \
        --top-module lcvex_logic_imm_quartus_tb \
        -Mdir "$obj_dir" -o lcvex_logic_imm_quartus_tb \
        rtl/lcvex_pkg.sv rtl/lcvex_decode.sv \
        fpga/catapult_a10/tb/sv/lcvex_logic_imm_quartus_tb.sv \
        >"$build_log" 2>&1
    local build_rc=$?
    set -e
    cat "$build_log"
    if (( build_rc != 0 )); then
        echo "LOGIC_IMM_REGRESSION_FAIL behavioral-compile=$build_rc" >&2
        exit "$build_rc"
    fi
    set +e
    "$obj_dir/lcvex_logic_imm_quartus_tb" >"$run_log" 2>&1
    local run_rc=$?
    set -e
    cat "$run_log"
    if (( run_rc != 0 )); then
        echo "LOGIC_IMM_REGRESSION_FAIL behavioral-run=$run_rc" >&2
        exit "$run_rc"
    fi
    grep -Fqx \
        "LOGIC_IMM_BEHAVIORAL_ORACLE_PASS exact=A43F/3F exhaustive=16384 legal=11328 reserved=5056" \
        "$run_log" || {
        echo "LOGIC_IMM_REGRESSION_FAIL missing-behavioral-pass-marker" >&2
        exit 1
    }
    echo "LOGIC_IMM_BEHAVIORAL_PASS"
}

ps_encoded() {
    # PowerShell -EncodedCommand consumes UTF-16LE, not UTF-8.
    printf '%s' "$1" | iconv -f UTF-8 -t UTF-16LE | base64 -w0
}

remote_path_win() {
    printf '%s' "$1" | sed 's#/#\\#g'
}

remote_ps() {
    local script="$1"
    ssh -o BatchMode=yes -o ConnectTimeout=10 "$REMOTE_HOST" \
        pwsh.exe -NoLogo -NoProfile -NonInteractive \
        -EncodedCommand "$(ps_encoded "$script")"
}

run_remote() {
    # resource-lock v2 exports this only to a lease-owned child.  Refuse to
    # issue even staging SSH/SCP without the gamepc lease.
    if [[ -z "${RESOURCE_LOCK_GUARD_FDS:-}" ]]; then
        echo "LOGIC_IMM_REGRESSION_FAIL remote-mode-requires-gamepc-lock" >&2
        exit 75
    fi
    local variant="$RUN_NAME"
    local stage="$RUN_DIR/stage"
    local local_src="$stage/src"
    local local_quartus="$stage/quartus"
    local local_sim="$stage/sim"
    mkdir -p "$local_src" "$local_quartus" "$local_sim"

    local source_sha
    if [[ "$MODE" == "--old-negative" ]]; then
        git -C "$REPO_DIR" cat-file -e "$OLD_SHA^{commit}"
        git -C "$REPO_DIR" show "$OLD_SHA:rtl/lcvex_pkg.sv" >"$local_src/lcvex_pkg.sv"
        git -C "$REPO_DIR" show "$OLD_SHA:rtl/lcvex_decode.sv" >"$local_src/lcvex_decode.sv"
        source_sha="$OLD_SHA"
    else
        [[ -f "$SOURCE_ROOT/rtl/lcvex_pkg.sv" &&
           -f "$SOURCE_ROOT/rtl/lcvex_decode.sv" ]] || {
            echo "LOGIC_IMM_REGRESSION_FAIL fixed-source-root=$SOURCE_ROOT" >&2
            exit 2
        }
        cp -- "$SOURCE_ROOT/rtl/lcvex_pkg.sv" "$local_src/lcvex_pkg.sv"
        cp -- "$SOURCE_ROOT/rtl/lcvex_decode.sv" "$local_src/lcvex_decode.sv"
        source_sha="$(git -C "$SOURCE_ROOT" rev-parse HEAD)"
    fi
    cp -- "$TOOLS_DIR/lcvex_logic_imm_quartus_probe_top.sv" \
        "$local_src/lcvex_logic_imm_quartus_probe_top.sv"
    cp -- "$TOOLS_DIR/lcvex_logic_imm_probe.qpf" "$local_quartus/"
    cp -- "$TOOLS_DIR/lcvex_logic_imm_probe.qsf" "$local_quartus/"
    cp -- "$TOOLS_DIR/run_quartus_probe.ps1" "$stage/"
    cp -- "$TOOLS_DIR/lcvex_logic_imm_quartus_postmap_tb.sv" "$local_sim/"
    {
        echo "task_id=T-20260920-023"
        echo "mode=$MODE"
        echo "source_sha=$source_sha"
        echo "source_pkg_sha256=$(sha256_file "$local_src/lcvex_pkg.sv")"
        echo "source_decode_sha256=$(sha256_file "$local_src/lcvex_decode.sv")"
        echo "remote_root=$REMOTE_ROOT"
        echo "remote_variant=$variant"
        echo "remote_host=$REMOTE_HOST"
    } | tee "$RUN_DIR/stage-manifest.txt"

    local remote_variant="$REMOTE_ROOT/$variant"
    local remote_root_win remote_variant_win
    remote_root_win="$(remote_path_win "$REMOTE_ROOT")"
    remote_variant_win="$(remote_path_win "$remote_variant")"
    local preflight_script
    preflight_script=$(cat <<EOF
\$ErrorActionPreference='Stop'
\$root='$remote_variant_win'
\$eda=@(Get-Process | Where-Object { \$_.ProcessName -match 'quartus|qsys|vsim|questa|vlog|vcom' })
Write-Output ('T023_PREFLIGHT EDA_COUNT=' + \$eda.Count)
if (\$eda.Count -ne 0) { Write-Error 'T023_PREFLIGHT_FAIL preexisting-eda-process'; exit 4 }
if (Test-Path -LiteralPath \$root) { Write-Error 'T023_PREFLIGHT_FAIL variant-exists'; exit 3 }
New-Item -ItemType Directory -Force -Path (Join-Path \$root 'src'),(Join-Path \$root 'quartus'),(Join-Path \$root 'sim') | Out-Null
Write-Output 'T023_PREFLIGHT_PASS fresh-variant'
EOF
)
    remote_ps "$preflight_script" | tee "$RUN_DIR/remote-preflight.log"

    # All SCP calls are intentionally after the lease check and after the
    # fresh-variant guard.  The remote root is task-owned and variant-specific.
    scp -q "$local_src/lcvex_pkg.sv" \
        "${REMOTE_HOST}:$remote_variant/src/lcvex_pkg.sv"
    scp -q "$local_src/lcvex_decode.sv" \
        "${REMOTE_HOST}:$remote_variant/src/lcvex_decode.sv"
    scp -q "$local_src/lcvex_logic_imm_quartus_probe_top.sv" \
        "${REMOTE_HOST}:$remote_variant/src/lcvex_logic_imm_quartus_probe_top.sv"
    scp -q "$local_quartus/lcvex_logic_imm_probe.qpf" \
        "${REMOTE_HOST}:$remote_variant/quartus/lcvex_logic_imm_probe.qpf"
    scp -q "$local_quartus/lcvex_logic_imm_probe.qsf" \
        "${REMOTE_HOST}:$remote_variant/quartus/lcvex_logic_imm_probe.qsf"
    scp -q "$stage/run_quartus_probe.ps1" \
        "${REMOTE_HOST}:$remote_variant/run_quartus_probe.ps1"
    scp -q "$local_sim/lcvex_logic_imm_quartus_postmap_tb.sv" \
        "${REMOTE_HOST}:$remote_variant/sim/lcvex_logic_imm_quartus_postmap_tb.sv"

    local runner_win="$remote_variant_win\\run_quartus_probe.ps1"
    local remote_run_script
    remote_run_script=$(cat <<EOF
\$ErrorActionPreference='Stop'
& '$runner_win' -Root '$remote_variant_win' -Variant '$variant' -SourceSha '$source_sha'
exit \$LASTEXITCODE
EOF
)
    set +e
    remote_ps "$remote_run_script" | tee "$RUN_DIR/remote-probe.log"
    local remote_rc=${PIPESTATUS[0]}
    set -e

    # The result file is mandatory even on failure: it carries the exact
    # missing-report/stale/warning/semantic reason without trusting stdout.
    local result_local="$RUN_DIR/probe-result.json"
    set +e
    scp -q "${REMOTE_HOST}:$remote_variant/probe-result.json" "$result_local"
    local result_scp_rc=$?
    scp -q "${REMOTE_HOST}:$remote_variant/synthesis.log" "$RUN_DIR/synthesis.log"
    scp -q "${REMOTE_HOST}:$remote_variant/quartus-eda.log" "$RUN_DIR/quartus-eda.log"
    scp -q "${REMOTE_HOST}:$remote_variant/quartus/output_files/lcvex_logic_imm_probe.syn.rpt" \
        "$RUN_DIR/lcvex_logic_imm_probe.syn.rpt"
    set -e
    if (( result_scp_rc != 0 )) || [[ ! -s "$result_local" ]]; then
        echo "LOGIC_IMM_REGRESSION_FAIL missing-remote-result ssh_rc=$remote_rc" >&2
        exit 1
    fi
    local status warning_count postmap_status report_path
    status=$(python3 - "$result_local" <<'PY'
import json, sys
d=json.load(open(sys.argv[1], encoding='utf-8'))
print(d.get('status',''))
PY
)
    warning_count=$(python3 - "$result_local" <<'PY'
import json, sys
d=json.load(open(sys.argv[1], encoding='utf-8'))
print(d.get('synthesis',{}).get('warning_16788_count',-1))
PY
)
    postmap_status=$(python3 - "$result_local" <<'PY'
import json, sys
d=json.load(open(sys.argv[1], encoding='utf-8'))
print(d.get('postmap',{}).get('semantic_status',''))
PY
)
    report_path=$(python3 - "$result_local" <<'PY'
import json, sys
d=json.load(open(sys.argv[1], encoding='utf-8'))
print(d.get('synthesis',{}).get('report',''))
PY
)
    {
        echo "remote_exit=$remote_rc"
        echo "status=$status"
        echo "warning_16788_count=$warning_count"
        echo "postmap_semantic_status=$postmap_status"
        echo "remote_report=$report_path"
        echo "remote_root=$remote_variant"
    } | tee "$RUN_DIR/remote-summary.txt"
    if (( remote_rc != 0 )) || [[ "$status" != PASS_* ]]; then
        echo "LOGIC_IMM_REGRESSION_FAIL remote-probe status=$status rc=$remote_rc" >&2
        exit 1
    fi
    if [[ "$MODE" == "--old-negative" && "$warning_count" -lt 1 ]]; then
        echo "LOGIC_IMM_REGRESSION_FAIL old-negative-warning-contract" >&2
        exit 1
    fi
    if [[ "$MODE" == "--fixed" && "$warning_count" -ne 0 ]]; then
        echo "LOGIC_IMM_REGRESSION_FAIL fixed-warning-16788=$warning_count" >&2
        exit 1
    fi
    echo "LOGIC_IMM_QUARTUS_${RUN_NAME^^}_PASS warning16788=$warning_count postmap=$postmap_status"
}

case "$MODE" in
    --behavioral) run_behavioral ;;
    --old-negative|--fixed) run_remote ;;
esac
