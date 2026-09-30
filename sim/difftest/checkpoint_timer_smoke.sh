#!/usr/bin/env bash
# Generic Timer checkpoint 联合恢复 smoke：
# 1) QEMU/RTL 锁步捕获 seq=0；
# 2) 恢复 RAM、QEMU device VMState 和两个 sidecar；
# 3) QEMU -incoming 与 DUT 各执行下一条 CNTVCT，比较结果。
set -euo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
QEMU_BIN="${QEMU_BIN:-$REPO/../qemu/build/qemu-system-aarch64}"
COORD="${COORD:-$REPO/build/verilator_lockstep/lockstep_coordinator}"
PLUGIN="$REPO/qemu/plugins/lcvex_difftest.so"
IMAGE="${IMAGE:-$REPO/build/difftest/hard_timer.bin}"

for f in "$QEMU_BIN" "$COORD" "$PLUGIN" "$IMAGE"; do
  if [[ ! -f "$f" ]]; then
    echo "错误：找不到 $f" >&2
    exit 1
  fi
done

RUN_DIR="$(mktemp -d "$REPO/build/difftest/checkpoint-timer-joint.XXXXXX")"
COORD_PID=""
QEMU_PID=""
stop_pid() {
  local pid="$1"
  [[ -z "$pid" ]] && return 0
  kill -TERM "$pid" 2>/dev/null || true
  for _ in $(seq 1 20); do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 0.05
  done
  # -incoming 在某些 QEMU 错误路径会阻塞退出；这里只对本 smoke 自己
  # 启动且已明确记录的 PID 使用 KILL，避免遗留高 CPU 进程。
  kill -KILL "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
}
cleanup() {
  if [[ -n "$QEMU_PID" ]]; then
    stop_pid "$QEMU_PID"
  fi
  if [[ -n "$COORD_PID" ]]; then
    stop_pid "$COORD_PID"
  fi
  find "$RUN_DIR" -mindepth 1 -delete 2>/dev/null || true
  rmdir "$RUN_DIR" 2>/dev/null || true
}
trap cleanup EXIT

CKPT_DIR="$RUN_DIR/chain"
mkdir -p "$CKPT_DIR"

# 在第一条 CNTPCT 之后保存，下一条就是 CNTVCT，能检测计数边界转换。
IMAGE="$IMAGE" DIFF_CKPT=1 CKPT_EVERY=1 CKPT_DIR="$CKPT_DIR" \
  RAM_FILE="$CKPT_DIR/ram.bin" MAX_INSNS=2 PROGRESS_EVERY=0 \
  bash "$REPO/sim/difftest/run_lockstep_step.sh" \
  >"$RUN_DIR/capture.log" 2>&1

RAM="$RUN_DIR/ram.bin"
python3 "$REPO/sim/difftest/checkpoint.py" restore-ram \
  --chain "$CKPT_DIR" --seq 0 --output "$RAM" >/dev/null
gzip -cd "$CKPT_DIR/base-0.dev.gz" >"$RUN_DIR/state.dev"
gzip -cd "$CKPT_DIR/base-0.dev.timer.gz" >"$RUN_DIR/timer.raw"

SOCK="$RUN_DIR/step.sock"
"$COORD" --socket "$SOCK" --image "$IMAGE" --base 0x44000000 \
  --restore-sys "$CKPT_DIR/base-0.dev.sys.gz" \
  --restore-timer "$CKPT_DIR/base-0.dev.timer.gz" \
  --restore-gic "$CKPT_DIR/base-0.dev.gic.gz" \
  --restore-ram "$RAM" --max-insns 1 --progress-every 0 \
  --timeout-ms 30000 --dump "$RUN_DIR/fail.txt" \
  >"$RUN_DIR/coord.log" 2>&1 &
COORD_PID=$!
for _ in $(seq 1 300); do
  [[ -S "$SOCK" ]] && break
  sleep 0.01
done
if [[ ! -S "$SOCK" ]]; then
  cat "$RUN_DIR/coord.log" >&2 || true
  exit 1
fi

LCVEX_DIFFTEST_STEP=1 LCVEX_TIMER_RESTORE_PATH="$RUN_DIR/timer.raw" \
  "$QEMU_BIN" -machine virt -cpu max,has_el3=false,has_el2=false \
  -accel tcg,thread=single,tb-size=64 \
  -icount shift=0,align=off,sleep=off -display none \
  -incoming "exec:cat $RUN_DIR/state.dev" \
  -object "memory-backend-file,id=lcvexram,size=128M,mem-path=$RAM,share=on" \
  -machine memory-backend=lcvexram \
  -plugin "file=$PLUGIN,mode=step,socket=$SOCK" \
  >"$RUN_DIR/qemu.log" 2>&1 &
QEMU_PID=$!

set +e
wait "$COORD_PID"
RC=$?
set -e
COORD_PID=""
if [[ $RC -ne 0 ]]; then
  cat "$RUN_DIR/coord.log" >&2 || true
  cat "$RUN_DIR/qemu.log" >&2 || true
  exit "$RC"
fi
echo "PASS: Generic Timer checkpoint QEMU/DUT 联合恢复 1 条指令"
