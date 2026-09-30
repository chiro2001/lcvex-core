#!/usr/bin/env bash
# P7-4 FMA/转换：L0-L2 可复现入口（A76 required strict lockstep）。
# 用法：bash sim/difftest/run_p7_4.sh [--only main|edge|rounding|sequence]
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ONLY="${1:-all}"
mkdir -p "$REPO/build/difftest"
make -C "$REPO" lockstep-build >/dev/null
make -C "$REPO/qemu/plugins" >/dev/null
run_one() {
  local name=$1 max=$2
  local image="$REPO/build/difftest/$name.bin"
  python3 - "$image" "$name" <<PY
import sys
sys.path.insert(0, "$REPO/sim/difftest")
import test_program
builder = getattr(test_program, "$name".replace("hard_", "build_hard_").replace("-", "_") + "_program")
n = builder(sys.argv[1])
assert n == int("$max"), (n, "$max")
PY
  FP_NEON=required IMAGE="$image" MAX_INSNS="$max" \
    COORD="$REPO/build/verilator_lockstep/lockstep_coordinator" \
    bash "$REPO/sim/difftest/run_lockstep_step.sh"
}
if [[ "$ONLY" == "all" || "$ONLY" == "main" ]]; then
  run_one hard_p7_4_fma_convert 94
fi
if [[ "$ONLY" == "all" || "$ONLY" == "edge" ]]; then
  run_one hard_p7_4_fma_convert_edge 54
fi
if [[ "$ONLY" == "all" || "$ONLY" == "rounding" ]]; then
  run_one hard_p7_4_fma_convert_rounding 27
fi
if [[ "$ONLY" == "all" || "$ONLY" == "sequence" ]]; then
  run_one hard_p7_4_fma_convert_sequence 142
fi
