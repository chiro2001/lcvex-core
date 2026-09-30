#!/usr/bin/env bash
# B25: independent ELF-derived BRAM image contract plus focused SV test.
set -euo pipefail

TASK_ID="T-20260909-001"
SCRIPT_PATH="$(CDPATH= cd -- "$(dirname "$0")" && pwd)/$(basename "$0")"
TOOLS_DIR="$(CDPATH= cd -- "$(dirname "$SCRIPT_PATH")" && pwd)"
PLATFORM_DIR="$(CDPATH= cd -- "$TOOLS_DIR/.." && pwd)"
REPO_DIR="$(CDPATH= cd -- "$PLATFORM_DIR/../.." && pwd)"
BOOT_DIR="$PLATFORM_DIR/boot"
CHECKER="$BOOT_DIR/check_image_contract.py"
BOOT_OUTPUT_DIR="${LCVEX_BRAM_BOOT_BUILD_DIR:-$REPO_DIR/build/agents/$TASK_ID/boot}"
OUT_DIR="${LCVEX_BRAM_INIT25_TEST_DIR:-$REPO_DIR/build/agents/$TASK_ID/bram-init25}"
ORACLE_DIR="$OUT_DIR/oracle"
FAULT_DIR="$OUT_DIR/faults"
TMP_DIR="${LCVEX_BRAM_INIT25_TMPDIR:-$OUT_DIR/tmp}"
PYTHON_BIN="${PYTHON_BIN:-python3}"
RESOURCE_LOCK="/home/chiro/projects/.resource-locks/resource-lock"
MIN_LOCAL_MIB="${LCVEX_MIN_LOCAL_AVAILABLE_MIB:-8192}"
VERILATOR_JOBS_VALUE="${VERILATOR_JOBS:-1}"

if [[ "${1:-}" == "--heavy-run" ]]; then
    shift
    if [[ $# -ne 3 ]]; then
        echo "LCVEX_BRAM_INIT25_HEAVY_FAIL usage=--heavy-run OUT_DIR BOOT_HEX EXPECTED_HEX" >&2
        exit 2
    fi
    heavy_out="$1"
    heavy_boot_hex="$2"
    heavy_expected_hex="$3"
    mkdir -p "$heavy_out/obj_dir" "$heavy_out/tmp"
    export TMPDIR="${LCVEX_BRAM_INIT25_TMPDIR:-$heavy_out/tmp}"

    if [[ -n "${VERILATOR_BIN:-}" ]]; then
        read -r -a verilator_command <<< "$VERILATOR_BIN"
    elif command -v verilator >/dev/null 2>&1; then
        verilator_command=(verilator)
    elif command -v conda >/dev/null 2>&1 && conda env list | awk '{print $1}' | grep -qx lcvex; then
        verilator_command=(conda run --no-capture-output -n lcvex verilator)
    else
        echo "LCVEX_BRAM_INIT25_HEAVY_FAIL TOOL_MISSING=verilator" >&2
        exit 127
    fi

    echo "LCVEX_BRAM_INIT25_HEAVY_RUN"
    echo "repo=$REPO_DIR"
    echo "output=$heavy_out"
    echo "boot_hex=$heavy_boot_hex"
    echo "expected_image=$heavy_expected_hex"
    echo "verilator_jobs=$VERILATOR_JOBS_VALUE"
    "${verilator_command[@]}" --version
    set +e
    /usr/bin/busybox time -v "${verilator_command[@]}" \
        --binary --timing --assert \
        -j "$VERILATOR_JOBS_VALUE" \
        -Wall -Wno-fatal \
        -Wno-DECLFILENAME -Wno-PINMISSING -Wno-UNUSEDSIGNAL \
        -Wno-UNDRIVEN -Wno-WIDTHEXPAND -Wno-UNSIGNED -Wno-PROCASSINIT \
        --top-module lcvex_bram_init25_tb \
        "-GBOOT_HEX_FILE=\"$heavy_boot_hex\"" \
        "-GEXPECTED_IMAGE_FILE=\"$heavy_expected_hex\"" \
        -Mdir "$heavy_out/obj_dir" -o lcvex_bram_init25_tb \
        "$REPO_DIR/rtl/lcvex_pkg.sv" \
        "$REPO_DIR/rtl/lcvex_bram_boot.sv" \
        "$REPO_DIR/tb/sv/lcvex_bram_init25_tb.sv" \
        > "$heavy_out/verilator-build.log" 2>&1
    compile_rc=$?
    set -e
    cat "$heavy_out/verilator-build.log"
    if [[ $compile_rc -ne 0 ]]; then
        echo "LCVEX_BRAM_INIT25_HEAVY_FAIL compile_exit=$compile_rc" >&2
        exit "$compile_rc"
    fi
    set +e
    /usr/bin/busybox time -v "$heavy_out/obj_dir/lcvex_bram_init25_tb" > "$heavy_out/verilator-run.log" 2>&1
    run_rc=$?
    set -e
    cat "$heavy_out/verilator-run.log"
    if [[ $run_rc -ne 0 ]]; then
        echo "LCVEX_BRAM_INIT25_HEAVY_FAIL run_exit=$run_rc" >&2
        exit "$run_rc"
    fi
    if ! grep -Fqx "BRAM_INIT25_TB PASS" "$heavy_out/verilator-run.log"; then
        echo "LCVEX_BRAM_INIT25_HEAVY_FAIL missing-pass-marker" >&2
        exit 1
    fi
    echo "LCVEX_BRAM_INIT25_HEAVY_PASS"
    exit 0
fi

cd "$REPO_DIR"
mkdir -p "$OUT_DIR" "$ORACLE_DIR" "$FAULT_DIR" "$TMP_DIR"

echo "LCVEX_BRAM_INIT25_TEST"
echo "task=$TASK_ID"
echo "repo=$REPO_DIR"
echo "output=$OUT_DIR"
echo "boot_output=$BOOT_OUTPUT_DIR"
echo "source_sha=$(git rev-parse HEAD)"

BOOT_BUILD_LOG="$OUT_DIR/boot-build.log"
if ! env LCVEX_BOOT_BUILD_DIR="$BOOT_OUTPUT_DIR" bash "$BOOT_DIR/build.sh" > "$BOOT_BUILD_LOG" 2>&1; then
    cat "$BOOT_BUILD_LOG"
    echo "LCVEX_BRAM_INIT25_TEST_FAIL boot-build" >&2
    exit 1
fi
cat "$BOOT_BUILD_LOG"

ELF="$BOOT_OUTPUT_DIR/boot.elf"
BIN="$BOOT_OUTPUT_DIR/boot.bin"
HEX="$BOOT_OUTPUT_DIR/boot.hex"
MIF="$BOOT_OUTPUT_DIR/boot.mif"
EXPECTED="$ORACLE_DIR/expected_image.hex"
MANIFEST="$ORACLE_DIR/image_manifest.json"
SOURCE_BOOT_S="$REPO_DIR/fpga/catapult_a10/boot/boot.S"
SOURCE_BOOT_LD="$REPO_DIR/fpga/catapult_a10/boot/boot.ld"
SOURCE_BUILD_SH="$REPO_DIR/fpga/catapult_a10/boot/build.sh"
SOURCE_BIN_TO_MIF="$REPO_DIR/fpga/catapult_a10/boot/bin_to_mif.py"

CHECK_ARGS=(
    --elf "$ELF" --bin "$BIN" --hex "$HEX" --mif "$MIF"
    --expected "$EXPECTED" --manifest "$MANIFEST"
    --source "$SOURCE_BOOT_S" --source "$SOURCE_BOOT_LD"
    --source "$SOURCE_BUILD_SH" --source "$SOURCE_BIN_TO_MIF"
)

"$PYTHON_BIN" "$CHECKER" --emit "${CHECK_ARGS[@]}" > "$ORACLE_DIR/contract-emit.log" 2>&1
cat "$ORACLE_DIR/contract-emit.log"
"$PYTHON_BIN" "$CHECKER" --check "${CHECK_ARGS[@]}" > "$ORACLE_DIR/contract-check.log" 2>&1
cat "$ORACLE_DIR/contract-check.log"

fixture_check() {
    local fixture_dir="$1"
    "$PYTHON_BIN" "$CHECKER" --check \
        --elf "$fixture_dir/boot.elf" \
        --bin "$fixture_dir/boot.bin" \
        --hex "$fixture_dir/boot.hex" \
        --mif "$fixture_dir/boot.mif" \
        --expected "$fixture_dir/expected_image.hex" \
        --manifest "$fixture_dir/image_manifest.json"
}

make_fixture() {
    local case_name="$1"
    local fixture_dir="$FAULT_DIR/$case_name"
    mkdir -p "$fixture_dir"
    cp "$ELF" "$fixture_dir/boot.elf"
    cp "$BIN" "$fixture_dir/boot.bin"
    cp "$HEX" "$fixture_dir/boot.hex"
    cp "$MIF" "$fixture_dir/boot.mif"
    "$PYTHON_BIN" "$CHECKER" --emit \
        --elf "$fixture_dir/boot.elf" \
        --bin "$fixture_dir/boot.bin" \
        --hex "$fixture_dir/boot.hex" \
        --mif "$fixture_dir/boot.mif" \
        --expected "$fixture_dir/expected_image.hex" \
        --manifest "$fixture_dir/image_manifest.json" \
        --source "$SOURCE_BOOT_S" --source "$SOURCE_BOOT_LD" \
        --source "$SOURCE_BUILD_SH" --source "$SOURCE_BIN_TO_MIF" \
        > "$fixture_dir/emit.log" 2>&1
    echo "$fixture_dir"
}

expect_failure() {
    local case_name="$1"
    local fixture_dir="$2"
    local log_path="$fixture_dir/negative-check.log"
    shift 2
    set +e
    fixture_check "$fixture_dir" "$@" > "$log_path" 2>&1
    local check_rc=$?
    set -e
    cat "$log_path"
    if [[ $check_rc -eq 0 ]]; then
        echo "NEGATIVE_FAIL case=$case_name checker-unexpected-pass" >&2
        return 1
    fi
    echo "NEGATIVE_PASS case=$case_name exit=$check_rc"
}

mutate_reset_byte() {
    python3 - "$1" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
b = bytearray(p.read_bytes())
b[0x10000] ^= 0x01
p.write_bytes(b)
PY
}

mutate_imm19() {
    python3 - "$1" <<'PY'
from pathlib import Path
import struct
import sys
p = Path(sys.argv[1])
b = bytearray(p.read_bytes())
word = struct.unpack_from('<I', b, 0x10000)[0]
struct.pack_into('<I', b, 0x10000, word ^ (1 << 5))
p.write_bytes(b)
PY
}

mutate_mov_sp() {
    python3 - "$1" <<'PY'
from pathlib import Path
import struct
import sys
p = Path(sys.argv[1])
b = bytearray(p.read_bytes())
word = struct.unpack_from('<I', b, 0x10004)[0]
struct.pack_into('<I', b, 0x10004, word ^ (1 << 5))
p.write_bytes(b)
PY
}

mutate_bin_byte_reverse() {
    python3 - "$1" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
b = bytearray(p.read_bytes())
b[0:8] = b[0:8][::-1]
p.write_bytes(b)
PY
}

mutate_bin_word_swap() {
    python3 - "$1" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
b = bytearray(p.read_bytes())
b[0:8] = b[4:8] + b[0:4]
p.write_bytes(b)
PY
}

mutate_hex_first() {
    python3 - "$1" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
lines = p.read_text(encoding='ascii').splitlines()
lines[0] = 'ff'
p.write_text('\n'.join(lines) + '\n', encoding='ascii')
PY
}

mutate_hex_extra() {
    python3 - "$1" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
p.write_text(p.read_text(encoding='ascii') + '00\n', encoding='ascii')
PY
}

mutate_mif_lane() {
    python3 - "$1" <<'PY'
from pathlib import Path
import re
import sys
p = Path(sys.argv[1])
lines = p.read_text(encoding='ascii').splitlines()
for index, line in enumerate(lines):
    if re.match(r'^0000\s*:', line):
        value = line.split(':', 1)[1].split(';', 1)[0].strip()
        lines[index] = f'0000 : {bytes.fromhex(value)[::-1].hex().upper()};'
        break
else:
    raise SystemExit('MIF address 0000 not found')
p.write_text('\n'.join(lines) + '\n', encoding='ascii')
PY
}

mutate_mif_record() {
    python3 - "$1" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
lines = p.read_text(encoding='ascii').splitlines()
for index, line in enumerate(lines):
    if line.startswith('0001 :'):
        lines[index] = line.replace('0001 :', '0000 :', 1)
        break
else:
    raise SystemExit('MIF address 0001 not found')
p.write_text('\n'.join(lines) + '\n', encoding='ascii')
PY
}

mutate_mif_padding() {
    python3 - "$1" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
lines = p.read_text(encoding='ascii').splitlines()
for index, line in enumerate(lines):
    if line.startswith('1FFF :'):
        lines[index] = '1FFF : 0000000000000001;'
        break
else:
    raise SystemExit('MIF address 1FFF not found')
p.write_text('\n'.join(lines) + '\n', encoding='ascii')
PY
}

mutate_expected_stale() {
    python3 - "$1" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
lines = p.read_text(encoding='ascii').splitlines()
lines[0] = 'ff'
p.write_text('\n'.join(lines) + '\n', encoding='ascii')
PY
}

echo "LCVEX_BRAM_INIT25_NEGATIVE_FAULTS"
fixture_dir="$(make_fixture missing_expected)"
mv "$fixture_dir/expected_image.hex" "$fixture_dir/expected_image.hex.missing"
expect_failure missing_expected "$fixture_dir"
fixture_dir="$(make_fixture wrong_hex_path)"
mv "$fixture_dir/boot.hex" "$fixture_dir/boot.hex.missing"
expect_failure wrong_hex_path "$fixture_dir"
fixture_dir="$(make_fixture reset_byte)"
mutate_reset_byte "$fixture_dir/boot.elf"
expect_failure reset_byte "$fixture_dir"
fixture_dir="$(make_fixture imm19_target)"
mutate_imm19 "$fixture_dir/boot.elf"
expect_failure imm19_target "$fixture_dir"
fixture_dir="$(make_fixture mov_sp)"
mutate_mov_sp "$fixture_dir/boot.elf"
expect_failure mov_sp "$fixture_dir"
fixture_dir="$(make_fixture byte_reverse_bin)"
mutate_bin_byte_reverse "$fixture_dir/boot.bin"
expect_failure byte_reverse_bin "$fixture_dir"
fixture_dir="$(make_fixture word_swap_bin)"
mutate_bin_word_swap "$fixture_dir/boot.bin"
expect_failure word_swap_bin "$fixture_dir"
fixture_dir="$(make_fixture hex_byte)"
mutate_hex_first "$fixture_dir/boot.hex"
expect_failure hex_byte "$fixture_dir"
fixture_dir="$(make_fixture hex_extra)"
mutate_hex_extra "$fixture_dir/boot.hex"
expect_failure hex_extra "$fixture_dir"
fixture_dir="$(make_fixture mif_lane)"
mutate_mif_lane "$fixture_dir/boot.mif"
expect_failure mif_lane "$fixture_dir"
fixture_dir="$(make_fixture mif_record)"
mutate_mif_record "$fixture_dir/boot.mif"
expect_failure mif_record "$fixture_dir"
fixture_dir="$(make_fixture mif_nonzero_padding)"
mutate_mif_padding "$fixture_dir/boot.mif"
expect_failure mif_nonzero_padding "$fixture_dir"
fixture_dir="$(make_fixture stale_expected_hash)"
mutate_expected_stale "$fixture_dir/expected_image.hex"
expect_failure stale_expected_hash "$fixture_dir"
echo "NEGATIVE_SUMMARY pass=13 total=13"

heavy_log="$OUT_DIR/heavy-wrapper.log"
set +e
"$RESOURCE_LOCK" run local mycpu "$TASK_ID" b25_boot_oracle \
    --min-local-available-mib "$MIN_LOCAL_MIB" \
    --meta "stage=bram-init25-verilator" \
    --meta "source_sha=$(git rev-parse HEAD)" \
    --meta "verilator_jobs=$VERILATOR_JOBS_VALUE" \
    -- systemd-run --user --scope \
    -p MemoryMax=16G -p MemorySwapMax=0 \
    -- env TMPDIR="$TMP_DIR" VERILATOR_JOBS="$VERILATOR_JOBS_VALUE" \
    bash "$SCRIPT_PATH" --heavy-run "$OUT_DIR" "$HEX" "$EXPECTED" \
    > "$heavy_log" 2>&1
heavy_rc=$?
set -e
cat "$heavy_log"
if [[ $heavy_rc -eq 75 ]]; then
    echo "LCVEX_BRAM_INIT25_TEST_WAIT exit=75"
    exit 75
fi
if [[ $heavy_rc -ne 0 ]]; then
    echo "LCVEX_BRAM_INIT25_TEST_FAIL heavy_exit=$heavy_rc" >&2
    exit "$heavy_rc"
fi

echo "LCVEX_BRAM_INIT25_TEST_PASS"
