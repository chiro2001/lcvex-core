#!/usr/bin/env bash
# 锁步差分：启动 Verilator 协调器 + QEMU（mode=sync 插件）。
# 用法：make lockstep
#
# 环境变量：
#   MAX_INSNS           协调器步数上限（默认 36）
#   EXPECT_FAIL         设为 1 时，协调器退出码非 0 视为测试通过
#                       （用于 Q5：discon/断开等预期失败场景）
#   KILL_QEMU_AFTER     >0 时在指定秒数后 SIGKILL QEMU（断开场景）
#   COORD_TIMEOUT_S     协调器最长等待秒数（默认 60）
set -euo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
QEMU_BIN="${QEMU_BIN:-$REPO/../qemu/build/qemu-system-aarch64}"
PLUGIN="$REPO/qemu/plugins/lcvex_difftest.so"
COORD="$REPO/build/verilator_lockstep/lockstep_coordinator"
SOCK="$REPO/build/difftest/lockstep.sock"
IMAGE="${IMAGE:-$REPO/build/difftest/p2.bin}"
DUMP="$REPO/build/difftest/lockstep_fail.txt"
COORD_LOG="$REPO/build/difftest/lockstep_coord.log"
QEMU_LOG="$REPO/build/difftest/lockstep_qemu.log"
BASE=0x44000000
MAX_INSNS="${MAX_INSNS:-36}"
EXPECT_FAIL="${EXPECT_FAIL:-0}"
KILL_QEMU_AFTER="${KILL_QEMU_AFTER:-0}"
COORD_TIMEOUT_S="${COORD_TIMEOUT_S:-60}"

if [[ ! -x "$COORD" ]]; then
  echo "错误：找不到协调器 $COORD（先 make lockstep-build）" >&2
  exit 1
fi
if [[ ! -f "$PLUGIN" ]]; then
  echo "错误：找不到插件 $PLUGIN" >&2
  exit 1
fi
if [[ ! -f "$IMAGE" ]]; then
  echo "错误：找不到镜像 $IMAGE" >&2
  exit 1
fi

mkdir -p "$(dirname "$SOCK")"
rm -f "$SOCK" "$DUMP" "$COORD_LOG" "$QEMU_LOG"

"$COORD" --socket "$SOCK" --image "$IMAGE" --base "$BASE" \
  --max-insns "$MAX_INSNS" --max-cycles-per-insn 1000 \
  --timeout-ms 30000 --dump "$DUMP" \
  > "$COORD_LOG" 2>&1 &
COORD_PID=$!

# 等待协调器监听就绪
for _ in $(seq 1 100); do
  [[ -S "$SOCK" ]] && break
  sleep 0.05
done

"$QEMU_BIN" -machine virt -cpu max -accel tcg,thread=single \
  -nographic \
  -plugin "file=$PLUGIN,mode=sync,socket=$SOCK" \
  -device "loader,file=$IMAGE,addr=$BASE,cpu-num=0,force-raw=on" \
  > "$QEMU_LOG" 2>&1 &
QEMU_PID=$!

# Q5：断开场景——在指定秒数后强杀 QEMU，验证协调器不会死锁
if [[ "$KILL_QEMU_AFTER" -gt 0 ]]; then
  (
    sleep "$KILL_QEMU_AFTER"
    kill -9 "$QEMU_PID" 2>/dev/null || true
  ) &
  KILLER_PID=$!
fi

set +e
# 等待协调器结束（最长 COORD_TIMEOUT_S 秒），随后回收 QEMU
for _ in $(seq 1 $((COORD_TIMEOUT_S * 10))); do
  if ! kill -0 "$COORD_PID" 2>/dev/null; then
    break
  fi
  sleep 0.1
done
if kill -0 "$COORD_PID" 2>/dev/null; then
  echo "错误：协调器超时未退出（${COORD_TIMEOUT_S}s），强杀" >&2
  kill -TERM "$COORD_PID" 2>/dev/null
fi
wait "$COORD_PID"
COORD_RC=$?
if kill -0 "$QEMU_PID" 2>/dev/null; then
  kill -TERM "$QEMU_PID" 2>/dev/null
  wait "$QEMU_PID" 2>/dev/null
fi
if [[ -n "${KILLER_PID:-}" ]]; then
  kill "$KILLER_PID" 2>/dev/null || true
fi
set -e

if [[ $COORD_RC -ne 0 ]]; then
  if [[ "$EXPECT_FAIL" == "1" ]]; then
    echo "PASS(预期失败): 协调器退出码 $COORD_RC"
    tail -5 "$COORD_LOG"
    exit 0
  fi
  echo "FAIL: 锁步测试失败（协调器退出码 $COORD_RC）"
  cat "$COORD_LOG"
  exit 1
fi

if [[ "$EXPECT_FAIL" == "1" ]]; then
  echo "FAIL: 预期协调器失败，但成功退出"
  cat "$COORD_LOG"
  exit 1
fi

echo "PASS: 锁步 $MAX_INSNS 条指令与 QEMU 完全一致"
