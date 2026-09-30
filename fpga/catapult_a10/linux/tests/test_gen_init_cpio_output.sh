#!/usr/bin/env bash
set -euo pipefail

REPO="$(cd "$(dirname "$0")/../../../.." && pwd)"
BUILD_SCRIPT="$REPO/scripts/build-linux-catapult.sh"
KERNEL_SRC="${KERNEL_SRC:-$REPO/build/linux-6.6}"
HOSTCC="${HOSTCC:-cc}"
BUILD_ROOT="${CATAPULT_TEST_BUILD_ROOT:-$REPO/build/tmp}"

[[ -f "$KERNEL_SRC/usr/gen_init_cpio.c" ]] || {
	echo "ERROR: Linux source is required for the host tool test: $KERNEL_SRC/usr/gen_init_cpio.c" >&2
	exit 2
}
grep -Fq 'build_gen_init_cpio "$SRC_BUILD" "$KERNEL_OUT/usr/gen_init_cpio"' "$BUILD_SCRIPT" || {
	echo "ERROR: full build does not generate the host tool at KERNEL_OUT/usr/gen_init_cpio" >&2
	exit 1
}
grep -Fq '"$KERNEL_OUT/usr/gen_init_cpio" -t 0 "$INITRAMFS_LIST"' "$BUILD_SCRIPT" || {
	echo "ERROR: initramfs step does not use the generated KERNEL_OUT host tool" >&2
	exit 1
}

mkdir -p "$BUILD_ROOT"
OUT="$(mktemp -d "$BUILD_ROOT/gen-init-cpio.XXXXXX")"
trap 'rm -rf -- "$OUT"' EXIT
OUTPUT_ROOT="$OUT/output"

KERNEL_SRC="$KERNEL_SRC" HOSTCC="$HOSTCC" \
	"$BUILD_SCRIPT" --kernel-src "$KERNEL_SRC" --out-root "$OUTPUT_ROOT" \
	--gen-init-cpio-only

HOST_TOOL="$OUTPUT_ROOT/kernel/usr/gen_init_cpio"
[[ -x "$HOST_TOOL" ]] || {
	echo "ERROR: expected executable host tool at $HOST_TOOL" >&2
	exit 1
}
"$HOST_TOOL" -h >/dev/null 2>&1
HOST_TOOL_SHA256="$(sha256sum "$HOST_TOOL" | awk '{print $1}')"
echo "PASS: gen_init_cpio is built into and used from the independent KERNEL_OUT sha256=$HOST_TOOL_SHA256"
