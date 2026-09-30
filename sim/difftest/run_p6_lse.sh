#!/usr/bin/env bash
# P6 LSE 原子定向锁步：LD*/ST* 原子族 + CAS W/X。
# 用法：bash sim/difftest/run_p6_lse.sh [--only base|cache]
set -euo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO"

ONLY="${ONLY:-}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --only) ONLY="${2:-}"; shift 2 ;;
    *) echo "未知参数：$1" >&2; exit 2 ;;
  esac
done

make -C qemu/plugins
python3 - <<'PY'
import sys
sys.path.insert(0, "sim/difftest")
import test_program
test_program.build_hard_lse_atomic_program("build/difftest/hard_lse_atomic.bin")
print("hard_lse_atomic.bin 生成完成")
PY

run_one() {
  local phase=$1 coord=$2
  if [[ -n "$ONLY" && "$ONLY" != "$phase" ]]; then
    return 0
  fi
  echo "===== hard_lse_atomic ($phase) ====="
  IMAGE="$REPO/build/difftest/hard_lse_atomic.bin" \
  MAX_INSNS="${MAX_INSNS:-100}" COORD="$REPO/$coord" \
    bash sim/difftest/run_lockstep_step.sh
}

make lockstep-build
run_one base build/verilator_lockstep/lockstep_coordinator

make lockstep-build-l1dl2
run_one cache build/verilator_lockstep_l1dl2/lockstep_coordinator

echo "PASS: P6 LSE 原子定向测试 base/cache 均与 QEMU 一致"
