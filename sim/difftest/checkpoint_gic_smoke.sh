#!/usr/bin/env bash
# GICv2 checkpoint 联合恢复 smoke：在 hard_gic 配置完成后保存 seq=29，
# 恢复 QEMU device state/GIC sidecar 与 DUT，继续执行 5 条 MMIO 指令。
set -euo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
QEMU_BIN="${QEMU_BIN:-$REPO/../qemu/build/qemu-system-aarch64}"
COORD="${COORD:-$REPO/build/verilator_lockstep/lockstep_coordinator}"
PLUGIN="$REPO/qemu/plugins/lcvex_difftest.so"
IMAGE="${IMAGE:-$REPO/build/difftest/hard_gic.bin}"
for f in "$QEMU_BIN" "$COORD" "$PLUGIN" "$IMAGE"; do
  [[ -f "$f" ]] || { echo "错误：找不到 $f" >&2; exit 1; }
done

RUN_DIR="$(mktemp -d "$REPO/build/difftest/checkpoint-gic-joint.XXXXXX")"
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
  kill -KILL "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
}
cleanup() {
  [[ -z "$QEMU_PID" ]] || stop_pid "$QEMU_PID"
  [[ -z "$COORD_PID" ]] || stop_pid "$COORD_PID"
  find "$RUN_DIR" -mindepth 1 -delete 2>/dev/null || true
  rmdir "$RUN_DIR" 2>/dev/null || true
}
trap cleanup EXIT

CKPT_DIR="$RUN_DIR/chain"
mkdir -p "$CKPT_DIR"
IMAGE="$IMAGE" DIFF_CKPT=1 CKPT_EVERY=30 CKPT_DIR="$CKPT_DIR" \
  RAM_FILE="$CKPT_DIR/ram.bin" MAX_INSNS=31 PROGRESS_EVERY=0 \
  bash "$REPO/sim/difftest/run_lockstep_step.sh" \
  >"$RUN_DIR/capture.log" 2>&1

RAM="$RUN_DIR/ram.bin"
python3 "$REPO/sim/difftest/checkpoint.py" restore-ram \
  --chain "$CKPT_DIR" --seq 29 --output "$RAM" >/dev/null
gzip -cd "$CKPT_DIR/base-29.dev.gz" >"$RUN_DIR/state.dev"

SOCK="$RUN_DIR/step.sock"
"$COORD" --socket "$SOCK" --image "$IMAGE" --base 0x44000000 \
  --restore-sys "$CKPT_DIR/base-29.dev.sys.gz" \
  --restore-gic "$CKPT_DIR/base-29.dev.gic.gz" \
  --restore-ram "$RAM" --max-insns 5 --progress-every 0 \
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

LCVEX_DIFFTEST_STEP=1 "$QEMU_BIN" \
  -machine virt -cpu max,has_el3=false,has_el2=false \
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
echo "PASS: GIC checkpoint QEMU/DUT 联合恢复 5 条指令"
