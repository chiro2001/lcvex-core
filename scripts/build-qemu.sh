#!/usr/bin/env bash
# 构建固定版本 QEMU（../qemu，aarch64-softmmu + plugins，无文档）。
# 幂等：build/qemu-system-aarch64 存在且较新时跳过。
# 用法：scripts/build-qemu.sh [QEMU_DIR]
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
QEMU_DIR="${1:-$REPO_ROOT/../qemu}"

if [[ ! -d "$QEMU_DIR/.git" ]]; then
  echo "错误：$QEMU_DIR 不是 QEMU fork，先运行 qemu/scripts/apply-patches.sh" >&2
  exit 1
fi

if [[ -x "$QEMU_DIR/build/qemu-system-aarch64" ]] &&
   [[ "$QEMU_DIR/build/qemu-system-aarch64" -nt "$QEMU_DIR/configure" ]]; then
  echo "OK   QEMU 已构建：$QEMU_DIR/build/qemu-system-aarch64"
  exit 0
fi

echo "==> 配置 QEMU（aarch64-softmmu + plugins）"
mkdir -p "$QEMU_DIR/build"
cd "$QEMU_DIR/build"
"$QEMU_DIR/configure" --target-list=aarch64-softmmu --enable-plugins \
  --disable-docs --prefix="$QEMU_DIR/build/install"
echo "==> 构建 QEMU（多核）"
make -j"$(nproc)"
echo "OK   QEMU 构建完成：$QEMU_DIR/build/qemu-system-aarch64"
