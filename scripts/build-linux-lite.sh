#!/usr/bin/env bash
# 构建 Linux 6.6 单核 lite 线及其最小静态 /init initramfs。
#
# 所有临时/发布输入默认落在 build/tmp；不触碰主线 build/linux-6.6 的
# .config，也不把长期 artifact 写入 /tmp。若已有内核源树带生成文件，
# 使用独立副本作为只读构建源，避免污染主线构建目录。
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
KERNEL_SRC="${KERNEL_SRC:-$REPO/build/linux-6.6}"
OUT="${LITE_OUT:-$REPO/build/linux-lite-6.6}"
TMP_ROOT="${LCVEX_TMP_DIR:-$REPO/build/tmp}"
ARTIFACT="${LITE_ARTIFACT_DIR:-$TMP_ROOT/linux-lite-6.6}"
PUBLISHED="${LITE_PUBLISHED_DIR:-$REPO/build/difftest/linux-lite}"
ARCH="${ARCH:-arm64}"
CROSS_COMPILE="${CROSS_COMPILE:-aarch64-linux-gnu-}"
JOBS_REQUESTED="${JOBS:-}"
WAIT_FOR_RESOURCES="${WAIT_FOR_RESOURCES:-1}"
RESERVE_SLOTS="${RESERVE_SLOTS:-0}"
QEMU_BIN="${QEMU_BIN:-$REPO/../qemu/build/qemu-system-aarch64}"
KERNEL_APPEND="${KERNEL_APPEND:-console=ttyAMA0,115200 earlycon=pl011,0x09000000 rdinit=/init nokaslr panic=-1}"
FRAGMENT="${LITE_FRAGMENT:-$REPO/configs/linux-lite-6.6.fragment}"
INIT_SRC="$REPO/baremetal/linux-lite/init.S"

for f in "$KERNEL_SRC/Makefile" "$KERNEL_SRC/Kconfig" "$FRAGMENT" "$INIT_SRC"; do
  [[ -f "$f" ]] || { echo "错误：找不到 $f" >&2; exit 1; }
done
command -v "$CROSS_COMPILE"gcc >/dev/null || {
  echo "错误：找不到 ${CROSS_COMPILE}gcc" >&2; exit 1;
}
command -v "$CROSS_COMPILE"ld >/dev/null || {
  echo "错误：找不到 ${CROSS_COMPILE}ld" >&2; exit 1;
}
command -v cpio >/dev/null || { echo "错误：找不到 cpio" >&2; exit 1; }
command -v gzip >/dev/null || { echo "错误：找不到 gzip" >&2; exit 1; }

mkdir -p "$TMP_ROOT" "$ARTIFACT" "$PUBLISHED" "$OUT"

# Linux make 的 out-of-tree 检查要求源树没有 .config/generated。主线源树
# 已经用于正常 Linux 构建，因此只建立一次独立副本；源文件不再复制到 /tmp。
SRC_BUILD="$KERNEL_SRC"
if [[ -f "$KERNEL_SRC/.config" || -d "$KERNEL_SRC/include/config" || \
      -d "$KERNEL_SRC/include/generated" || -d "$KERNEL_SRC/arch/arm64/include/generated" ]]; then
  SRC_BUILD="$TMP_ROOT/linux-lite-src"
  if [[ ! -f "$SRC_BUILD/.lcvex-source-marker" ]]; then
    mkdir -p "$SRC_BUILD"
    command -v rsync >/dev/null || {
      echo "错误：脏源树需要 rsync 生成不带构建输出的 CoW 副本" >&2
      exit 1
    }
    rsync -a --delete-excluded \
      --exclude='/.config' --exclude='/include/config' \
      --exclude='/include/generated' --exclude='/arch/arm64/include/generated' \
      "$KERNEL_SRC/" "$SRC_BUILD/"
    printf 'source=%s\n' "$KERNEL_SRC" > "$SRC_BUILD/.lcvex-source-marker"
  fi
fi

# 由 planner 决定可用物理核和默认构建并行度；资源不足时按项目规则排队。
PLAN_ARGS=(--local --reserve-slots="$RESERVE_SLOTS")
[[ "$WAIT_FOR_RESOURCES" == "1" ]] && PLAN_ARGS+=(--wait)
PLAN="$(bash "$REPO/scripts/test_planner.sh" "${PLAN_ARGS[@]}")"
PLAN_PARALLEL="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["parallel"])' <<<"$PLAN")"
PLAN_CPUS="$(python3 -c 'import json,sys; print(" ".join(map(str,json.load(sys.stdin)["cpus"])))' <<<"$PLAN")"
if [[ -n "$JOBS_REQUESTED" ]]; then
  JOBS="$JOBS_REQUESTED"
else
  JOBS="$PLAN_PARALLEL"
fi
(( JOBS > 6 )) && JOBS=6
(( JOBS < 1 )) && { echo "错误：没有可用构建槽位" >&2; exit 1; }
CPU_BIND=""
if [[ -n "$PLAN_CPUS" ]]; then
  CPU_BIND="$(tr ' ' ',' <<<"$PLAN_CPUS" | sed 's/,$//')"
  CPU_COUNT="$(wc -w <<<"$PLAN_CPUS")"
  (( JOBS > CPU_COUNT )) && JOBS="$CPU_COUNT"
fi
echo "==> Linux lite: source=$SRC_BUILD out=$OUT jobs=$JOBS cpus=$CPU_BIND"

run_make() {
  local -a cmd=(make -C "$SRC_BUILD" O="$OUT" ARCH="$ARCH"
    CROSS_COMPILE="$CROSS_COMPILE" KBUILD_BUILD_USER=lcvex
    KBUILD_BUILD_HOST=lcvex KBUILD_BUILD_TIMESTAMP=1970-01-01T00:00:00Z "$@")
  if [[ -n "$CPU_BIND" ]]; then
    taskset -c "$CPU_BIND" "${cmd[@]}"
  else
    "${cmd[@]}"
  fi
}

# allnoconfig 只在 lite 输出目录生成配置；随后严格合并可审阅 fragment。
run_make allnoconfig
(cd "$OUT" && "$SRC_BUILD/scripts/kconfig/merge_config.sh" -m -O "$OUT" \
  "$OUT/.config" "$FRAGMENT")
run_make olddefconfig

# 编译无 libc 的 PID 1。
INIT_BUILD="$ARTIFACT/init-build"
mkdir -p "$INIT_BUILD"
"${CROSS_COMPILE}gcc" -c -nostdlib -ffreestanding -fno-stack-protector \
  -fno-pic -march=armv8-a "$INIT_SRC" -o "$INIT_BUILD/init.o"
"${CROSS_COMPILE}ld" -nostdlib -static -z noexecstack -Ttext=0x400000 \
  -o "$INIT_BUILD/init" "$INIT_BUILD/init.o"

INITRAMFS_LIST="$ARTIFACT/initramfs.list"
printf 'dir /dev 0755 0 0\nnod /dev/console 0600 0 0 c 5 1\nfile /init %s 0755 0 0\n' \
  "$INIT_BUILD/init" > "$INITRAMFS_LIST"
"$SRC_BUILD/usr/gen_init_cpio" "$INITRAMFS_LIST" > "$ARTIFACT/initramfs.cpio"
gzip -n -f -9 < "$ARTIFACT/initramfs.cpio" > "$ARTIFACT/initramfs"

# 把 initramfs 路径写入 lite .config，再重新解析依赖并构建 Image。
"$SRC_BUILD/scripts/config" --file "$OUT/.config" --set-str \
  CONFIG_INITRAMFS_SOURCE "$INITRAMFS_LIST"
run_make olddefconfig
run_make -j"$JOBS" Image

cp "$OUT/arch/arm64/boot/Image" "$ARTIFACT/Image"
cp "$ARTIFACT/Image" "$PUBLISHED/Image"
cp "$ARTIFACT/initramfs" "$PUBLISHED/initramfs"

# DTB 由锁步 runner 在首次 lite 运行时按同一 KERNEL_APPEND 导出；已有
# 确定性 raw DTB 可先复制成 lite 专属输入，runner 传 KERNEL_DTB_REGEN=1
# 时会覆盖它，不影响主线的 qemu-fdt-raw.bin。
if [[ -f "$REPO/build/difftest/qemu-fdt-raw.bin" ]]; then
  cp "$REPO/build/difftest/qemu-fdt-raw.bin" "$ARTIFACT/qemu-lite-fdt-raw.bin"
  cp "$ARTIFACT/qemu-lite-fdt-raw.bin" "$PUBLISHED/qemu-lite-fdt-raw.bin"
fi

sha256sum "$ARTIFACT/Image" "$ARTIFACT/initramfs" "$OUT/.config" \
  > "$ARTIFACT/SHA256SUMS"
cp "$ARTIFACT/SHA256SUMS" "$PUBLISHED/SHA256SUMS"
cat > "$ARTIFACT/manifest.txt" <<EOF
format=LCVX-linux-lite-v1
kernel_source=$KERNEL_SRC
source_build=$SRC_BUILD
output=$OUT
image=$ARTIFACT/Image
initramfs=$ARTIFACT/initramfs
kernel_append=$KERNEL_APPEND
jobs=$JOBS
cpu_bind=$CPU_BIND
EOF
cp "$ARTIFACT/manifest.txt" "$PUBLISHED/manifest.txt"

echo "PASS: Linux lite Image/initramfs 已生成"
echo "  Image:    $PUBLISHED/Image"
echo "  initramfs: $PUBLISHED/initramfs"
echo "  config:   $OUT/.config"
