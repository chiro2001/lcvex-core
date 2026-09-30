#!/usr/bin/env bash
# M2-4b 定向测试：缓存/TLB 维护指令（IC IVAU / IC IALLU / DC * / TLBI）。
#
# 用法：bash sim/difftest/run_m2_4b.sh [--only name1,name2] [--parallel]
#   --only：只跑指定测试（按镜像名或 step 名精确匹配，逗号分隔）。
#   --parallel：base/cache 两阶段各自用并行 runner（planner 绑核）。
#
# 分两级验证：
#   1. 基础锁步构建（无缓存）：hard_barrier / hard_selfmod（含 IC IVAU）/
#      hard_tlbi 全部与 QEMU 一致；
#   2. 全缓存锁步构建（I+D+L2）：hard_selfmod 转绿 = M2-4b 完成判据
#      （store 经 D-L1->L2->SRAM 更新，IC IVAU 失效 I-L1 陈旧行）；
#      hard_tlbi / hard_barrier 同样一致。
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

python3 - <<'EOF'
import sys
sys.path.insert(0, "sim/difftest")
import test_program
for name, fn in [
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
    ("hard_exclusive", "build_hard_exclusive_program"),
    ("hard_p6_isa", "build_hard_p6_isa_program"),
    ("hard_big_mem", "build_hard_big_mem_program"),
    ("hard_uart", "build_hard_uart_program"),
    ("hard_pl031", "build_hard_pl031_program"),
    ("hard_crc32", "build_hard_crc32_program"),
    ("hard_pl061", "build_hard_pl061_program"),
    ("hard_timer", "build_hard_timer_program"),
    ("hard_gic", "build_hard_gic_program"),
    ("hard_irq", "build_hard_irq_program"),
    ("hard_irq_daif", "build_hard_irq_daif_program"),
    ("hard_ldur", "build_hard_ldur_program"),
    ("hard_postpre", "build_hard_postpre_program"),
    ("hard_ttbr1", "build_hard_ttbr1_program"),
    ("hard_psci", "build_hard_psci_program"),
    ("hard_dit", "build_hard_dit_program"),
    ("hard_varshift", "build_hard_varshift_program"),
    ("hard_ldtr_sttr", "build_hard_ldtr_sttr_program"),
    ("hard_adc_sbc", "build_hard_adc_sbc_program"),
    ("hard_allint", "build_hard_allint_program"),
    ("hard_sctlr_pauth", "build_hard_sctlr_pauth_program"),
    ("hard_id_sysreg", "build_hard_id_sysreg_program"),
    ("hard_sve_probe", "build_hard_sve_probe_program"),
]:
    getattr(test_program, fn)(f"build/difftest/{name}.bin")
    print(f"{name}.bin 生成完成")
EOF

fails=0
run_one() {
  local coord=$1 image=$2 max=$3 name=$4
  if [[ -n "$ONLY" ]]; then
    local matched=0 tok
    local IFS=,
    for tok in $ONLY; do
      if [[ "$tok" == "$image" || "$tok" == "$name" ]]; then
        matched=1
        break
      fi
    done
    [[ $matched -eq 0 ]] && return 0
  fi
  echo "===== $name ($(basename "$(dirname "$coord")")) ====="
  if IMAGE="$REPO/build/difftest/$image.bin" MAX_INSNS="$max" \
      COORD="$coord" bash sim/difftest/run_lockstep_step.sh; then
    echo "OK(green): $name"
  else
    echo "FAIL(red-expected): $name"
    fails=$((fails + 1))
  fi
}

# 17 组测试（name:max_insns），base/cache 两配置共用
M2_TESTS=(hard_barrier:45 hard_selfmod:45 hard_tlbi:60 hard_mair_bypass:60
          hard_block_desc:45 hard_sys_fetch_fault:25 hard_msr_mmu_on:30
          hard_esr_far:25 hard_compiler_isa:20 hard_pair_ldst:35
          hard_reg_offset:45 hard_ext_addsub:25 hard_madd:43 hard_csel:55
          hard_bfm:25 hard_insn_gaps:40 hard_ldr_literal:10
          hard_exclusive:70 hard_p6_isa:114 hard_big_mem:6 hard_uart:62 hard_pl031:24 hard_crc32:20 hard_pl061:20
          hard_timer:40 hard_gic:52 hard_irq:30 hard_irq_daif:40 hard_ldur:45
          hard_postpre:70 hard_ttbr1:30 hard_psci:29 hard_id_sysreg:47
          hard_dit:32 hard_varshift:26 hard_ldtr_sttr:16
          hard_adc_sbc:30 hard_allint:20 hard_sctlr_pauth:8 hard_sve_probe:60)

run_phase() {
  local coord=$1 prefix=$2
  if [[ $PARALLEL -eq 1 ]]; then
    local SPECS="" spec name max
    for spec in "${M2_TESTS[@]}"; do
      name="${spec%%:*}"; max="${spec##*:}"
      if [[ -n "$ONLY" ]]; then
        local matched=0 tok
        local IFS=,
        for tok in $ONLY; do
          if [[ "$tok" == "$name" || "$tok" == "$prefix-$name" ]]; then
            matched=1
            break
          fi
        done
        [[ $matched -eq 0 ]] && continue
      fi
      SPECS+="$name:build/difftest/$name.bin:$max:$coord "
    done
    if [[ -n "$SPECS" ]]; then
      SPECS="$SPECS" bash scripts/run_lockstep_parallel.sh --wait || fails=$((fails + 1))
    fi
    return 0
  fi
  local spec name max
  for spec in "${M2_TESTS[@]}"; do
    name="${spec%%:*}"; max="${spec##*:}"
    run_one "$REPO/$coord" "$name" "$max" "$prefix-$name"
  done
}

make lockstep-build
run_phase "build/verilator_lockstep/lockstep_coordinator" base

# M2-4b 完成判据：全缓存配置下 hard_selfmod 转绿
make lockstep-build-l1dl2
run_phase "build/verilator_lockstep_l1dl2/lockstep_coordinator" cache

if [[ $fails -eq 0 ]]; then
  echo "PASS: M2/R1 定向测试全部与 QEMU 一致（含全缓存配置）"
  exit 0
else
  echo "RED: $fails/34 个 M2/R1 定向测试失败"
  exit 1
fi
