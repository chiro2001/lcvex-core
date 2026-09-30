#!/usr/bin/env bash
# PR-difftest 门禁：需要 QEMU fork + 插件，覆盖 RTL/QEMU 差分主路径。
# 覆盖：P1/P2 trace、P2 lockstep、hazard、P4c、P5a、P5a-Hardening、
#       P6 LSE、Q6、短随机 seed。
# 用法：scripts/ci-difftest.sh [--keep-logs]
#
# 前置安全：QEMU apply/build、plugin build 也走 run_step 日志；任一前置失败
# 立即以非零退出，避免在破损/陈旧产物上继续产生假绿。
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

CONDA_ENV="${CONDA_ENV:-lcvex}"
RUN() { conda run --no-capture-output -n "$CONDA_ENV" "$@"; }

LOG_DIR="${LOG_DIR:-build/ci-difftest}"
mkdir -p "$LOG_DIR"

# 重型 Verilator 统一串行（-j1）；外层必须先取得共享 local 锁，cgroup 上限可选。
export VERILATOR_JOBS=1

run_step() {
  local name="$1" cmd="$2"
  echo "===== [$name] $cmd ====="
  if eval "$cmd" >"$LOG_DIR/$name.log" 2>&1; then
    echo "PASS $name"
    return 0
  else
    echo "FAIL $name（日志 $LOG_DIR/$name.log）" >&2
    tail -25 "$LOG_DIR/$name.log" >&2
    return 1
  fi
}

preflight() {
  local name="$1" cmd="$2"
  if ! run_step "$name" "$cmd"; then
    echo "FAIL: 前置步骤 $name 失败，中止 PR-difftest（不使用陈旧产物）" >&2
    exit 1
  fi
}

# 清理/隔离可能掩盖真实失败或让后续步骤复用旧产物的文件。
# qemu/build 仍由上游 cache 管理；若 apply/build 失败，preflight 已立即退出。
rm -f qemu/plugins/lcvex_difftest.so
rm -f build/verilator_lockstep/lockstep_coordinator
rm -f build/verilator_lockstep_d1/lockstep_coordinator
rm -f build/verilator_lockstep_d2/lockstep_coordinator
rm -f build/verilator_lockstep_l1dl2_d2/lockstep_coordinator

preflight "qemu-apply" "bash qemu/scripts/apply-patches.sh"
preflight "qemu-build" "bash scripts/build-qemu.sh"
preflight "plugin-build" "make -C qemu/plugins"

steps=(
  "difftest-p1p2:make difftest"
  "lockstep-p2:make lockstep"
  "hazard:make difftest-hazard"
  "p4c:make p4c"
  "p5a:make p5a"
  "hardening:bash sim/difftest/run_p5a_hardening.sh"
  "p6-lse:make p6-lse"
  "p6-wfi:make p6-wfi"
  "q6:make q6"
  "random-short:make difftest-random SEED=7 LENGTH=20000"
)

fail=0
for entry in "${steps[@]}"; do
  name="${entry%%:*}"
  cmd="${entry#*:}"
  if ! run_step "$name" "$cmd"; then
    fail=1
  fi
done

if [[ $fail -eq 0 ]]; then
  echo "PASS: PR-difftest 门禁全部通过（日志 $LOG_DIR/）"
else
  echo "FAIL: PR-difftest 门禁有失败项" >&2
  exit 1
fi
