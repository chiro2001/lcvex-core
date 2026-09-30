#!/usr/bin/env bash
# T-054：真实 CASP/STXR/DC ZVA + Generic Timer IRQ 严格锁步。
#
# QEMU 只在完整指令边界产生 Generic Timer PPI IRQ；不把该入口冒充为
# 原子/维护微相位注入。真实微相位由 sim-sv-irq-atomic-overlap 覆盖。
# 本 runner 固定跑 base 与 MEM_DELAY_MODE=2 两条 coordinator，五个场景
# 各自独立生成镜像，保留最小失败现场和每个 case 的 strict log。
set -euo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
QEMU_BIN="${QEMU_BIN:-$REPO/../qemu/build/qemu-system-aarch64}"
if [[ -n "${PLUGIN-}" ]]; then
  PLUGIN="$PLUGIN"
elif [[ -f "$REPO/qemu/plugins/lcvex_difftest.so" ]]; then
  PLUGIN="$REPO/qemu/plugins/lcvex_difftest.so"
else
  # A direct sibling worktree reuses the integrator's read-only plugin until
  # QEMU paths are fully parameterized (the A0 workflow contract).
  PLUGIN="$REPO/../lcvex/qemu/plugins/lcvex_difftest.so"
fi
COORD_BASE="${COORD_BASE:-$REPO/build/verilator_lockstep/lockstep_coordinator}"
COORD_DELAY2="${COORD_DELAY2:-$REPO/build/verilator_lockstep_d2/lockstep_coordinator}"
PYTHON="${PYTHON:-python3}"
RUN_ROOT="${RUN_ROOT:-$REPO/build/tmp/t054q}"
MAX_INSNS_ATOMIC="${MAX_INSNS_ATOMIC:-55}"
MAX_INSNS_ZVA="${MAX_INSNS_ZVA:-65}"
PROBE_MAX_INSNS="${PROBE_MAX_INSNS:-180}"

for f in "$QEMU_BIN" "$PLUGIN" "$COORD_BASE" "$COORD_DELAY2"; do
  if [[ ! -f "$f" ]]; then
    echo "错误：找不到 $f" >&2
    exit 2
  fi
done

mkdir -p "$REPO/build/difftest" "$RUN_ROOT"

"$PYTHON" - <<'PY'
import sys
sys.path.insert(0, "sim/difftest")
import test_program

builders = {
    "casp_match": test_program.build_hard_irq_atomic_casp_match_program,
    "casp_mismatch": test_program.build_hard_irq_atomic_casp_mismatch_program,
    "stxr_success": test_program.build_hard_irq_atomic_stxr_success_program,
    "stxr_fail": test_program.build_hard_irq_atomic_stxr_fail_program,
    "dc_zva": test_program.build_hard_irq_atomic_dc_zva_program,
}
for name, builder in builders.items():
    path = f"build/difftest/t054-{name}.bin"
    base = builder(path)
    if base != 0x44000000:
        raise SystemExit(f"{name}: unexpected image base {base:#x}")
    print(f"generated {path}")
PY

probe_qemu_one() {
  local phase="$1" name="$2" prefix="$3"
  local op_pc="$4" op_insn="$5" op_stores="$6"
  local irq_pc="$7" irq_insn="$8" irq_stores="$9"
  local expected_store_list="${10}" post_load_list="${11}"
  local probe_log="${prefix}.probe.log"
  local probe_qemu_log="${prefix}.probe.qemu"
  local rc
  # Independent read-only protocol probe: strict coordinator progress omits
  # insn/store_count, so this parses actual QEMU COMMIT payloads and validates
  # the target/IRQ fields.  It never drives the DUT or replaces lockstep.
  set +e
  systemd-run --user --scope -p MemoryMax=16G -p MemorySwapMax=0 -- \
    env PYTHONPATH="$REPO" PYTHON="$PYTHON" \
      bash "$REPO/sim/difftest/run_irq_atomic_probe.sh" \
      "$REPO/build/difftest/t054-${name}.bin" "$QEMU_BIN" "$PLUGIN" \
      "${prefix}.probe.sock" "$probe_qemu_log" \
      "$op_pc" "$op_insn" "$op_stores" "$irq_pc" "$irq_insn" \
      "$irq_stores" "$expected_store_list" "$post_load_list" \
      "$PROBE_MAX_INSNS" >"$probe_log" 2>&1
  rc=$?
  set -e
  if [[ "$rc" -ne 0 ]]; then
    echo "T054 QEMU PROBE FAIL case=$name phase=$phase rc=$rc log=$probe_log" >&2
  fi
  return "$rc"
}

trace_qemu_one() {
  local phase="$1" name="$2" prefix="$3"
  local op_pc="$4" op_insn="$5" op_stores="$6"
  local expected_store_list="${7}" post_load_list="${8}"
  local trace_log="${prefix}.trace.log"
  local trace_path="${prefix}.trace.gz"
  local rc
  # Non-lockstep QEMU trace captures MEM_W tuples.  This supplements the
  # strict step run because the current step callback protocol cannot expose
  # stores while the PRE/GO socket is synchronously blocked.
  set +e
  systemd-run --user --scope -p MemoryMax=16G -p MemorySwapMax=0 -- \
    env PYTHONPATH="$REPO" PYTHON="$PYTHON" \
      bash "$REPO/sim/difftest/run_irq_atomic_trace.sh" \
      "$REPO/build/difftest/t054-${name}.bin" "$QEMU_BIN" "$PLUGIN" \
      "$trace_path" "$op_pc" "$op_insn" "$op_stores" \
      "$expected_store_list" "$post_load_list" >"$trace_log" 2>&1
  rc=$?
  set -e
  if [[ "$rc" -ne 0 ]]; then
    echo "T054 QEMU TRACE FAIL case=$name phase=$phase rc=$rc log=$trace_log" >&2
  fi
  return "$rc"
}

run_one() {
  local phase="$1" coord="$2" name="$3" max_insns="$4" spec="$5"
  local op_pc op_insn op_stores irq_pc irq_insn irq_stores
  local expected_store_list post_load_list
  IFS=: read -r op_pc op_insn op_stores irq_pc irq_insn irq_stores \
    expected_store_list post_load_list <<<"$spec"
  local prefix="$RUN_ROOT/${phase}-${name}"
  local log="${prefix}.log"
  local rc
  echo "T054 QEMU case=$name phase=$phase coord=$coord"
  set +e
  systemd-run --user --scope -p MemoryMax=16G -p MemorySwapMax=0 -- \
    env IMAGE="$REPO/build/difftest/t054-${name}.bin" \
      MAX_INSNS="$max_insns" COORD="$coord" QEMU_BIN="$QEMU_BIN" \
      PLUGIN="$PLUGIN" SOCK="${prefix}.sock" DUMP="${prefix}.fail" \
      COORD_LOG="${prefix}.coord" QEMU_LOG="${prefix}.qemu" \
      bash "$REPO/sim/difftest/run_lockstep_step.sh" >"$log" 2>&1
  rc=$?
  set -e
  if [[ "$rc" -eq 0 ]]; then
    local irq_pc_hex
    irq_pc_hex="$(printf '0x%x' "$irq_pc")"
    if ! rg -q "pc=${irq_pc_hex} .*exc=1" "${prefix}.coord"; then
      echo "T054 QEMU FAIL case=$name phase=$phase: coordinator IRQ PC/exc assertion failed" >&2
      return 1
    fi
    probe_qemu_one "$phase" "$name" "$prefix" "$op_pc" "$op_insn" \
      "$op_stores" "$irq_pc" "$irq_insn" "$irq_stores" \
      "$expected_store_list" "$post_load_list" || return 1
    trace_qemu_one "$phase" "$name" "$prefix" "$op_pc" "$op_insn" \
      "$op_stores" "$expected_store_list" "$post_load_list" || return 1
    echo "T054 QEMU PASS case=$name phase=$phase irq_pc=$irq_pc_hex log=$log"
  else
    echo "T054 QEMU FAIL case=$name phase=$phase rc=$rc log=$log" >&2
  fi
  return "$rc"
}

status=0
# CASP match retires its two accepted stores in the same IRQ COMMIT; the probe
# parses the corrected 560B wire ABI and therefore expects both.
for case_spec in \
  casp_match:0x44000078:0x4860fe82:2:0x44000078:0x4860fe82:2:44082000/33/ff,44082008/44/ff: \
  casp_mismatch:0x44000080:0x48207e82:0:0x44000080:0x48207e82:0:: \
  stxr_success:0x44000070:0x88077e86:1:0x44000074:0x14000001:0:44083000/aa/f: \
  stxr_fail:0x44000064:0x88077e86:0:0x4400006c:0x14000000:0:: \
  dc_zva:0x44000060:0xd50b7429:0:0x44000060:0xd50b7429:0::44000064/10,44000068/11,4400006c/12,44000070/13,44000074/14,44000078/15,4400007c/16,44000080/17; do
  name="${case_spec%%:*}"
  spec="${case_spec#*:}"
  max="$MAX_INSNS_ATOMIC"
  [[ "$name" == "dc_zva" ]] && max="$MAX_INSNS_ZVA"
  run_one base "$COORD_BASE" "$name" "$max" "$spec" || status=1
  run_one delay2 "$COORD_DELAY2" "$name" "$max" "$spec" || status=1
done

if [[ "$status" -ne 0 ]]; then
  echo "FAIL: T054 QEMU base/delay2 strict matrix" >&2
  exit "$status"
fi
echo "PASS: T054 QEMU Generic Timer IRQ strict base/delay2 matrix"
