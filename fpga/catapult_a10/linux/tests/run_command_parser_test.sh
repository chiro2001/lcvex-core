#!/usr/bin/env bash
set -euo pipefail

REPO="$(cd "$(dirname "$0")/../../../.." && pwd)"
CROSS_COMPILE="${CROSS_COMPILE:-aarch64-linux-gnu-}"
QEMU_AARCH64="${QEMU_AARCH64:-qemu-aarch64}"
BUILD_ROOT="${CATAPULT_TEST_BUILD_ROOT:-$REPO/build/tmp}"

for tool in "${CROSS_COMPILE}gcc" "${CROSS_COMPILE}ld" \
	"${CROSS_COMPILE}readelf" "$QEMU_AARCH64"; do
	command -v "$tool" >/dev/null || {
		echo "ERROR: required tool not found: $tool" >&2
		exit 1
	}
done

mkdir -p "$BUILD_ROOT"
OUT="$(mktemp -d "$BUILD_ROOT/catapult-parser.XXXXXX")"
trap 'rm -rf -- "$OUT"' EXIT

"${CROSS_COMPILE}gcc" -c -nostdlib -ffreestanding -fno-stack-protector \
	-fno-pic -march=armv8-a -mgeneral-regs-only \
	"$REPO/baremetal/linux-catapult/init.S" -o "$OUT/init.o"
"${CROSS_COMPILE}ld" -nostdlib -static --build-id=none -z noexecstack \
	-Ttext=0x400000 -o "$OUT/init" "$OUT/init.o"
"${CROSS_COMPILE}readelf" -h "$OUT/init" | grep -q 'Machine:.*AArch64'
if "${CROSS_COMPILE}readelf" -l "$OUT/init" | grep -q 'INTERP'; then
	echo "ERROR: /init unexpectedly has a dynamic interpreter" >&2
	exit 1
fi

"${CROSS_COMPILE}gcc" -DLCVEX_PARSER_ONLY -march=armv8-a \
	-mgeneral-regs-only -fno-pic -c \
	"$REPO/baremetal/linux-catapult/init.S" -o "$OUT/init-parser.o"
"${CROSS_COMPILE}gcc" -std=c11 -O1 -march=armv8-a \
	-mgeneral-regs-only -fno-tree-vectorize -static \
	-Wl,--build-id=none \
	"$REPO/fpga/catapult_a10/linux/tests/command_parser_test.c" \
	"$OUT/init-parser.o" -o "$OUT/command-parser-test"
"$QEMU_AARCH64" -cpu cortex-a53 "$OUT/command-parser-test"
