#!/usr/bin/env bash
# P4b 验收：异常/系统指令定向锁步（mode=step）。
# 覆盖：EL1h SVC 往返、EL0 SVC 往返、UDEF、DABT、IABT。
set -euo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO"
mkdir -p "$REPO/build/difftest"

make -C qemu/plugins
make lockstep-build

python3 - <<'EOF'
import sys
sys.path.insert(0, "sim/difftest")
import test_program
for name, fn in [
    ("q6_svc", "build_q6_svc_program"),
    ("p4b_el0_svc", "build_p4b_el0_svc_program"),
    ("p4b_invalid", "build_p4b_invalid_program"),
    ("p4b_dabt", "build_p4b_dabt_program"),
    ("p4b_iabt", "build_p4b_iabt_program"),
]:
    getattr(test_program, fn)(f"build/difftest/{name}.bin")
    print(f"{name}.bin 生成完成")
EOF

declare -A INSNS=(
  [q6_svc]=14
  [p4b_el0_svc]=18
  [p4b_invalid]=12
  [p4b_dabt]=12
  [p4b_iabt]=12
)

for name in q6_svc p4b_el0_svc p4b_invalid p4b_dabt p4b_iabt; do
  echo "===== $name ====="
  IMAGE="$REPO/build/difftest/$name.bin" MAX_INSNS="${INSNS[$name]}" \
    bash sim/difftest/run_lockstep_step.sh
done

echo "PASS: P4b 异常/系统指令定向锁步全部通过"
