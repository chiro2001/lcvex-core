#!/usr/bin/env bash
# T-055：STXR 同一 COMMIT 普通 IRQ 的 exclusive monitor sidecar 回归。
#
# same-COMMIT success/fail 使用 Generic Timer PPI30 的真实 IRQ 边界：
#   STXR success：IRQ COMMIT mon_we=1、mon_valid=0、store_count=1；
#   STXR fail：IRQ COMMIT mon_we=1、mon_valid=0、store_count=0。
# 其余场景覆盖同步 DABT/IABT、WFI/ASYNC、ordinary IRQ、LDXR/CLREX、
# LSE/LSE128，并保留 T-054 base/delay2 矩阵作为协议回归。所有协议运行
# 都独占 socket/log 前缀，避免 PRE/COMMIT/seq 跨场景串线。
set -euo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO"
QEMU_BIN="${QEMU_BIN:-$REPO/../qemu/build/qemu-system-aarch64}"
PLUGIN="${PLUGIN:-$REPO/qemu/plugins/lcvex_difftest.so}"
COORD_BASE="${COORD_BASE:-$REPO/build/verilator_lockstep/lockstep_coordinator}"
COORD_DELAY2="${COORD_DELAY2:-$REPO/build/verilator_lockstep_d2/lockstep_coordinator}"
PYTHON="${PYTHON:-python3}"
# Keep socket names below Linux sun_path's 108-byte limit.
RUN_ROOT="${RUN_ROOT:-$REPO/build/tmp/t55}"
RUN_T054="${RUN_T054:-1}"
RUN_REGRESSIONS="${RUN_REGRESSIONS:-1}"
MAX_INSNS="${MAX_INSNS:-40}"

for f in "$QEMU_BIN" "$PLUGIN" "$COORD_BASE" "$COORD_DELAY2"; do
  if [[ ! -f "$f" ]]; then
    echo "错误：找不到 $f" >&2
    exit 2
  fi
done

mkdir -p "$REPO/build/difftest" "$RUN_ROOT"

"$PYTHON" "$REPO/sim/difftest/stxr_irq_mon_we_fixture.py"

"$PYTHON" - <<'PY'
import sys
sys.path.insert(0, "sim/difftest")
import test_program
import stxr_irq_mon_we_fixture

builders = {
    "stxr_same_success": lambda p: test_program.build_hard_irq_atomic_overlap_program(
        p, "stxr_success", 12),
    "stxr_same_fail": lambda p: test_program.build_hard_irq_atomic_overlap_program(
        p, "stxr_fail", 9),
    "stxr_sync_dabt": stxr_irq_mon_we_fixture.build_stxr_sync_abort_image,
    "hard_irq": test_program.build_hard_irq_program,
    "hard_irq_daif": test_program.build_hard_irq_daif_program,
    "hard_wfi_timer_irq": test_program.build_hard_wfi_timer_irq_program,
    "hard_exclusive": test_program.build_hard_exclusive_program,
    "hard_lse": test_program.build_hard_lse_atomic_program,
    "hard_lse128": test_program.build_hard_lse128_program,
    "hard_esr_far": test_program.build_hard_esr_far_program,
    "hard_iabt": test_program.build_hard_sys_fetch_fault_program,
    "t054_casp_match": lambda p: test_program.build_hard_irq_atomic_overlap_program(
        p, "casp_match", 14),
    "t054_casp_mismatch": lambda p: test_program.build_hard_irq_atomic_overlap_program(
        p, "casp_mismatch", 16),
    "t054_stxr_success": lambda p: test_program.build_hard_irq_atomic_overlap_program(
        p, "stxr_success", 13),
    "t054_stxr_fail": lambda p: test_program.build_hard_irq_atomic_overlap_program(
        p, "stxr_fail", 13),
    "t054_dc_zva": lambda p: test_program.build_hard_irq_atomic_overlap_program(
        p, "dc_zva", 8),
}
for name, builder in builders.items():
    path = f"build/difftest/t055-{name}.bin"
    base = builder(path)
    if base != 0x44000000:
        raise SystemExit(f"{name}: unexpected image base {base:#x}")
    print(f"generated {path}")
PY

run_case() {
  local phase="$1" name="$2" image="$3" max_insns="$4" expected="$5"
  local prefix="$RUN_ROOT/${phase}-${name}"
  local log="${prefix}.log"
  local rc coord="$COORD_BASE"
  if [[ "$phase" == delay2 ]]; then
    coord="$COORD_DELAY2"
  fi

  echo "T055 QEMU case=$name phase=$phase"
  set +e
  systemd-run --user --scope -p MemoryMax=16G -p MemorySwapMax=0 -- \
    env IMAGE="$REPO/build/difftest/$image.bin" MAX_INSNS="$max_insns" \
      COORD="$coord" \
      QEMU_BIN="$QEMU_BIN" PLUGIN="$PLUGIN" SOCK="${prefix}.sock" \
      DUMP="${prefix}.fail" COORD_LOG="${prefix}.coord" \
      QEMU_LOG="${prefix}.qemu" \
      bash "$REPO/sim/difftest/run_lockstep_step.sh" >"$log" 2>&1
  rc=$?
  set -e
  if [[ "$rc" -ne 0 ]]; then
    echo "T055 QEMU FAIL case=$name phase=$phase rc=$rc log=$log" >&2
    return "$rc"
  fi
  if [[ -n "$expected" ]] && ! rg -q -- "$expected" "${prefix}.coord"; then
    echo "T055 QEMU FAIL case=$name phase=$phase: expected packet missing" >&2
    return 1
  fi
  echo "T055 QEMU PASS case=$name phase=$phase log=$log"
}

# The two failing T-054 exploratory windows are now strict green and must keep
# their exact architectural fields visible in the coordinator progress log.
run_case base stxr_same_success t055-stxr_same_success 40 \
  'pc=0x44000070 next=0x44010280 exc=1 mon_we=1 mon_v=0'
run_case delay2 stxr_same_success t055-stxr_same_success 40 \
  'pc=0x44000070 next=0x44010280 exc=1 mon_we=1 mon_v=0'
run_case base stxr_same_fail t055-stxr_same_fail 38 \
  'pc=0x44000064 next=0x44010280 exc=1 mon_we=1 mon_v=0'
run_case delay2 stxr_same_fail t055-stxr_same_fail 38 \
  'pc=0x44000064 next=0x44010280 exc=1 mon_we=1 mon_v=0'

# Synchronous STXR DABT must not update monitor; existing IABT/fetch-merge and
# ordinary IRQ/WFI paths remain explicit regressions in the same protocol.
run_case base stxr_sync_dabt t055-stxr_sync_dabt 55 \
  'pc=0x44000044 next=0x44010200 exc=1 mon_we=0 mon_v=0'
run_case base hard_iabt t055-hard_iabt 25 \
  'pc=0x44000ffc next=0x44010200 exc=1 mon_we=0 mon_v=0'

if [[ "$RUN_REGRESSIONS" == 1 ]]; then
  # The coordinator intentionally does not print ASYNC progress records.  Use
  # an independent protocol peer to prove that the WFI wake-up packet itself
  # has exc_code=0x40 but mon_we/store_count both zero.
  SOCK="$RUN_ROOT/wfi-async.sock" QEMU_LOG="$RUN_ROOT/wfi-async.qemu" \
    MAX_COMMITS=35 systemd-run --user --scope -p MemoryMax=16G -p MemorySwapMax=0 -- \
    env PYTHONPATH="$REPO" bash "$REPO/sim/difftest/run_stxr_irq_mon_we_probe.sh" \
      "$REPO/build/difftest/t055-hard_wfi_timer_irq.bin" "$QEMU_BIN" "$PLUGIN"
  run_case delay2 hard_wfi_timer_irq t055-hard_wfi_timer_irq 45 ""

  for spec in \
    'hard_irq:30' 'hard_irq_daif:45' 'hard_wfi_timer_irq:45' \
    'hard_exclusive:70' 'hard_lse:100' 'hard_lse128:120' 'hard_esr_far:25'; do
    name="${spec%%:*}"
    max_insns="${spec##*:}"
    run_case base "$name" "t055-$name" "$max_insns" ""
  done
fi

# T-054's ordinary CASP/STXR/DC ZVA base/delay2 matrix is the companion
# architectural-boundary regression.  Run its strict socket path directly so
# this task remains independent of the older text probe's pre-560B ABI parser;
# the coordinator still compares all available memory tuples.  Keep it opt-out
# only for local triage; normal CI/acceptance always executes it.
if [[ "$RUN_T054" == 1 ]]; then
  for phase in base delay2; do
    run_case "$phase" t054_casp_match t055-t054_casp_match 55 \
      'pc=0x44000078 next=0x44010280 exc=1 mon_we=0 mon_v=0'
    run_case "$phase" t054_casp_mismatch t055-t054_casp_mismatch 55 \
      'pc=0x44000080 next=0x44010280 exc=1 mon_we=0 mon_v=0'
    run_case "$phase" t054_stxr_success t055-t054_stxr_success 55 \
      'pc=0x44000070 next=0x44000074 exc=0 mon_we=1 mon_v=0'
    run_case "$phase" t054_stxr_fail t055-t054_stxr_fail 55 \
      'pc=0x44000064 next=0x44000068 exc=0 mon_we=1 mon_v=0'
    run_case "$phase" t054_dc_zva t055-t054_dc_zva 65 \
      'pc=0x44000060 next=0x44010280 exc=1 mon_we=0 mon_v=0'
    if ! rg -q -- 'pc=0x44000074 next=0x44010280 exc=1 mon_we=0 mon_v=0' \
        "$RUN_ROOT/${phase}-t054_stxr_success.coord"; then
      echo "T055 QEMU FAIL case=t054_stxr_success phase=$phase: IRQ packet missing" >&2
      exit 1
    fi
    if ! rg -q -- 'pc=0x4400006c next=0x44010280 exc=1 mon_we=0 mon_v=0' \
        "$RUN_ROOT/${phase}-t054_stxr_fail.coord"; then
      echo "T055 QEMU FAIL case=t054_stxr_fail phase=$phase: IRQ packet missing" >&2
      exit 1
    fi
  done
fi

echo "PASS: T-055 STXR same-COMMIT IRQ monitor sidecar + protocol regressions"
