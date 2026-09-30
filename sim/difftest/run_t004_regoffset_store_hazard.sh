#!/usr/bin/env bash
# T-20260908-004：register-offset store index/data dependency focused runner。
#
# The runner owns all images, coordinators, sockets, logs and temporary files
# below build/agents/T-20260908-004.  It intentionally does not call
# make -C qemu/plugins: callers must provide a read-only, already-built QEMU
# plugin with PLUGIN (the task forbids QEMU writes).
set -euo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO"

ART="${T004_ARTIFACT_ROOT:-$REPO/build/agents/T-20260908-004}"
TMPDIR="${T004_TMPDIR:-$ART/tmp}"
CONDA_ENV="${CONDA_ENV:-lcvex}"
VERILATOR_JOBS="${VERILATOR_JOBS:-1}"
QEMU_BIN="${QEMU_BIN:-$REPO/../qemu/build/qemu-system-aarch64}"
PLUGIN="${PLUGIN:-$REPO/qemu/plugins/lcvex_difftest.so}"
mkdir -p "$ART/images" "$ART/coordinators" "$ART/runs" "$TMPDIR"
export TMPDIR

FOCUSED_IMAGE="$ART/images/t004_regoffset_store_hazard.bin"
FOCUSED_META="$ART/images/t004_regoffset_store_hazard.meta"
HARD_IMAGE="$ART/images/hard_reg_offset.bin"

# Generate a compact program with adjacent producer -> register-offset
# consumers.  The image uses only existing a64/test_program helpers; no
# tracked generator or expectation is modified.
conda run --no-capture-output -n "$CONDA_ENV" python3 - "$FOCUSED_IMAGE" "$FOCUSED_META" "$HARD_IMAGE" <<'PY'
import sys
from pathlib import Path

sys.path.insert(0, "sim/difftest")
from a64 import Insn, assemble
import test_program

focused_path = Path(sys.argv[1])
meta_path = Path(sys.argv[2])
hard_path = Path(sys.argv[3])
base = test_program.BASE

program = [
    # Base and data setup.
    Insn("movz", 20, 0x4408, 1),
    Insn("movz", 0, 0x5A),

    # rm != rt: each index producer is immediately before its store.
    Insn("movz", 23, 1),
    Insn("strb_reg", 0, 20, 23, 0),
    Insn("movz", 1, 1),
    Insn("ldrb_reg", 2, 20, 1, 0),
    Insn("movz", 23, 2),
    Insn("strh_reg", 0, 20, 23, 1),
    Insn("movz", 1, 2),
    Insn("ldrh_reg", 2, 20, 1, 1),
    Insn("movz", 23, 3),
    Insn("strw_reg", 0, 20, 23, 1),
    Insn("movz", 1, 3),
    Insn("ldrw_reg", 2, 20, 1, 1),
    Insn("movz", 23, 4),
    Insn("str_reg", 0, 20, 23, 1),
    Insn("movz", 1, 4),
    Insn("ldr_reg", 2, 20, 1, 1),

    # rm == rt: the same producer supplies address index and store data.
    Insn("movz", 23, 5),
    Insn("strb_reg", 23, 20, 23, 0),
    Insn("movz", 1, 5),
    Insn("ldrb_reg", 2, 20, 1, 0),
    Insn("movz", 23, 6),
    Insn("strh_reg", 23, 20, 23, 1),
    Insn("movz", 1, 6),
    Insn("ldrh_reg", 2, 20, 1, 1),
    Insn("movz", 23, 7),
    Insn("strw_reg", 23, 20, 23, 1),
    Insn("movz", 1, 7),
    Insn("ldrw_reg", 2, 20, 1, 1),
    Insn("movz", 23, 8),
    Insn("str_reg", 23, 20, 23, 1),
    Insn("movz", 1, 8),
    Insn("ldr_reg", 2, 20, 1, 1),

    # XZR index and immediate preceding data/base producers.
    Insn("movz", 0, 0x7F),
    Insn("strb_reg", 0, 20, 31, 0),
    Insn("movz", 0, 0x1234),
    Insn("strh_reg", 0, 20, 31, 1),
    Insn("movz", 20, 0x4408, 1),
    Insn("strw_reg", 0, 20, 31, 1),

    # One more explicit producer -> STR register-offset pair.
    Insn("movz", 23, 0x20),
    Insn("str_reg", 0, 20, 23, 1),
    Insn("movz", 1, 0x20),
    Insn("ldr_reg", 2, 20, 1, 1),
    Insn("label", "loop"),
    Insn("b", "loop"),
]
words = assemble(program, base)
assert 0x78377A80 in words, hex(words)
test_program.build_program(focused_path, words)
meta_path.write_text(
    "name=t004_regoffset_store_hazard\n"
    f"base=0x{base:08x}\nwords={len(words)}\n"
    "exact_encoding=0x78377a80\n"
    "matrix=rm_ne_rt,rm_eq_rt,xzr_index,base_hazard,data_hazard,strb,strh,strw,str\n",
    encoding="utf-8",
)
test_program.build_hard_reg_offset_program(hard_path)
print(f"focused_image={focused_path} words={len(words)} exact=0x78377a80")
print(f"existing_image={hard_path}")
PY

MAX_FOCUSED="$(awk -F= '/^words=/{print $2}' "$FOCUSED_META")"
if [[ -z "$MAX_FOCUSED" ]]; then
  echo "FAIL: focused image metadata has no words" >&2
  exit 1
fi

if [[ "${T004_GENERATE_ONLY:-0}" == "1" ]]; then
  echo "PASS: generated T-20260908-004 focused image only"
  exit 0
fi

if [[ ! -f "$QEMU_BIN" ]]; then
  echo "FAIL: QEMU binary not found: $QEMU_BIN" >&2
  exit 1
fi
if [[ ! -f "$PLUGIN" ]]; then
  echo "FAIL: prebuilt read-only QEMU plugin not found: $PLUGIN" >&2
  exit 1
fi

build_coord() {
  local name="$1"
  shift
  local dir="$ART/coordinators/$name"
  mkdir -p "$dir"
  conda run --no-capture-output -n "$CONDA_ENV" verilator \
    --cc --exe --build --timing --assert -Wall -Wno-fatal -Wno-UNUSEDPARAM \
    -j "$VERILATOR_JOBS" --top-module lcvex_soc_tb "$@" \
    -Mdir "$dir" -o lockstep_coordinator --public-flat-rw \
    -f rtl/filelist.f tb/sv/lcvex_soc_tb.sv \
    -CFLAGS "-I/usr/include" -LDFLAGS "-lz" \
    sim/mmio/lcvex_mmio_fabric.cc sim/difftest/lockstep_coordinator.cc \
    > "$ART/coordinators/$name.build.log" 2>&1
  printf '%s\n' "$dir/lockstep_coordinator"
}

BASE_COORD="$(build_coord base)"
CACHE_COORD="$(build_coord cache -GI_L1_ENABLE=1 -GD_L1_ENABLE=1 -GL2_ENABLE=1)"
DELAY2_COORD="$(build_coord delay2 -GI_L1_ENABLE=1 -GD_L1_ENABLE=1 -GL2_ENABLE=1 -GMEM_DELAY_MODE=2)"

run_one() {
  local name="$1" image="$2" max_insns="$3" coord="$4"
  local dir="$ART/runs/$name"
  mkdir -p "$dir"
  IMAGE="$image" MAX_INSNS="$max_insns" COORD="$coord" \
    QEMU_BIN="$QEMU_BIN" PLUGIN="$PLUGIN" \
    SOCK="$dir/step.sock" DUMP="$dir/fail.txt" \
    COORD_LOG="$dir/coord.log" QEMU_LOG="$dir/qemu.log" \
    CKPT_DIR="$dir/ckpt" MON_SOCK="$dir/step.mon" \
    PROGRESS_EVERY=1 \
    bash sim/difftest/run_lockstep_step.sh > "$dir/run.log" 2>&1
}

# Existing regression plus the new adjacent-dependency image, each in base,
# full-cache and randomized-delay full-cache configurations.
run_one existing-base "$HARD_IMAGE" 45 "$BASE_COORD"
run_one existing-cache "$HARD_IMAGE" 45 "$CACHE_COORD"
run_one existing-delay2 "$HARD_IMAGE" 45 "$DELAY2_COORD"
run_one focused-base "$FOCUSED_IMAGE" "$MAX_FOCUSED" "$BASE_COORD"
run_one focused-cache "$FOCUSED_IMAGE" "$MAX_FOCUSED" "$CACHE_COORD"
run_one focused-delay2 "$FOCUSED_IMAGE" "$MAX_FOCUSED" "$DELAY2_COORD"

echo "PASS: T-20260908-004 register-offset store hazard matrix base/cache/delay2"
