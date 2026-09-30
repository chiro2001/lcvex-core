#!/usr/bin/env bash
# F1a strict lockstep scaffold.
#
# The coordinator binaries must be built with FETCH_FIFO_ENABLE=1 by the
# caller. Three binaries may be supplied to distinguish base, I-L1/cache,
# and delay2 configurations; when omitted, COORD is reused for a smoke run.
# The first implementation pass does not run this script because its test slot
# is withheld by the integration queue.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO"
BUILD_DIR="${F1A_BUILD_DIR:-$REPO/build/difftest/f1a}"
mkdir -p "$BUILD_DIR"

COORD_BASE="${COORD_BASE:-${COORD:-$REPO/build/verilator_lockstep_f1a/lockstep_coordinator}}"
COORD_CACHE="${COORD_CACHE:-${COORD:-$REPO/build/verilator_lockstep_f1a_cache/lockstep_coordinator}}"
COORD_DELAY2="${COORD_DELAY2:-${COORD:-$REPO/build/verilator_lockstep_f1a_delay2/lockstep_coordinator}}"
MAX_INSNS="${MAX_INSNS:-32}"

if [[ -n "${IMAGE:-}" ]]; then
  images=("$IMAGE")
else
  python3 - "$BUILD_DIR" <<'PY'
import sys
from pathlib import Path

sys.path.insert(0, "sim/difftest")
import test_program

out = Path(sys.argv[1])
builders = {
    "hard_fetch_epoch": test_program.build_hard_fetch_epoch_program,
    "hard_fetch_duplicate": test_program.build_hard_fetch_duplicate_program,
    "hard_fetch_ready_hold": test_program.build_hard_fetch_ready_hold_program,
    "hard_fetch_4k": test_program.build_hard_fetch_4k_program,
    "hard_fetch_line": test_program.build_hard_fetch_line_program,
    "hard_fetch_reset": test_program.build_hard_fetch_reset_program,
}
for name, builder in builders.items():
    builder(str(out / f"{name}.bin"))
PY
  images=(
    "$BUILD_DIR/hard_fetch_epoch.bin"
    "$BUILD_DIR/hard_fetch_duplicate.bin"
    "$BUILD_DIR/hard_fetch_ready_hold.bin"
    "$BUILD_DIR/hard_fetch_4k.bin"
    "$BUILD_DIR/hard_fetch_line.bin"
    "$BUILD_DIR/hard_fetch_reset.bin"
  )
fi

run_case() {
  local label="$1"
  local coord="$2"
  local image="$3"
  local sock="$BUILD_DIR/${label}.sock"
  local dump="$BUILD_DIR/${label}.fail.txt"
  local coord_log="$BUILD_DIR/${label}.coord.log"
  local qemu_log="$BUILD_DIR/${label}.qemu.log"
  [[ -f "$coord" ]] || { echo "错误：找不到 F1a coordinator=$coord" >&2; exit 1; }
  [[ -f "$image" ]] || { echo "错误：找不到 F1a image=$image" >&2; exit 1; }
  IMAGE="$image" MAX_INSNS="$MAX_INSNS" COORD="$coord" \
    SOCK="$sock" DUMP="$dump" COORD_LOG="$coord_log" QEMU_LOG="$qemu_log" \
    bash "$REPO/sim/difftest/run_lockstep_step.sh"
}

for image in "${images[@]}"; do
  stem="$(basename "$image" .bin)"
  run_case "${stem}_base" "$COORD_BASE" "$image"
  run_case "${stem}_cache" "$COORD_CACHE" "$image"
  run_case "${stem}_delay2" "$COORD_DELAY2" "$image"
done

echo "PASS: F1a lockstep matrix scaffold (base/cache/delay2 × ${#images[@]} images)"
