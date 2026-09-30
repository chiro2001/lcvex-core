#!/usr/bin/env bash
# 构建 LCVEX 裸机 C 测试镜像（M3：交叉工具链）。
#
# 用法：scripts/build-baremetal.sh [OUT_BIN]
# 默认输出 build/difftest/bm_c.bin；工具链缺失时退出码 2。

set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
CC="${AARCH64_GCC:-aarch64-linux-gnu-gcc}"
# AARCH64_GCC 覆盖时同步推导同前缀 objcopy，也可用 AARCH64_OBJCOPY 显式覆盖。
if [[ -n "${AARCH64_OBJCOPY:-}" ]]; then
  OBJCOPY="$AARCH64_OBJCOPY"
elif [[ "$CC" == *gcc ]]; then
  OBJCOPY="${CC%gcc}objcopy"
else
  echo "错误：无法从 AARCH64_GCC=$CC 推导 objcopy；请设置 AARCH64_OBJCOPY" >&2
  exit 2
fi
OUT="${1:-$REPO/build/difftest/bm_c.bin}"

if ! command -v "$CC" >/dev/null 2>&1; then
  echo "错误：找不到交叉工具链 $CC（M3 依赖；安装 aarch64-linux-gnu-gcc）" >&2
  exit 2
fi
if ! command -v "$OBJCOPY" >/dev/null 2>&1; then
  echo "错误：找不到交叉 objcopy $OBJCOPY（M3 依赖；安装 binutils-aarch64-linux-gnu）" >&2
  exit 2
fi

mkdir -p "$REPO/build/difftest" "$REPO/build/baremetal"
cd "$REPO/build/baremetal"

"$CC" -O2 -ffreestanding -nostdlib -nostartfiles -mabi=lp64 \
  -mgeneral-regs-only \
  -c "$REPO/baremetal/main.c" -o main.o
"$CC" -O2 -ffreestanding -nostdlib -mabi=lp64 \
  -c "$REPO/baremetal/startup.s" -o startup.o
"$CC" -nostdlib -T "$REPO/baremetal/link.ld" \
  -o bm.elf startup.o main.o
"$OBJCOPY" -O binary bm.elf "$OUT"
echo "==> 裸机镜像：$OUT（$(stat -c%s "$OUT") 字节）"
