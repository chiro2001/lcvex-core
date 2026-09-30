#!/usr/bin/env bash
# P6 C++ MMIO fabric 联合 checkpoint smoke：
# 1) hard_pl031 写入 LR 后保存 seq=9；
# 2) 校验 .dev.mmio.gz 中的 PL031 状态；
# 3) 同时恢复 QEMU VMState、DUT 架构/设备状态和 C++ fabric，继续锁步 7 条。
set -euo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
QEMU_BIN="${QEMU_BIN:-$REPO/../qemu/build/qemu-system-aarch64}"
COORD="${COORD:-$REPO/build/verilator_lockstep/lockstep_coordinator}"
PLUGIN="$REPO/qemu/plugins/lcvex_difftest.so"
IMAGE="$REPO/build/difftest/hard_pl031.bin"
PYTHON="${PYTHON:-python3}"
CHECKPOINT_TOOL="$REPO/sim/difftest/checkpoint.py"
RUN_DIR="$(mktemp -d "$REPO/build/difftest/checkpoint-mmio-joint.XXXXXX")"
COORD_PID=""
QEMU_PID=""

for f in "$QEMU_BIN" "$COORD" "$PLUGIN" "$IMAGE"; do
  [[ -f "$f" ]] || { echo "错误：找不到 $f" >&2; exit 1; }
done

stop_pid() {
  local pid="$1"
  [[ -z "$pid" ]] && return 0
  kill -TERM "$pid" 2>/dev/null || true
  for _ in $(seq 1 20); do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 0.05
  done
  kill -KILL "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
}
cleanup() {
  [[ -z "$QEMU_PID" ]] || stop_pid "$QEMU_PID"
  [[ -z "$COORD_PID" ]] || stop_pid "$COORD_PID"
  rm -rf "$RUN_DIR"
}
trap cleanup EXIT

CKPT_DIR="$RUN_DIR/chain"
mkdir -p "$CKPT_DIR"
# seq=9 是 LR=0x12345678 写入后；max=14 让捕获端自然完成 MR 写。
IMAGE="$IMAGE" DIFF_CKPT=1 CKPT_EVERY=10 CKPT_DIR="$CKPT_DIR" \
  RAM_FILE="$CKPT_DIR/ram.bin" MAX_INSNS=14 PROGRESS_EVERY=0 \
  bash "$REPO/sim/difftest/run_lockstep_step.sh" \
  >"$RUN_DIR/capture.log" 2>&1

LR="$("$PYTHON" "$CHECKPOINT_TOOL" read-mmio --chain "$CKPT_DIR" --seq 9 | \
  "$PYTHON" -c 'import json,sys; print(json.load(sys.stdin)["pl031_lr"])')"
if [[ "$LR" != "305419896" ]]; then
  echo "FAIL: MMIO checkpoint PL031 LR=$LR，期望 305419896" >&2
  exit 1
fi
echo "OK: C++ MMIO sidecar 保存 PL031 LR=0x12345678"

RAM="$RUN_DIR/ram.bin"
"$PYTHON" "$CHECKPOINT_TOOL" restore-ram \
  --chain "$CKPT_DIR" --seq 9 --output "$RAM" >/dev/null
gzip -cd "$CKPT_DIR/base-9.dev.gz" >"$RUN_DIR/state.dev"
gzip -cd "$CKPT_DIR/base-9.dev.timer.gz" >"$RUN_DIR/timer.raw"

SOCK="$RUN_DIR/step.sock"
"$COORD" --socket "$SOCK" --image "$IMAGE" --base 0x44000000 \
  --restore-arch "$CKPT_DIR/base-9.arch.gz" \
  --restore-sys "$CKPT_DIR/base-9.dev.sys.gz" \
  --restore-timer "$CKPT_DIR/base-9.dev.timer.gz" \
  --restore-gic "$CKPT_DIR/base-9.dev.gic.gz" \
  --restore-mmio "$CKPT_DIR/base-9.dev.mmio.gz" \
  --restore-ram "$RAM" --max-insns 7 --progress-every 0 \
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
  -icount shift=0,align=off,sleep=off \
  -rtc base=2000-01-01T00:00:00,clock=vm -display none \
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
echo "PASS: C++ MMIO PL031 checkpoint QEMU/DUT 联合恢复 7 条指令"
