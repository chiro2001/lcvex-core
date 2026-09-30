#!/usr/bin/env bash
# P6 WFI/WFE 等待与 Generic Timer/GIC IRQ 唤醒锁步。
set -euo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO"
QEMU_BIN="${QEMU_BIN:-$REPO/../qemu/build/qemu-system-aarch64}"

make -C qemu/plugins
python3 - <<'PY'
import sys
sys.path.insert(0, "sim/difftest")
import test_program
test_program.build_hard_wfi_program("build/difftest/hard_wfi.bin")
test_program.build_hard_wfe_program("build/difftest/hard_wfe.bin")
test_program.build_hard_wfit_wfet_timer_program(
    "build/difftest/hard_wfit_wfet_timer.bin")
test_program.build_hard_wfi_timer_irq_program(
    "build/difftest/hard_wfi_timer_irq.bin")
PY

run_phase() {
  local coord=$1 phase=$2
  echo "===== P6 WFI/WFE phase=$phase ====="
  IMAGE="$REPO/build/difftest/hard_wfi.bin" MAX_INSNS=2 \
    COORD="$REPO/$coord" QEMU_BIN="$QEMU_BIN" \
    bash sim/difftest/run_lockstep_step.sh
  IMAGE="$REPO/build/difftest/hard_wfe.bin" MAX_INSNS=2 \
    COORD="$REPO/$coord" QEMU_BIN="$QEMU_BIN" \
    bash sim/difftest/run_lockstep_step.sh
  IMAGE="$REPO/build/difftest/hard_wfit_wfet_timer.bin" MAX_INSNS=14 \
    COORD="$REPO/$coord" QEMU_BIN="$QEMU_BIN" \
    bash sim/difftest/run_lockstep_step.sh
  IMAGE="$REPO/build/difftest/hard_wfi_timer_irq.bin" MAX_INSNS=45 \
    COORD="$REPO/$coord" QEMU_BIN="$QEMU_BIN" \
    bash sim/difftest/run_lockstep_step.sh
}

make lockstep-build
run_phase build/verilator_lockstep/lockstep_coordinator base
make lockstep-build-l1dl2
run_phase build/verilator_lockstep_l1dl2/lockstep_coordinator cache

echo "PASS: P6 WFI/WFE/Timer IRQ base/cache 全部锁步通过"
