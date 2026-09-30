#!/usr/bin/env bash
# L0: offline source, host correctness signature, parser, and BRAM image checks.
set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
PLATFORM_DIR="$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)"
REPO_DIR="$(CDPATH= cd -- "$PLATFORM_DIR/../.." && pwd)"
OUT_DIR="${LCVEX_MICROBENCH_TEST_DIR:-$REPO_DIR/build/agents/T-20260920-042/l0}"
HOST_CC="${HOST_CC:-cc}"

mkdir -p "$OUT_DIR"
cd "$REPO_DIR"

LCVEX_BOOT_BUILD_DIR="$OUT_DIR/boot" bash fpga/catapult_a10/boot/build.sh
LCVEX_BOOT_BUILD_DIR="$OUT_DIR/boot-repro" bash fpga/catapult_a10/boot/build.sh
for artifact in boot.elf boot.bin boot.hex boot.mif microbench-build-manifest.json; do
    cmp "$OUT_DIR/boot/$artifact" "$OUT_DIR/boot-repro/$artifact"
done
echo "MICROBENCH_REPRODUCIBLE_BUILD_PASS"

"$HOST_CC" -std=c11 -O2 -Wall -Wextra -Werror \
    -Ifpga/catapult_a10/coremark \
    -Ifpga/catapult_a10/coremark/upstream \
    fpga/catapult_a10/coremark/lcvex_bench.c \
    fpga/catapult_a10/tools/lcvex_bench_host_test.c \
    -o "$OUT_DIR/lcvex_bench_host_test"
"$OUT_DIR/lcvex_bench_host_test"

PYTHONPATH=fpga/catapult_a10/tools \
    python3 fpga/catapult_a10/tools/test_parse_microbench.py
python3 fpga/catapult_a10/tools/check_microbench_port.py \
    --elf "$OUT_DIR/boot/boot.elf" \
    --bin "$OUT_DIR/boot/boot.bin" \
    --hex "$OUT_DIR/boot/boot.hex" \
    --mif "$OUT_DIR/boot/boot.mif" \
    --manifest "$OUT_DIR/boot/microbench-build-manifest.json"

echo "LCVEX_B25_MICROBENCH_L0_PASS"
