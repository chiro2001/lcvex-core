#!/usr/bin/env bash
# LCVEX 测试资源规划器。
#
# 在并行测试（microbench 多镜像、锁步 runner、多配置构建）前调用：
#   1. 读取系统负载（loadavg 1 分钟，按“已占用核数”估计）与可用内存；
#   2. 按“最多占用系统比例”计算可用 CPU 槽位与内存预算；
#   3. 枚举可绑定的物理核（超线程去重）并输出建议并行度 parallel
#      与核列表 cpus（JSON），exit 0 = 可运行，1 = 资源不足。
#   --wait：资源不足时排队（按间隔重试直到可用或超时），供测试运行器
#   后台批次排队使用。
#   --reserve-slots=N：为已启动的长跑保留 N 个单核槽位；用于 main/lite
#   异步运行时避免 loadavg 尚未更新造成短测试抢占其物理核。
#
# 运行器应用 taskset -c <cpus> 绑定物理核运行，避免与其他负载混抢；
# 资源上限：本地默认 50%，CI（--ci）最多 75%。

set -uo pipefail

MODE=local
RATIO=0.50
MIN_MEM_MB=2048          # 最低可用内存门槛（不足则拒绝运行）
MEM_PER_SLOT_MB=512      # 每个并发测试单元的估算内存（Verilator 模型等）
WAIT=0
WAIT_TIMEOUT=600         # 排队最长等待秒数
RETRY_INTERVAL=30        # 排队重试间隔秒数
RESERVE_SLOTS=0          # 已由其它长跑占用、但尚未反映到 loadavg 的槽位

for a in "$@"; do
  case "$a" in
    --ci)       MODE=ci; RATIO=0.75 ;;
    --local)    MODE=local; RATIO=0.50 ;;
    --min-mem-mb=*)      MIN_MEM_MB="${a#*=}" ;;
    --mem-per-slot-mb=*) MEM_PER_SLOT_MB="${a#*=}" ;;
    --wait)              WAIT=1 ;;
    --wait-timeout=*)    WAIT_TIMEOUT="${a#*=}" ;;
    --retry-interval=*)  RETRY_INTERVAL="${a#*=}" ;;
    --reserve-slots=*)   RESERVE_SLOTS="${a#*=}" ;;
    *) echo "未知参数: $a" >&2; exit 2 ;;
  esac
done

# 展开 "0-3,5" 形式的核列表
expand_list() {
  local list="$1" p lo hi c
  IFS=',' read -ra parts <<< "$list"
  for p in "${parts[@]}"; do
    if [[ "$p" == *-* ]]; then
      lo="${p%-*}"; hi="${p#*-}"
      for ((c = lo; c <= hi; c++)); do echo "$c"; done
    else
      echo "$p"
    fi
  done
}

detect() {
  NPROC="$(nproc 2>/dev/null || echo 1)"
  LOAD1="$(awk '{print $1}' /proc/loadavg 2>/dev/null || echo 0)"

  # 当前进程允许的 CPU affinity（默认全部逻辑核）
  AFFINITY="$(taskset -pc $$ 2>/dev/null | sed -E 's/.*[：:][[:space:]]*//' | head -1)"
  if [[ -z "$AFFINITY" ]]; then
    AFFINITY="$(awk '/Cpus_allowed_list/{print $3}' /proc/self/status)"
  fi

  # 物理核去重：每个 (SOCKET,CORE) 只取第一个逻辑 CPU；无 lscpu 时回退
  # 到 affinity 列表
  PHYS_CPUS=()
  if command -v lscpu >/dev/null 2>&1 && [[ -n "$AFFINITY" ]]; then
    mapfile -t ALLOWED < <(expand_list "$AFFINITY")
    while IFS= read -r c; do
      PHYS_CPUS+=("$c")
    done < <(lscpu -e=CPU,SOCKET,CORE 2>/dev/null | tail -n +2 |
             awk -v ok="$(printf '%s\n' "${ALLOWED[@]}" | sort -n | tr '\n' ' ')" '
               BEGIN { split(ok, a, " "); for (i in a) allowed[a[i]] = 1 }
               !seen[$2 "," $3]++ && allowed[$1] { print $1 }')
  else
    mapfile -t PHYS_CPUS < <(expand_list "$AFFINITY")
  fi

  if [[ -r /proc/meminfo ]]; then
    MEM_TOTAL_MB="$(awk '/MemTotal:/{print int($2/1024)}' /proc/meminfo)"
    MEM_AVAIL_MB="$(awk '/MemAvailable:/{print int($2/1024)}' /proc/meminfo)"
  else
    MEM_TOTAL_MB=0
    MEM_AVAIL_MB=0
  fi

  # 已有 lcvex 测试进程检测（提示用，不算失败）
  LCVEX_RUNNING="$(pgrep -f 'run_gate_d|lockstep_coordinator|microbench_runner|qemu-system-aarch64' | wc -l)"

  # 计算：loadavg 1 分钟 ≈ 已占用核数；槽位 = nproc × 比例
  CPU_SLOTS="$(awk -v n="$NPROC" -v r="$RATIO" 'BEGIN{printf "%d", n*r}')"
  [[ "$CPU_SLOTS" -lt 1 ]] && CPU_SLOTS=1
  CPU_FREE="$(awk -v s="$CPU_SLOTS" -v l="$LOAD1" -v r="$RESERVE_SLOTS" \
              'BEGIN{f=s-l-r; if (f<0) f=0; printf "%d", f}')"
  MEM_BUDGET_MB="$(awk -v m="$MEM_AVAIL_MB" -v r="$RATIO" 'BEGIN{printf "%d", m*r}')"
  PARALLEL="$(awk -v c="$CPU_FREE" -v b="$MEM_BUDGET_MB" -v s="$MEM_PER_SLOT_MB" \
              'BEGIN{p=c; if (s>0 && b/s < p) p=int(b/s); if (p<0) p=0; printf "%d", p}')"

  # 取前 PARALLEL 个物理核作为建议绑定列表
  CPUS=()
  for ((i = 0; i < PARALLEL && i < ${#PHYS_CPUS[@]}; i++)); do
    CPUS+=("${PHYS_CPUS[$i]}")
  done
  CPUS_JSON="[$(IFS=,; echo "${CPUS[*]}")]"

  OK=1
  REASON="ok"
  if [[ "$PARALLEL" -lt 1 ]]; then
    OK=0
    REASON="cpu/内存不足：cpu_free=${CPU_FREE} mem_budget=${MEM_BUDGET_MB}MB"
  elif [[ "$MEM_BUDGET_MB" -lt "$MIN_MEM_MB" ]]; then
    OK=0
    REASON="可用内存预算 ${MEM_BUDGET_MB}MB < 门槛 ${MIN_MEM_MB}MB"
  fi
}

detect

if [[ "$WAIT" -eq 1 && "$OK" -eq 0 ]]; then
  DEADLINE=$((SECONDS + WAIT_TIMEOUT))
  while [[ "$OK" -eq 0 && "$SECONDS" -lt "$DEADLINE" ]]; do
    echo "[test_planner] 资源不足（$REASON），${RETRY_INTERVAL}s 后重试..." >&2
    sleep "$RETRY_INTERVAL"
    detect
  done
  if [[ "$OK" -eq 0 ]]; then
    echo "[test_planner] 排队超时（${WAIT_TIMEOUT}s）：$REASON" >&2
  fi
fi

cat <<EOF
{
  "mode": "$MODE",
  "ratio": $RATIO,
  "nproc": $NPROC,
  "loadavg_1m": $LOAD1,
  "mem_total_mb": $MEM_TOTAL_MB,
  "mem_avail_mb": $MEM_AVAIL_MB,
  "cpu_slots": $CPU_SLOTS,
  "reserved_slots": $RESERVE_SLOTS,
  "cpu_free": $CPU_FREE,
  "mem_budget_mb": $MEM_BUDGET_MB,
  "mem_per_slot_mb": $MEM_PER_SLOT_MB,
  "parallel": $PARALLEL,
  "cpus": $CPUS_JSON,
  "lcvex_running": $LCVEX_RUNNING,
  "ok": $OK,
  "reason": "$REASON"
}
EOF

[[ "$OK" -eq 1 ]] && exit 0 || exit 1
