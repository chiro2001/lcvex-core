#!/usr/bin/env bash
# Build Catapult-specific Linux 6.6 Image, DTB and no-libc initramfs inputs.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
KERNEL_SRC="${KERNEL_SRC:-$REPO/build/linux-6.6}"
OUT_ROOT="${CATAPULT_OUT_ROOT:-$REPO/build/linux-catapult-6.6}"
CROSS_COMPILE="${CROSS_COMPILE:-aarch64-linux-gnu-}"
HOSTCC="${HOSTCC:-cc}"
RESOURCE_LOCK="${RESOURCE_LOCK:-/home/chiro/projects/.resource-locks/resource-lock}"
RESOURCE_TASK_ID="${RESOURCE_TASK_ID:-T-20260928-003}"
RESOURCE_OWNER="${RESOURCE_OWNER:-linux_software}"
FRAGMENT="${CATAPULT_FRAGMENT:-$REPO/configs/linux-catapult-lite.fragment}"
INIT_SRC="$REPO/baremetal/linux-catapult/init.S"
DTS_SRC="$REPO/fpga/catapult_a10/linux/catapult-a10.dts"
JOBS_USE="${JOBS:-6}"
BUILD_IMAGE=1
SOURCE_ID_ONLY=0
RESOURCE_IDENTITY_ONLY=0
GEN_INIT_CPIO_ONLY=0
RESOURCE_RUN_ARGS=(local lcvex "$RESOURCE_TASK_ID" "$RESOURCE_OWNER")
ORIGINAL_ARGS=("$@")

usage() {
	cat <<EOF
usage: scripts/build-linux-catapult.sh [--kernel-src DIR] [--out-root DIR] [--inputs-only]
       scripts/build-linux-catapult.sh [--kernel-src DIR] --source-id-only
       scripts/build-linux-catapult.sh --resource-lock-identity-only
       scripts/build-linux-catapult.sh [--kernel-src DIR] [--out-root DIR] --gen-init-cpio-only
Defaults: KERNEL_SRC=$REPO/build/linux-6.6
          CATAPULT_OUT_ROOT=$REPO/build/linux-catapult-6.6
--inputs-only skips the full Linux Image build. Image builds acquire the local
resource lock automatically. --source-id-only reports source identity without
reading Kconfig or creating build outputs. RESOURCE_TASK_ID and RESOURCE_OWNER
override the full-build lock labels.
EOF
}

build_gen_init_cpio() {
	local source_root="$1"
	local output="$2"
	[[ -f "$source_root/usr/gen_init_cpio.c" ]] || {
		echo "ERROR: missing host tool source: $source_root/usr/gen_init_cpio.c" >&2
		return 2
	}
	command -v "$HOSTCC" >/dev/null || {
		echo "ERROR: host compiler not found: $HOSTCC" >&2
		return 2
	}
	mkdir -p "$(dirname "$output")"
	"$HOSTCC" -O2 -std=gnu11 -Wall -Wmissing-prototypes \
		-Wstrict-prototypes -fomit-frame-pointer -o "$output" \
		"$source_root/usr/gen_init_cpio.c"
	[[ -x "$output" ]] || {
		echo "ERROR: host tool was not created executable: $output" >&2
		return 1
	}
	"$output" -h >/dev/null 2>&1 || {
		echo "ERROR: generated host tool failed its help smoke check: $output" >&2
		return 1
	}
}

parse_args() {
	if (($# == 0)); then return; fi
	case "$1" in
		--kernel-src)
			(($# >= 2)) || { echo "ERROR: --kernel-src needs DIR" >&2; exit 2; }
			KERNEL_SRC="$2"; shift 2; parse_args "$@" ;;
		--out-root)
			(($# >= 2)) || { echo "ERROR: --out-root needs DIR" >&2; exit 2; }
			OUT_ROOT="$2"; shift 2; parse_args "$@" ;;
		--inputs-only) BUILD_IMAGE=0; shift; parse_args "$@" ;;
		--source-id-only) SOURCE_ID_ONLY=1; shift; parse_args "$@" ;;
		--resource-lock-identity-only) RESOURCE_IDENTITY_ONLY=1; shift; parse_args "$@" ;;
		--gen-init-cpio-only) GEN_INIT_CPIO_ONLY=1; BUILD_IMAGE=0; shift; parse_args "$@" ;;
		-h|--help) usage; exit 0 ;;
		*) echo "ERROR: unknown argument: $1" >&2; usage >&2; exit 2 ;;
	esac
}
parse_args "$@"
if ((RESOURCE_IDENTITY_ONLY)); then
	printf '%s\n' "${RESOURCE_RUN_ARGS[*]}"
	exit 0
fi

kernel_source_identity() {
	local source_root git_root
	[[ -d "$KERNEL_SRC" ]] || {
		echo "ERROR: kernel source directory not found: $KERNEL_SRC" >&2
		return 2
	}
	source_root="$(cd "$KERNEL_SRC" && pwd -P)"
	git_root="$(git -C "$source_root" rev-parse --show-toplevel 2>/dev/null || true)"
	if [[ -n "$git_root" ]]; then
		git_root="$(cd "$git_root" && pwd -P)"
	fi
	if [[ "$git_root" == "$source_root" ]] && git -C "$source_root" rev-parse --verify HEAD >/dev/null 2>&1; then
		SOURCE_REVISION="$(git -C "$source_root" rev-parse HEAD)"
		SOURCE_DIRTY="$(git -C "$source_root" status --porcelain | wc -l | tr -d ' ')"
	else
		SOURCE_REVISION="${KERNEL_SOURCE_ID:-no-git-metadata}"
		SOURCE_DIRTY=unknown
	fi
}
if ((SOURCE_ID_ONLY)); then
	kernel_source_identity
	printf '%s\n' "$SOURCE_REVISION"
	exit 0
fi
if ((GEN_INIT_CPIO_ONLY)); then
	[[ "$OUT_ROOT" = /* ]] || OUT_ROOT="$REPO/$OUT_ROOT"
	mkdir -p "$OUT_ROOT"
	OUT_ROOT="$(cd "$OUT_ROOT" && pwd -P)"
	build_gen_init_cpio "$KERNEL_SRC" "$OUT_ROOT/kernel/usr/gen_init_cpio"
	echo "PASS: host tool generated at $OUT_ROOT/kernel/usr/gen_init_cpio"
	exit 0
fi

if [[ ! -f "$KERNEL_SRC/Makefile" || ! -f "$KERNEL_SRC/Kconfig" || \
	! -f "$KERNEL_SRC/scripts/kconfig/merge_config.sh" || ! -f "$FRAGMENT" || \
	! -f "$INIT_SRC" || ! -f "$DTS_SRC" ]]; then
	echo "ERROR: missing Linux 6.6 source or Catapult input. Pass --kernel-src DIR (or set KERNEL_SRC)." >&2
	echo "       Expected kernel Makefile/Kconfig/merge_config.sh under: $KERNEL_SRC" >&2
	exit 2
fi

KERNEL_VERSION="$(awk -F= '/^[[:space:]]*VERSION[[:space:]]*=/ {gsub(/[[:space:]]/, "", $2); v=$2} /^[[:space:]]*PATCHLEVEL[[:space:]]*=/ {gsub(/[[:space:]]/, "", $2); p=$2} END {if (v != "" && p != "") print v "." p}' "$KERNEL_SRC/Makefile")"
if [[ "$KERNEL_VERSION" != "6.6" ]]; then
	echo "ERROR: expected Linux 6.6 source, found '${KERNEL_VERSION:-unknown}' at $KERNEL_SRC" >&2
	exit 2
fi

require_tool() {
	command -v "$1" >/dev/null || { echo "ERROR: required tool not found: $1" >&2; exit 2; }
}
require_tool make
require_tool awk
require_tool grep
require_tool head
require_tool sha256sum
require_tool dtc
require_tool gzip
require_tool "${CROSS_COMPILE}gcc"
require_tool "${CROSS_COMPILE}ld"
require_tool "$HOSTCC"

NEEDS_SRC_COPY=0
if [[ -f "$KERNEL_SRC/.config" || -d "$KERNEL_SRC/include/config" || \
	-d "$KERNEL_SRC/include/generated" || -d "$KERNEL_SRC/arch/arm64/include/generated" ]]; then
	NEEDS_SRC_COPY=1
fi
kernel_source_identity
TOOLCHAIN_GCC_VERSION="$("${CROSS_COMPILE}gcc" -dumpfullversion -dumpversion)"
TOOLCHAIN_LD_VERSION="$("${CROSS_COMPILE}ld" --version | head -n 1)"
HOSTCC_VERSION="$("$HOSTCC" --version | head -n 1)"
DTC_VERSION="$(dtc --version)"
if ((BUILD_IMAGE || NEEDS_SRC_COPY)) && [[ "${LCVEX_CATAPULT_LOCAL_LOCK_HELD:-0}" != 1 ]]; then
	[[ -x "$RESOURCE_LOCK" ]] || { echo "ERROR: local Image build requires resource lock: $RESOURCE_LOCK" >&2; exit 2; }
	exec "$RESOURCE_LOCK" run "${RESOURCE_RUN_ARGS[@]}" -- \
		env LCVEX_CATAPULT_LOCAL_LOCK_HELD=1 "$0" "${ORIGINAL_ARGS[@]}"
fi
[[ "$JOBS_USE" =~ ^[1-9][0-9]*$ ]] || { echo "ERROR: JOBS must be a positive integer" >&2; exit 2; }

[[ "$OUT_ROOT" = /* ]] || OUT_ROOT="$REPO/$OUT_ROOT"
mkdir -p "$OUT_ROOT"
OUT_ROOT="$(cd "$OUT_ROOT" && pwd)"
KERNEL_OUT="$OUT_ROOT/kernel"
TMP_ROOT="$OUT_ROOT/tmp"
ARTIFACT="$OUT_ROOT/artifacts"
PUBLISHED="$OUT_ROOT/published"
mkdir -p "$KERNEL_OUT" "$TMP_ROOT" "$ARTIFACT" "$PUBLISHED"

SRC_BUILD="$KERNEL_SRC"
if ((NEEDS_SRC_COPY)); then
	require_tool rsync
	SRC_BUILD="$TMP_ROOT/linux-6.6-source"
	if [[ ! -f "$SRC_BUILD/.lcvex-source-marker" ]]; then
		mkdir -p "$SRC_BUILD"
		rsync -a --delete-excluded --exclude='/.config' --exclude='/include/config' \
			--exclude='/include/generated' --exclude='/arch/arm64/include/generated' \
			"$KERNEL_SRC/" "$SRC_BUILD/"
		printf 'source=%s\n' "$KERNEL_SRC" > "$SRC_BUILD/.lcvex-source-marker"
	fi
fi

run_make() {
	make -C "$SRC_BUILD" O="$KERNEL_OUT" ARCH=arm64 CROSS_COMPILE="$CROSS_COMPILE" \
		KBUILD_BUILD_USER=lcvex KBUILD_BUILD_HOST=lcvex \
		KBUILD_BUILD_TIMESTAMP=1970-01-01T00:00:00Z "$@"
}

echo "==> Catapult Linux 6.6: source=$SRC_BUILD revision=$SOURCE_REVISION dirty_files=$SOURCE_DIRTY output=$OUT_ROOT"
run_make allnoconfig
(cd "$KERNEL_OUT" && "$SRC_BUILD/scripts/kconfig/merge_config.sh" -m -O "$KERNEL_OUT" \
	"$KERNEL_OUT/.config" "$FRAGMENT")
run_make olddefconfig

require_config() {
	grep -qx "$1=y" "$KERNEL_OUT/.config" || { echo "ERROR: Kconfig did not enable $1" >&2; exit 1; }
}
require_config CONFIG_ARM64
require_config CONFIG_MMU
require_config CONFIG_OF
require_config CONFIG_ARM_GIC
require_config CONFIG_ARM_ARCH_TIMER
require_config CONFIG_SERIAL_ALTERA_JTAGUART
require_config CONFIG_SERIAL_ALTERA_JTAGUART_CONSOLE
require_config CONFIG_BLK_DEV_INITRD
require_config CONFIG_BINFMT_ELF
require_config CONFIG_DEVTMPFS
require_config CONFIG_DEVTMPFS_MOUNT

INIT_BUILD="$ARTIFACT/init-build"
mkdir -p "$INIT_BUILD"
"${CROSS_COMPILE}gcc" -c -nostdlib -ffreestanding -fno-stack-protector \
	-fno-pic -march=armv8-a -mgeneral-regs-only "$INIT_SRC" -o "$INIT_BUILD/init.o"
"${CROSS_COMPILE}ld" -nostdlib -static --build-id=none -z noexecstack \
	-Ttext=0x400000 -o "$INIT_BUILD/init" "$INIT_BUILD/init.o"
dtc -I dts -O dtb -o "$ARTIFACT/catapult-a10.dtb" "$DTS_SRC"
cp "$DTS_SRC" "$ARTIFACT/catapult-a10.dts"

build_gen_init_cpio "$SRC_BUILD" "$KERNEL_OUT/usr/gen_init_cpio"
INITRAMFS_LIST="$ARTIFACT/initramfs.list"
printf 'dir /dev 0755 0 0\nnod /dev/console 0600 0 0 c 5 1\nfile /init %s 0755 0 0\n' \
	"$INIT_BUILD/init" > "$INITRAMFS_LIST"
"$KERNEL_OUT/usr/gen_init_cpio" -t 0 "$INITRAMFS_LIST" > "$ARTIFACT/initramfs.cpio"
gzip -n -f -9 < "$ARTIFACT/initramfs.cpio" > "$ARTIFACT/initramfs.gz"
"$SRC_BUILD/scripts/config" --file "$KERNEL_OUT/.config" --set-str \
	CONFIG_INITRAMFS_SOURCE "$ARTIFACT/initramfs.cpio"
run_make olddefconfig

if ((BUILD_IMAGE)); then
	echo "==> Building arm64 Image with JOBS=$JOBS_USE"
	run_make -j"$JOBS_USE" Image
	cp "$KERNEL_OUT/arch/arm64/boot/Image" "$ARTIFACT/Image"
	cp "$ARTIFACT/Image" "$PUBLISHED/Image"
fi
cp "$ARTIFACT/catapult-a10.dtb" "$PUBLISHED/catapult-a10.dtb"
cp "$ARTIFACT/initramfs.gz" "$PUBLISHED/initramfs"
cp "$INIT_BUILD/init" "$ARTIFACT/init"
cp "$INIT_BUILD/init" "$PUBLISHED/init"
sha256sum "$ARTIFACT/catapult-a10.dtb" "$ARTIFACT/init" \
	"$ARTIFACT/initramfs.gz" "$KERNEL_OUT/usr/gen_init_cpio" \
	"$KERNEL_OUT/.config" > "$ARTIFACT/SHA256SUMS"
if ((BUILD_IMAGE)); then sha256sum "$ARTIFACT/Image" >> "$ARTIFACT/SHA256SUMS"; fi
cp "$ARTIFACT/SHA256SUMS" "$PUBLISHED/SHA256SUMS"
cat > "$ARTIFACT/manifest.txt" <<EOF
format=LCVEX-catapult-linux-6.6-v1
kernel_version=$KERNEL_VERSION
kernel_source=$KERNEL_SRC
kernel_source_revision=$SOURCE_REVISION
kernel_source_dirty_files=$SOURCE_DIRTY
resource_task_id=$RESOURCE_TASK_ID
resource_owner=$RESOURCE_OWNER
kernel_output=$KERNEL_OUT
artifact_root=$ARTIFACT
published_root=$PUBLISHED
jobs=$JOBS_USE
cross_compile=$CROSS_COMPILE
gcc_version=$TOOLCHAIN_GCC_VERSION
ld_version=$TOOLCHAIN_LD_VERSION
dtc_version=$DTC_VERSION
hostcc_version=$HOSTCC_VERSION
image_built=$BUILD_IMAGE
EOF
cp "$ARTIFACT/manifest.txt" "$PUBLISHED/manifest.txt"
if ((BUILD_IMAGE)); then
	echo "PASS: Catapult Linux Image/DTB/initramfs inputs generated"
	printf '  Image: %s\n  DTB:   %s\n  init:  %s\n' "$PUBLISHED/Image" "$PUBLISHED/catapult-a10.dtb" "$PUBLISHED/init"
else
	echo "PASS: Catapult config/DTB/initramfs inputs generated (Image skipped)"
fi
