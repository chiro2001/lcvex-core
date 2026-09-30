#!/usr/bin/env bash
# Build the small Linux inputs, package them behind the AArch64 BRAM loader,
# and run one resource-locked Catapult SoC boot/console simulation.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/../../.." && pwd)"
KERNEL_SRC="${KERNEL_SRC:-/home/chiro/projects/mycpu/lcvex/build/linux-6.6}"
OUT_ROOT="${LINUX_BOOT_OUT_ROOT:-$REPO/build/agents/T-20260928-002/linux-catapult}"
RESOURCE_LOCK="${RESOURCE_LOCK:-/home/chiro/projects/.resource-locks/resource-lock}"
SOURCE_ID="${KERNEL_SOURCE_ID:-linux-v6.6.0-local-tree-20260928}"
SIM_ROOT="$OUT_ROOT/simulation"
SIM_LAYOUT="$SIM_ROOT/linux_flash_layout.json"
SIM_DTB="$OUT_ROOT/artifacts/catapult-a10.dtb"

RESOURCE_TASK_ID=T-20260928-002 RESOURCE_OWNER=root KERNEL_SOURCE_ID="$SOURCE_ID" \
  bash "$REPO/scripts/build-linux-catapult.sh" \
  --kernel-src "$KERNEL_SRC" --out-root "$OUT_ROOT"

bash "$REPO/fpga/catapult_a10/boot/build_linux_loader.sh"

# Keep the behavioral boot test on the physical 128 MiB DDR aperture. Linux
# reserves a substantial part of this range during early boot; shrinking the
# DTB/model to 16 MiB changes the workload and can hide failures.
mkdir -p "$SIM_ROOT"
cp "$REPO/fpga/catapult_a10/boot/linux_flash_layout.json" "$SIM_LAYOUT"
python3 "$REPO/fpga/catapult_a10/boot/linux_image_format.py" build \
  --layout "$SIM_LAYOUT" \
  --image "$OUT_ROOT/artifacts/Image" \
  --dtb "$SIM_DTB" \
  --bin "$OUT_ROOT/artifacts/flash_data.bin" \
  --hex "$OUT_ROOT/artifacts/flash_data.hex"
python3 "$REPO/fpga/catapult_a10/tools/bin_to_memh.py" \
  --input "$OUT_ROOT/artifacts/flash_data.bin" \
  --word-bytes 64 \
  --output "$OUT_ROOT/artifacts/flash_data.memh"
FLASH_BIN_BYTES="$(stat -c '%s' "$OUT_ROOT/artifacts/flash_data.bin")"
if ((FLASH_BIN_BYTES >= 6000000)); then
  echo "ERROR: payload exceeds current simulation model capacity bytes=$FLASH_BIN_BYTES capacity=6000000" >&2
  exit 2
fi

[[ -x "$RESOURCE_LOCK" ]] || { echo "RESOURCE_LOCK_MISSING path=$RESOURCE_LOCK" >&2; exit 2; }
exec "$RESOURCE_LOCK" run local lcvex T-20260928-002 root -- \
  env VERILATOR_JOBS=1 LINUX_PLATFORM_TEST_OUT="$SIM_ROOT" \
  LINUX_BOOT_FLASH_MEMH="$OUT_ROOT/artifacts/flash_data.memh" \
  make -C "$REPO" b25-linux-boot-test
