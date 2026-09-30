#!/usr/bin/env bash
# Q6 验证：QEMU fork step hook 精确异常上报（SVC/ERET），无 DUT。
# 用法：make q6 或直接运行本脚本。
set -euo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
QEMU_BIN="${QEMU_BIN:-$REPO/../qemu/build/qemu-system-aarch64}"
PLUGIN="$REPO/qemu/plugins/lcvex_difftest.so"
IMAGE="$REPO/build/difftest/q6_svc.bin"
SOCK="$REPO/build/difftest/q6.sock"
LOG="$REPO/build/difftest/q6_harness.log"
QEMU_LOG="$REPO/build/difftest/q6_qemu.log"
MAX_INSNS="${MAX_INSNS:-12}"

mkdir -p "$(dirname "$SOCK")"
rm -f "$SOCK" "$LOG" "$QEMU_LOG"

cd "$REPO"
make -C qemu/plugins
python3 - <<'EOF'
import sys
sys.path.insert(0, "sim/difftest")
import test_program
test_program.build_q6_svc_program("build/difftest/q6_svc.bin")
print("q6_svc.bin 生成完成")
EOF

python3 sim/difftest/q6_harness.py --socket "$SOCK" \
  --max-insns "$MAX_INSNS" --check-svc --dump "$LOG" &
HARNESS_PID=$!

for _ in $(seq 1 100); do
  [[ -S "$SOCK" ]] && break
  sleep 0.05
done

LCVEX_DIFFTEST_STEP=1 "$QEMU_BIN" -machine virt \
  -cpu max,has_el3=false,has_el2=false \
  -accel tcg,thread=single -icount shift=0,align=off,sleep=off -nographic \
  -plugin "file=$PLUGIN,mode=step,socket=$SOCK" \
  -device "loader,file=$IMAGE,addr=0x44000000,cpu-num=0,force-raw=on" \
  > "$QEMU_LOG" 2>&1 &
QEMU_PID=$!

set +e
wait "$HARNESS_PID"
RC=$?
kill -TERM "$QEMU_PID" 2>/dev/null
wait "$QEMU_PID" 2>/dev/null
set -e

if [[ $RC -ne 0 ]]; then
  echo "FAIL: Q6 harness 校验失败（退出码 $RC）"
  tail -40 "$LOG"
  exit 1
fi
echo "PASS: Q6 fork step hook 验证通过"
