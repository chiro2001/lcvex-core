#!/usr/bin/env bash
# nightly 门禁：长时间回归 + 延迟注入 + 干净 QEMU patch 重放。
# 覆盖：5 个固定 seed x 100k、随机内存延迟锁步（MEM_DELAY_MODE=2）、
#       干净 release 上补丁重放。
# 用法：scripts/ci-nightly.sh [--keep-logs]
#
# 前置安全：QEMU apply、plugin、lockstep/delay2 构建和镜像生成都走 run_step；
# 任一前置失败立即非零退出，避免用陈旧 binary/image 继续产生假绿。
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

LOG_DIR="${LOG_DIR:-build/ci-nightly}"
TMP_ROOT="${LCVEX_TMP_DIR:-$REPO_ROOT/build/tmp}"
mkdir -p "$LOG_DIR"
mkdir -p "$TMP_ROOT"
mkdir -p "$REPO_ROOT/build/difftest"

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
    echo "FAIL: 前置步骤 $name 失败，中止 nightly（不使用陈旧产物）" >&2
    exit 1
  fi
}

# 清理/隔离会掩盖失败的旧插件、锁步协调器和延时镜像。
rm -f qemu/plugins/lcvex_difftest.so
rm -f build/verilator_lockstep/lockstep_coordinator
rm -f build/verilator_lockstep_d2/lockstep_coordinator
rm -f build/difftest/hard_ap_matrix.bin
rm -f build/difftest/hard_af.bin
rm -f build/difftest/hard_uxn_pxn.bin
rm -f build/difftest/hard_ttbr_gap.bin
rm -f build/difftest/p5a2_fetch.bin

preflight "qemu-apply" "bash qemu/scripts/apply-patches.sh"
preflight "qemu-build" "bash scripts/build-qemu.sh"
preflight "plugin-build" "make -C qemu/plugins"
preflight "lockstep-build" "make lockstep-build"

fail=0
for seed in 1 2 3 4 5; do
  if ! run_step "random-seed$seed" \
    "make difftest-random SEED=$seed LENGTH=100000"; then
    fail=1
  fi
done

# 随机延迟（0..4 周期）下的 MMU/异常锁步
preflight "delay2-build" "make lockstep-build-delay2"

# delay2 复用的定向镜像不由 lockstep-build 生成；在干净 CI worktree
# 显式生成，避免把“输入文件不存在”误报为 RTL/QEMU 失败。
generate_delay2_images() {
  python3 - <<'PY'
import sys
sys.path.insert(0, "sim/difftest")
import test_program
for name, fn in [
    ("hard_ap_matrix", "build_hard_ap_matrix_program"),
    ("hard_af", "build_hard_af_program"),
    ("hard_uxn_pxn", "build_hard_uxn_pxn_program"),
    ("hard_ttbr_gap", "build_hard_ttbr_gap_program"),
    ("p5a2_fetch", "build_p5a2_fetch_program"),
]:
    getattr(test_program, fn)(f"build/difftest/{name}.bin")
    print(f"{name}.bin 生成完成")
PY
}
preflight "delay2-images" "generate_delay2_images"

for name in hard_ap_matrix hard_af hard_uxn_pxn hard_ttbr_gap p5a2_fetch; do
  if ! run_step "delay2-$name" \
    "IMAGE=build/difftest/$name.bin MAX_INSNS=80 \
     COORD=build/verilator_lockstep_d2/lockstep_coordinator \
     bash sim/difftest/run_lockstep_step.sh"; then
    fail=1
  fi
done

# 干净 QEMU release 上补丁重放
QEMU_PATCH_TMP="$(mktemp -d "$TMP_ROOT/qemu-patch-XXXXXX")"
trap 'rm -rf "$QEMU_PATCH_TMP"' EXIT
if ! run_step "qemu-patch-replay" \
  "bash qemu/scripts/apply-patches.sh --fresh '$QEMU_PATCH_TMP' && \
   git -C '$QEMU_PATCH_TMP' diff --stat | grep -q ."; then
  fail=1
fi

if [[ $fail -eq 0 ]]; then
  echo "PASS: nightly 门禁全部通过（日志 $LOG_DIR/）"
else
  echo "FAIL: nightly 门禁有失败项" >&2
  exit 1
fi
