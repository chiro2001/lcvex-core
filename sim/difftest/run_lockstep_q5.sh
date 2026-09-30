#!/usr/bin/env bash
# Q5 里程碑验收：discon / 退出 / 断开不会死锁。
# 三个场景依次验证：
#   1. 正常锁步到 max_insns（分支/循环）并快速退出，无死锁；
#   2. 提前 STOP（max_insns 小于程序长度），协调器正常结束，QEMU 回收；
#   3. 非法指令触发异常：插件上报 DISCON，协调器快速失败；
#   4. 运行中 SIGKILL QEMU：协调器检测连接中断并快速失败。
set -euo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$REPO/sim/difftest/run_lockstep.sh"
COORD_LOG="$REPO/build/difftest/lockstep_coord.log"
EXC_IMAGE="$REPO/build/difftest/q5exc.bin"

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

echo "[Q5-1] 正常锁步 36 条"
MAX_INSNS=36 "$SCRIPT"

echo "[Q5-2] 提前 STOP（max_insns=8，快速回收 QEMU）"
MAX_INSNS=8 COORD_TIMEOUT_S=30 "$SCRIPT"

echo "[Q5-3] store 到未映射地址触发异常 -> 上报 DISCON"
if [[ ! -f "$EXC_IMAGE" ]]; then
  fail "找不到 $EXC_IMAGE（先 make -C ... run_qemu --program q5exc）"
fi
if IMAGE="$EXC_IMAGE" MAX_INSNS=1000 EXPECT_FAIL=1 COORD_TIMEOUT_S=30 \
   "$SCRIPT"; then
  grep -q "DISCON" "$COORD_LOG" \
    || fail "协调器失败但日志中未出现 DISCON 诊断"
  cp "$REPO/build/difftest/lockstep_fail.txt" \
     "$REPO/build/difftest/lockstep_discon_fail.txt" 2>/dev/null || true
  echo "PASS: DISCON 诊断已记录"
else
  fail "discon 场景未按预期完成"
fi

echo "[Q5-4] 运行中 SIGKILL QEMU -> 协调器检测断开"
if MAX_INSNS=100000 EXPECT_FAIL=1 KILL_QEMU_AFTER=3 COORD_TIMEOUT_S=30 \
   "$SCRIPT"; then
  grep -q "连接中断" "$COORD_LOG" \
    || fail "协调器失败但日志中未出现连接中断诊断"
  echo "PASS: 连接中断诊断已记录"
else
  fail "断开场景未按预期完成"
fi

echo "PASS: Q5 discon/停止处理全部通过"
