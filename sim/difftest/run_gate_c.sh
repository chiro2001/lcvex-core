#!/usr/bin/env bash
# Gate C 验收：同步异常与 EL0/EL1 定向锁步全套（mode=step）。
# 覆盖：EL1h SVC、EL0 SVC、UDEF、DABT、IABT、EL0 越权 MRS、EL0 双 SVC。
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
    ("p4c_el0_priv", "build_p4c_el0_priv_program"),
    ("p4c_el0_double_svc", "build_p4c_el0_double_svc_program"),
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
  [p4c_el0_priv]=16
  [p4c_el0_double_svc]=22
)

for name in q6_svc p4b_el0_svc p4b_invalid p4b_dabt p4b_iabt \
            p4c_el0_priv p4c_el0_double_svc; do
  echo "===== $name ====="
  IMAGE="$REPO/build/difftest/$name.bin" MAX_INSNS="${INSNS[$name]}" \
    bash sim/difftest/run_lockstep_step.sh
done

echo "PASS: Gate C 异常/EL0-EL1 定向锁步全部通过（7 组）"
