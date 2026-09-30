#!/usr/bin/env bash
# P5a 验收：MMU 数据翻译（P5a）+ 取指翻译与 IABT 合并（P5a-2）。
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
    ("p5a_mmu", "build_p5a_mmu_program"),
    ("p5a_mmu_el0", "build_p5a_mmu_program_el0"),
    ("p5a2_fetch", "build_p5a2_fetch_program"),
]:
    getattr(test_program, fn)(f"build/difftest/{name}.bin")
    print(f"{name}.bin 生成完成")
EOF

declare -A INSNS=(
  [p5a_mmu]=24
  [p5a_mmu_el0]=26
  [p5a2_fetch]=40
)

for name in p5a_mmu p5a_mmu_el0 p5a2_fetch; do
  echo "===== $name ====="
  IMAGE="$REPO/build/difftest/$name.bin" MAX_INSNS="${INSNS[$name]}" \
    bash sim/difftest/run_lockstep_step.sh
done

echo "PASS: P5a MMU 数据翻译锁步全部通过"
