#!/usr/bin/env bash
# LCVXSYS3 联合恢复 smoke：PMUSERENR_EL0、TCR2_EL1、PIRE0_EL1 与有效 exclusive
# monitor 必须由 QEMU sidecar 经恢复端口进入 DUT。保存点位于 LDXR 后，
# 恢复后 STXR 必须成功写入，避免“仅恢复普通系统寄存器”的假绿。
set -euo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
QEMU_BIN="${QEMU_BIN:-$REPO/../qemu/build/qemu-system-aarch64}"
COORD="${COORD:-$REPO/build/verilator_lockstep/lockstep_coordinator}"
PLUGIN="$REPO/qemu/plugins/lcvex_difftest.so"
IMAGE="$REPO/build/difftest/hard_checkpoint_sys_v3.bin"
PYTHON="${PYTHON:-python3}"
CHECKPOINT_TOOL="$REPO/sim/difftest/checkpoint.py"

for f in "$QEMU_BIN" "$COORD" "$PLUGIN" "$IMAGE"; do
  if [[ ! -f "$f" ]]; then
    echo "错误：找不到 $f" >&2
    exit 1
  fi
done

RUN_DIR="$(mktemp -d "$REPO/build/difftest/checkpoint-sys-v3-joint.XXXXXX")"
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
  [[ -n "$QEMU_PID" ]] && stop_pid "$QEMU_PID"
  [[ -n "$COORD_PID" ]] && stop_pid "$COORD_PID"
  find "$RUN_DIR" -mindepth 1 -delete 2>/dev/null || true
  rmdir "$RUN_DIR" 2>/dev/null || true
}
trap cleanup EXIT

CKPT_DIR="$RUN_DIR/chain"
mkdir -p "$CKPT_DIR"

# label 不计数；第 12 条（seq=11）为 LDXR。保存后下一条是 MRS
# PMUSERENR，随后读 TCR2、STXR 和 LDR，五条共同检验 v3 状态。
IMAGE="$IMAGE" DIFF_CKPT=1 CKPT_EVERY=12 CKPT_DIR="$CKPT_DIR" \
  RAM_FILE="$CKPT_DIR/ram.bin" MAX_INSNS=17 PROGRESS_EVERY=0 \
  bash "$REPO/sim/difftest/run_lockstep_step.sh" \
  >"$RUN_DIR/capture.log" 2>&1

read -r PMU TCR2 PIRE0 EXCL_ADDR EXCL_VAL EXCL_HIGH <<<"$($PYTHON "$CHECKPOINT_TOOL" read-sys \
  --chain "$CKPT_DIR" --seq 11 | $PYTHON -c 'import json,sys; d=json.load(sys.stdin); \
print(d["pmuserenr_el0"], d["tcr2_el1"], d["pire0_el1"], d["exclusive_addr"], \
      d["exclusive_val"], d["exclusive_high"])')"
if [[ "$PMU" != "15" || "$TCR2" != "458770" || "$PIRE0" != "1450" || \
      "$EXCL_ADDR" != "1140854784" || "$EXCL_VAL" != "85" || \
      "$EXCL_HIGH" != "0" ]]; then
  echo "FAIL: LCVXSYS3 字段错误 pmu=$PMU tcr2=$TCR2 pire0=$PIRE0 addr=$EXCL_ADDR val=$EXCL_VAL high=$EXCL_HIGH" >&2
  exit 1
fi
echo "OK: LCVXSYS3 pmuserenr=$PMU tcr2=$TCR2 pire0=$PIRE0 exclusive=[$EXCL_ADDR,$EXCL_VAL,$EXCL_HIGH]"

RAM="$RUN_DIR/ram.bin"
"$PYTHON" "$CHECKPOINT_TOOL" restore-ram --chain "$CKPT_DIR" --seq 11 \
  --output "$RAM" >/dev/null
gzip -cd "$CKPT_DIR/base-11.dev.gz" >"$RUN_DIR/state.dev"
gzip -cd "$CKPT_DIR/base-11.dev.timer.gz" >"$RUN_DIR/timer.raw"

SOCK="$RUN_DIR/step.sock"
"$COORD" --socket "$SOCK" --image "$IMAGE" --base 0x44000000 \
  --restore-sys "$CKPT_DIR/base-11.dev.sys.gz" \
  --restore-timer "$CKPT_DIR/base-11.dev.timer.gz" \
  --restore-gic "$CKPT_DIR/base-11.dev.gic.gz" \
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

LCVEX_DIFFTEST_STEP=1 LCVEX_TIMER_RESTORE_PATH="$RUN_DIR/timer.raw" \
  "$QEMU_BIN" -machine virt -cpu max,has_el3=false,has_el2=false \
  -accel tcg,thread=single,tb-size=64 -icount shift=0,align=off,sleep=off \
  -display none -incoming "exec:cat $RUN_DIR/state.dev" \
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
echo "PASS: LCVXSYS3 QEMU/DUT 联合恢复 5 条指令"
