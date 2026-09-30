#!/usr/bin/env bash
# M2-5 Gate D 系统回归（验收脚本）。
#
# 用法：bash sim/difftest/run_gate_d.sh [--only name1,name2] [--parallel]
#   --only：只跑名字匹配的 step（子脚本 run_m2_4b/run_p5a_hardening 会
#   透传并做测试级筛选）；名字含“构建”的前置步骤总是执行。
#   --parallel：M2-4b、delay2、P5a-Hardening 三个锁步批次改用并行
#   runner（planner 并行度 + 物理核绑定），Gate C/P5a/P4b 保持串行。
#   --skip-baremetal：显式非发布/开发模式，baremetal-C 缺失时打印 SKIP，
#   不计入失败；默认发布模式必须执行 baremetal-C，缺失即 Gate D 失败。
#   --check-baremetal：只执行 baremetal-C 工具链/镜像检查，不运行其它
#   重型回归；用于隔离 PATH 下的快速负测。
#
# 退出条件（见 docs/PROJECT_STATUS.md Gate D）：
#   hit/miss/refill/evict、冲突替换、写穿副作用、I/D 失效、Device bypass、
#   TLB hit/miss/fault 与 maintenance 全部有单元与系统测试；可注入下级
#   延迟（含全缓存配置）；P0～P5a 全量回归通过；缓存内部事件有 SVA 与
#   覆盖率验证。
set -uo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO"
mkdir -p "$REPO/build/difftest"

ONLY=""
PARALLEL=0
SKIP_BAREMETAL=0
CHECK_BAREMETAL=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --only) ONLY="${2:-}"; shift 2 ;;
    --parallel) PARALLEL=1; shift ;;
    --skip-baremetal) SKIP_BAREMETAL=1; shift ;;
    --check-baremetal) CHECK_BAREMETAL=1; shift ;;
    *) echo "未知参数：$1" >&2; exit 2 ;;
  esac
done

# 快速负测/工具链前检：只运行 baremetal-C 工具链与镜像构建。
# 发布模式缺工具必须非零；这里不触碰任何 Verilator/重回归。
if [[ $CHECK_BAREMETAL -eq 1 ]]; then
  echo "########## baremetal-C 工具链/镜像（--check-baremetal） ##########"
  if bash scripts/build-baremetal.sh; then
    echo "OK: baremetal-C 工具链/镜像可用"
    exit 0
  else
    echo "FAIL: baremetal-C 工具链/镜像不可用（发布模式不得跳过）" >&2
    exit 1
  fi
fi

fails=0
step() {
  local name=$1
  shift
  if [[ -n "$ONLY" ]]; then
    local matched=0 tok
    local IFS=,
    for tok in $ONLY; do
      if [[ "$name" == *"$tok"* ]]; then
        matched=1
        break
      fi
    done
    if [[ $matched -eq 0 && "$name" != *"构建"* ]]; then
      echo "########## (skip) $name ##########"
      return 0
    fi
  fi
  echo "########## $name ##########"
  if "$@"; then
    echo "OK(green): $name"
  else
    echo "FAIL(red-expected): $name"
    fails=$((fails + 1))
  fi
}

step "make test（单元 + SVA）" make test
step "make coverage（缓存/MMU TB 覆盖率）" make coverage

step "M2-4b/4c 定向锁步（base + 全缓存）" \
  env ONLY="$ONLY" PARALLEL="$PARALLEL" \
  bash sim/difftest/run_m2_4b.sh

# 全缓存 + 随机下级延迟（0..4 周期 LFSR）系统回归
step "lockstep-build-l1dl2-delay2 构建" make lockstep-build-l1dl2-delay2
# 重新生成随机 smoke 镜像：保证用当前随机生成器（含 exclusive 对与
# 基址约束），避免陈旧二进制触发旧的“分支跳过基址 movz”序列。
step "随机 smoke 镜像重新生成" python3 -c "
import random, sys
sys.path.insert(0, 'sim/difftest')
import random_program, test_program
from a64 import assemble
rng = random.Random(1)
insns = random_program.with_loop(random_program.gen_program(rng, 3000))
test_program.build_program('build/difftest/random_smoke.bin',
                           assemble(insns, 0x44000000))
print('random_smoke.bin 重新生成完成')
"
DELAY2_TESTS=(hard_barrier:45 hard_selfmod:60 hard_tlbi:80 hard_mair_bypass:80 \
              hard_block_desc:60 hard_sys_fetch_fault:30 hard_msr_mmu_on:35 \
              hard_esr_far:30 hard_pair_ldst:40 hard_reg_offset:50 \
              hard_ext_addsub:30 hard_madd:45 hard_csel:60 hard_bfm:30 \
              hard_insn_gaps:45 hard_ldr_literal:15 hard_p6_isa:75 \
              hard_exclusive:55 hard_big_mem:6 hard_uart:62 hard_pl031:24 hard_crc32:20 hard_pl061:20 hard_timer:40 \
              hard_gic:52 hard_irq:30 hard_irq_daif:40 hard_ldur:45 hard_postpre:70
              hard_ttbr1:30 hard_allint:20)
if [[ $PARALLEL -eq 1 ]]; then
  D2_SPECS=""
  for t in "${DELAY2_TESTS[@]}"; do
    name="${t%%:*}"; max="${t##*:}"
    D2_SPECS+="$name:build/difftest/$name.bin:$max:build/verilator_lockstep_l1dl2_d2/lockstep_coordinator "
  done
  D2_SPECS+="random_smoke:build/difftest/random_smoke.bin:3000:build/verilator_lockstep_l1dl2_d2/lockstep_coordinator"
  step "delay2-cache-*（并行）" env SPECS="$D2_SPECS" \
    bash scripts/run_lockstep_parallel.sh --wait
else
  for t in "${DELAY2_TESTS[@]}"; do
    name="${t%%:*}"; max="${t##*:}"
    step "delay2-cache-$name" \
      env IMAGE="$REPO/build/difftest/$name.bin" MAX_INSNS="$max" \
          COORD="$REPO/build/verilator_lockstep_l1dl2_d2/lockstep_coordinator" \
          bash sim/difftest/run_lockstep_step.sh
  done
  step "delay2-cache-random-smoke" \
    env IMAGE="$REPO/build/difftest/random_smoke.bin" MAX_INSNS=3000 \
        COORD="$REPO/build/verilator_lockstep_l1dl2_d2/lockstep_coordinator" \
        bash sim/difftest/run_lockstep_step.sh
fi

step "P5a-Hardening + M2 定向（13 组）" \
  env ONLY="$ONLY" PARALLEL="$PARALLEL" \
  bash sim/difftest/run_p5a_hardening.sh
step "Gate C 异常/EL0-EL1（7 组）" bash sim/difftest/run_gate_c.sh
step "P5a MMU 数据翻译（3 组）" bash sim/difftest/run_p5a.sh
step "P4b 异常/系统指令" bash sim/difftest/run_p4b.sh

step "随机回归（seed 1~3 × 100k）" make difftest-random-multi
step "指令覆盖记账（random 1~3 trace ↔ ISA_SCOPE）" \
  python3 scripts/insn_coverage.py --expect random \
    build/difftest/random_1.trace \
    build/difftest/random_2.trace \
    build/difftest/random_3.trace

# M3：裸机 C。默认是发布模式：工具链/镜像缺失必须使 Gate D 非零失败；
# 仅 --skip-baremetal 表示显式非发布/开发模式，打印 SKIP 且不计失败。
if [[ $SKIP_BAREMETAL -eq 1 ]]; then
  echo "########## baremetal-C（显式跳过） ##########"
  echo "SKIP: baremetal-C（--skip-baremetal 非发布模式，不计入 Gate D 失败）"
else
  step "baremetal-C 工具链/镜像" bash scripts/build-baremetal.sh
  step "baremetal-C 锁步" \
    env IMAGE="$REPO/build/difftest/bm_c.bin" MAX_INSNS=200 \
        COORD="$REPO/build/verilator_lockstep/lockstep_coordinator" \
        bash sim/difftest/run_lockstep_step.sh
fi

if [[ $fails -eq 0 ]]; then
  echo "PASS: Gate D 系统回归全部通过"
  exit 0
else
  echo "RED: Gate D 有 $fails 项失败"
  exit 1
fi
