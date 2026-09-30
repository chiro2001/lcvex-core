#!/usr/bin/env bash
# B25 post/pre-index writeback focused matrix.  All architectural expectations
# come from the normal QEMU lockstep coordinator; this runner has no golden
# result table and does not alter existing tests.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
ROOT="${B25_POSTPRE_MATRIX_ROOT:-$REPO/build/agents/T-20260908-002/matrix}"
mkdir -p "$ROOT/logs" "$ROOT/tmp" "$REPO/build/difftest"
cd "$REPO"
export TMPDIR="$ROOT/tmp"
export TMP="$ROOT/tmp"
export TEMP="$ROOT/tmp"
export VERILATOR_JOBS="${VERILATOR_JOBS:-2}"
IMAGE="$ROOT/b25_postpre_writeback_matrix.bin"

conda run --no-capture-output -n lcvex python3 \
  sim/difftest/b25_postpre_writeback_matrix.py "$IMAGE" \
  2>&1 | tee "$ROOT/logs/image-build.log"
make -C qemu/plugins 2>&1 | tee "$ROOT/logs/plugin-build.log"

run_one() {
  local name="$1" coord="$2"
  local sock="$ROOT/$name.sock" dump="$ROOT/$name.fail"
  local coord_log="$ROOT/logs/$name.coord.log"
  local qemu_log="$ROOT/logs/$name.qemu.log"
  local run_log="$ROOT/logs/$name.run.log"
  echo "===== $name =====" | tee "$run_log"
  set +e
  IMAGE="$IMAGE" MAX_INSNS=180 COORD="$REPO/$coord" \
    SOCK="$sock" DUMP="$dump" COORD_LOG="$coord_log" QEMU_LOG="$qemu_log" \
    bash sim/difftest/run_lockstep_step.sh 2>&1 | tee -a "$run_log"
  local rc="${PIPESTATUS[0]}"
  set -e
  printf 'rc=%s\n' "$rc" | tee "$ROOT/$name.result"
  return "$rc"
}

make lockstep-build
run_one base build/verilator_lockstep/lockstep_coordinator
make lockstep-build-l1dl2
run_one cache build/verilator_lockstep_l1dl2/lockstep_coordinator
make lockstep-build-l1dl2-delay2
run_one delay2 build/verilator_lockstep_l1dl2_d2/lockstep_coordinator

echo "PASS: B25 post/pre writeback matrix base/cache/delay2" | tee "$ROOT/summary.log"
