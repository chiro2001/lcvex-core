#!/usr/bin/env bash
# 锁步测试并行 runner：资源感知规划 + 物理核绑定 + per-test 独立路径。
#
# 每个测试规格：name:image:max_insns:coord（image/coord 相对仓库根目录）。
# 并行度与 CPU 列表来自 scripts/test_planner.sh（本地 50% / CI 75%）。
#
# 用法：
#   SPECS="hard_csel:build/difftest/hard_csel.bin:55:build/verilator_lockstep/lockstep_coordinator \
#          hard_madd:build/difftest/hard_madd.bin:40:build/verilator_lockstep/lockstep_coordinator"
#   bash scripts/run_lockstep_parallel.sh [--ci] [--wait] [--max-parallel N]
#   若 main/lite 长跑已占用槽位，可加 --reserve-slots=2，避免负载平均值
#   尚未更新时把短测试调度到它们的物理核。
#
# 退出码：全部 PASS=0，任一 FAIL=1。日志在 build/difftest/par/<name>/。
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO"

CI=0
WAIT=0
MAX_P=""
RESERVE_SLOTS=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --ci) CI=1; shift ;;
    --wait) WAIT=1; shift ;;
    --max-parallel) MAX_P="${2:-}"; shift 2 ;;
    --reserve-slots) RESERVE_SLOTS="${2:-}"; shift 2 ;;
    --reserve-slots=*) RESERVE_SLOTS="${1#*=}"; shift ;;
    *) echo "未知参数：$1" >&2; exit 2 ;;
  esac
done

if [[ -z "${SPECS:-}" ]]; then
  echo "错误：未提供 SPECS（name:image:max:coord 空格分隔）" >&2
  exit 2
fi

# 资源决策：--ci 时 75%，否则 50%；--wait 时排队等待资源
PLAN_ARGS=()
[[ $CI -eq 1 ]] && PLAN_ARGS+=(--ci)
[[ $WAIT -eq 1 ]] && PLAN_ARGS+=(--wait)
PLAN_ARGS+=(--reserve-slots="$RESERVE_SLOTS")
PLAN="$(bash scripts/test_planner.sh "${PLAN_ARGS[@]}")"
PARALLEL="$(python3 -c "import json,sys; print(json.load(sys.stdin)['parallel'])" <<<"$PLAN")"
CPUS="$(python3 -c "import json,sys; print(' '.join(map(str, json.load(sys.stdin)['cpus'])))" <<<"$PLAN")"
if [[ -n "$MAX_P" ]] && (( MAX_P < PARALLEL )); then
  PARALLEL="$MAX_P"
fi
echo "==> planner: parallel=$PARALLEL cpus=[$CPUS]"

read -r -a CPU_LIST <<<"$CPUS"
if (( PARALLEL < 1 || ${#CPU_LIST[@]} < 1 )); then
  echo "资源不足：planner 未提供可用并行槽位（parallel=$PARALLEL cpus=[$CPUS]）；"
  echo "请使用 --wait 排队，或稍后重试。" >&2
  exit 75
fi
if (( PARALLEL > ${#CPU_LIST[@]} )); then
  PARALLEL="${#CPU_LIST[@]}"
fi
PAR_DIR="$REPO/build/difftest/par"
mkdir -p "$PAR_DIR"

fails=0
launch() {
  local spec=$1 cpu=$2
  local name image max coord
  IFS=: read -r name image max coord <<<"$spec"
  local dir="$PAR_DIR/$name"
  mkdir -p "$dir"
  if [[ ! -f "$REPO/$image" ]]; then
    echo "FAIL: $name 镜像不存在 $REPO/$image" >"$dir/result"
    return 1
  fi
  if [[ ! -f "$REPO/$coord" ]]; then
    echo "FAIL: $name 协调器不存在 $REPO/$coord" >"$dir/result"
    return 1
  fi
  (
    cd "$REPO"
    taskset -c "$cpu" env \
      IMAGE="$REPO/$image" MAX_INSNS="$max" COORD="$REPO/$coord" \
      SOCK="$dir/step.sock" DUMP="$dir/fail.txt" \
      COORD_LOG="$dir/coord.log" QEMU_LOG="$dir/qemu.log" \
      bash sim/difftest/run_lockstep_step.sh \
        >"$dir/run.log" 2>&1
    echo "rc=$?" >"$dir/result"
  ) &
}

read -r -a SPEC_ARR <<<"$SPECS"
pids=()
i=0
for spec in "${SPEC_ARR[@]}"; do
  cpu="${CPU_LIST[$((i % ${#CPU_LIST[@]}))]}"
  while ((${#pids[@]} >= PARALLEL)); do
    wait -n 2>/dev/null || true
    new_pids=()
    for p in "${pids[@]}"; do
      if kill -0 "$p" 2>/dev/null; then new_pids+=("$p"); fi
    done
    pids=("${new_pids[@]}")
  done
  launch "$spec" "$cpu" || continue
  pids+=("$!")
  i=$((i + 1))
done
for p in "${pids[@]}"; do
  wait "$p" 2>/dev/null
done

echo "===== 并行锁步汇总 ====="
for spec in "${SPEC_ARR[@]}"; do
  name="${spec%%:*}"
  result_file="$PAR_DIR/$name/result"
  if [[ -f "$result_file" ]] && grep -q "^rc=0$" "$result_file"; then
    echo "OK(green): $name"
  else
    echo "FAIL(red-expected): $name（日志 $PAR_DIR/$name/run.log）"
    fails=$((fails + 1))
  fi
done

if [[ $fails -eq 0 ]]; then
  echo "PASS: ${#SPEC_ARR[@]} 项并行锁步全部通过"
  exit 0
else
  echo "RED: $fails/${#SPEC_ARR[@]} 项失败"
  exit 1
fi
