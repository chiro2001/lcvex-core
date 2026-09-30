#!/usr/bin/env bash
# P5a-Hardening（M0）定向测试：NZCV 位域 / MOV wide 保留编码 / ADD·SUB imm
# shift / B.cond 保留条件 / MMU AP 全矩阵 / AF=0 / 取指 UXN·PXN /
# TTBR gap / PA 越界。
#
# 用法：bash sim/difftest/run_p5a_hardening.sh [--only name1,name2] [--parallel]
#   --only：只跑指定测试（按镜像名精确匹配，逗号分隔）。
#   --parallel：用 scripts/run_lockstep_parallel.sh 并行（planner 绑核）。
#
# 阶段语义：feature/p5a-arch-fixes 修复前，本脚本预期 5 项全部 FAIL（RED），
# 证明测试能暴露评估 R0.1~R0.4 的架构错误；修复后同一脚本应全部 PASS（GREEN）。
set -uo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO"
mkdir -p "$REPO/build/difftest"

ONLY="${ONLY:-}"
PARALLEL="${PARALLEL:-0}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --only) ONLY="${2:-}"; shift 2 ;;
    --parallel) PARALLEL=1; shift ;;
    *) echo "未知参数：$1" >&2; exit 2 ;;
  esac
done

make -C qemu/plugins
make lockstep-build

python3 - <<'EOF'
import sys
sys.path.insert(0, "sim/difftest")
import test_program
for name, fn in [
    ("hard_nzcv", "build_hard_nzcv_program"),
    ("hard_movwide", "build_hard_movwide_program"),
    ("hard_addsub_shift", "build_hard_addsub_shift_program"),
    ("hard_bcond_f", "build_hard_bcond_f_program"),
    ("hard_ap_matrix", "build_hard_ap_matrix_program"),
    ("hard_af", "build_hard_af_program"),
    ("hard_uxn_pxn", "build_hard_uxn_pxn_program"),
    ("hard_ttbr_gap", "build_hard_ttbr_gap_program"),
    ("hard_pa_oob", "build_hard_pa_oob_program"),
    ("hard_barrier", "build_hard_barrier_program"),
    ("hard_selfmod", "build_hard_selfmod_program"),
    ("hard_tlbi", "build_hard_tlbi_program"),
    ("hard_mair_bypass", "build_hard_mair_bypass_program"),
    ("hard_block_desc", "build_hard_block_desc_program"),
    ("hard_sys_fetch_fault", "build_hard_sys_fetch_fault_program"),
    ("hard_msr_mmu_on", "build_hard_msr_mmu_on_program"),
    ("hard_esr_far", "build_hard_esr_far_program"),
    ("hard_compiler_isa", "build_hard_compiler_isa_program"),
    ("hard_pair_ldst", "build_hard_pair_ldst_program"),
    ("hard_reg_offset", "build_hard_reg_offset_program"),
    ("hard_ext_addsub", "build_hard_ext_addsub_program"),
    ("hard_madd", "build_hard_madd_program"),
    ("hard_csel", "build_hard_csel_program"),
    ("hard_bfm", "build_hard_bfm_program"),
    ("hard_insn_gaps", "build_hard_insn_gaps_program"),
    ("hard_ldr_literal", "build_hard_ldr_literal_program"),
]:
    getattr(test_program, fn)(f"build/difftest/{name}.bin")
    print(f"{name}.bin 生成完成")
EOF

declare -A INSNS=(
  [hard_nzcv]=14
  [hard_movwide]=8
  [hard_addsub_shift]=8
  [hard_bcond_f]=8
  [hard_ap_matrix]=70
  [hard_af]=30
  [hard_uxn_pxn]=80
  [hard_ttbr_gap]=20
  [hard_pa_oob]=20
  [hard_barrier]=40
  [hard_selfmod]=45
  [hard_tlbi]=60
  [hard_mair_bypass]=60
  [hard_block_desc]=45
  [hard_sys_fetch_fault]=25
  [hard_msr_mmu_on]=30
  [hard_esr_far]=25
  [hard_compiler_isa]=20
  [hard_pair_ldst]=30
  [hard_reg_offset]=45
  [hard_ext_addsub]=25
  [hard_madd]=40
  [hard_csel]=55
  [hard_bfm]=25
  [hard_insn_gaps]=40
  [hard_ldr_literal]=10
)

fails=0
if [[ $PARALLEL -eq 1 ]]; then
  SPECS=""
  for name in hard_nzcv hard_movwide hard_addsub_shift hard_bcond_f \
              hard_ap_matrix hard_af hard_uxn_pxn hard_ttbr_gap hard_pa_oob \
              hard_barrier hard_selfmod hard_tlbi hard_mair_bypass \
              hard_block_desc hard_sys_fetch_fault hard_msr_mmu_on \
              hard_esr_far hard_compiler_isa hard_pair_ldst \
              hard_reg_offset hard_ext_addsub hard_madd hard_csel \
              hard_bfm hard_insn_gaps hard_ldr_literal; do
    if [[ -n "$ONLY" ]]; then
      matched=0
      old_ifs=$IFS
      IFS=,
      for tok in $ONLY; do
        if [[ "$tok" == "$name" ]]; then
          matched=1
          break
        fi
      done
      IFS=$old_ifs
      [[ $matched -eq 0 ]] && continue
    fi
    SPECS+="$name:build/difftest/$name.bin:${INSNS[$name]}:build/verilator_lockstep/lockstep_coordinator "
  done
  SPECS="$SPECS" bash scripts/run_lockstep_parallel.sh --wait
  exit $?
fi

for name in hard_nzcv hard_movwide hard_addsub_shift hard_bcond_f \
            hard_ap_matrix hard_af hard_uxn_pxn hard_ttbr_gap hard_pa_oob \
            hard_barrier hard_selfmod hard_tlbi hard_mair_bypass \
            hard_block_desc hard_sys_fetch_fault hard_msr_mmu_on \
            hard_esr_far hard_compiler_isa hard_pair_ldst \
            hard_reg_offset hard_ext_addsub hard_madd hard_csel \
            hard_bfm hard_insn_gaps hard_ldr_literal; do
  if [[ -n "$ONLY" ]]; then
    matched=0
    old_ifs=$IFS
    IFS=,
    for tok in $ONLY; do
      if [[ "$tok" == "$name" ]]; then
        matched=1
        break
      fi
    done
    IFS=$old_ifs
    [[ $matched -eq 0 ]] && continue
  fi
  echo "===== $name ====="
  if IMAGE="$REPO/build/difftest/$name.bin" MAX_INSNS="${INSNS[$name]}" \
      bash sim/difftest/run_lockstep_step.sh; then
    echo "OK(green): $name"
  else
    echo "FAIL(red-expected): $name"
    fails=$((fails + 1))
  fi
done

if [[ $fails -eq 0 ]]; then
  echo "PASS: P5a-Hardening + M2/R1 定向测试全部与 QEMU 一致"
  exit 0
else
  echo "RED: $fails/26 个定向测试失败"
  exit 1
fi
