#!/usr/bin/env bash
# 编译 LCVEX microbench / perf 裸机镜像。
#
# 用法：
#   scripts/build-microbench.sh [OUT_BIN]
#     - 默认构建全部 baremetal/tests/t_*.c + microbench_main.c + startup_mb.s，
#       输出 build/microbench/mb_all.bin（保持原 mb_all 行为）。
#   PERF_ONLY=<name> scripts/build-microbench.sh [OUT_BIN]
#     - 构建 baremetal/perf/t_<name>.c 对应的单个性能 workload，
#       默认输出 build/microbench/perf_<name>.bin。
#     - <name> 可写 smoke 或 t_smoke.c（脚本自动规范化）；name 必须是合法 C 标识符。
#   MB_ONLY=<name> scripts/build-microbench.sh [OUT_BIN]
#     - 保留原有功能微基准单测筛选。

set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
CC="${AARCH64_GCC:-aarch64-linux-gnu-gcc}"
OUT="${1:-$REPO/build/microbench/mb_all.bin}"
PERF_ONLY="${PERF_ONLY:-}"
MB_ONLY="${MB_ONLY:-}"
PERF_CFLAGS="${PERF_CFLAGS:--O2}"

if ! command -v "$CC" >/dev/null 2>&1; then
  echo "错误：找不到交叉工具链 $CC（microbench 依赖；安装 aarch64-linux-gnu-gcc）" >&2
  exit 2
fi

# 统一把相对输出路径按仓库根目录解释，避免 cd 后写到错误位置。
if [[ "$OUT" != /* ]]; then
  OUT="$REPO/$OUT"
fi

mkdir -p "$REPO/build/microbench"
cd "$REPO/build/microbench"

if [[ -n "$PERF_ONLY" ]]; then
  # ---- 性能 workload 单测构建 ----
  PERF_BASE="${PERF_ONLY#t_}"
  PERF_BASE="${PERF_BASE%.c}"
  PERF_SRC="$REPO/baremetal/perf/t_${PERF_BASE}.c"
  if [[ ! -f "$PERF_SRC" ]]; then
    echo "错误：找不到 perf 源文件 $PERF_SRC（PERF_ONLY=$PERF_ONLY）" >&2
    exit 2
  fi
  if [[ "$OUT" == "$REPO/build/microbench/mb_all.bin" ]]; then
    OUT="$REPO/build/microbench/perf_${PERF_BASE}.bin"
  fi

  # perf workload 编译允许 FP/NEON，因此不传 -mgeneral-regs-only。
  # 只有明确需要 FP/NEON 的 workload 才保留 FP 寄存器；其余纯整数
  # workload 加 -mgeneral-regs-only，避免编译器在 CPACR 未使能前生成
  # Q/D 寄存器栈拷贝而触发 FP access 异常/挂起。
  PERF_FP_NAMES="fp_scalar fp_fp16 neon_vect"
  PERF_NEEDS_FP=0
  for _pfn in $PERF_FP_NAMES; do
    if [[ "$PERF_BASE" == "$_pfn" ]]; then
      PERF_NEEDS_FP=1
      break
    fi
  done
  if [[ "$PERF_NEEDS_FP" -eq 0 ]]; then
    PERF_CFLAGS="$PERF_CFLAGS -mgeneral-regs-only"
  fi
  # PERF_CFLAGS 可供具体 workload 覆盖（如 -march=armv8.2-a+fp16）。
  "$CC" $PERF_CFLAGS -ffreestanding -nostdlib -nostartfiles -mabi=lp64 \
    -I"$REPO/baremetal" -I"$REPO/baremetal/perf" \
    -c "$PERF_SRC" -o perf_test.o
  "$CC" $PERF_CFLAGS -ffreestanding -nostdlib -nostartfiles -mabi=lp64 \
    -I"$REPO/baremetal" -I"$REPO/baremetal/perf" \
    -DPERF_ONLY="$PERF_BASE" \
    -c "$REPO/baremetal/microbench_main.c" -o main.o
  OBJS=(perf_test.o)
elif [[ -n "$MB_ONLY" ]]; then
  # ---- 原功能微基准单测构建：MB_ONLY=csel ----
  "$CC" -O2 -ffreestanding -nostdlib -nostartfiles -mabi=lp64 \
    -mgeneral-regs-only -I"$REPO/baremetal" -DMB_ONLY="$MB_ONLY" \
    -c "$REPO/baremetal/microbench_main.c" -o main.o
  "$CC" -O2 -ffreestanding -nostdlib -nostartfiles -mabi=lp64 \
    -mgeneral-regs-only -I"$REPO/baremetal" \
    -c "$REPO/baremetal/tests/t_${MB_ONLY}.c" -o test.o
  OBJS=(test.o)
else
  # ---- 原全量 mb_all 构建 ----
  OBJS=()
  for src in "$REPO"/baremetal/tests/t_*.c; do
    o="$(basename "${src%.c}").o"
    "$CC" -O2 -ffreestanding -nostdlib -nostartfiles -mabi=lp64 \
      -mgeneral-regs-only -I"$REPO/baremetal" -c "$src" -o "$o"
    OBJS+=("$o")
  done
  "$CC" -O2 -ffreestanding -nostdlib -nostartfiles -mabi=lp64 \
    -mgeneral-regs-only -I"$REPO/baremetal" \
    -c "$REPO/baremetal/microbench_main.c" -o main.o
fi

"$CC" -O2 -ffreestanding -nostdlib -mabi=lp64 \
  -c "$REPO/baremetal/startup_mb.s" -o startup.o
"$CC" -nostdlib -T "$REPO/baremetal/link.ld" \
  -o mb.elf startup.o main.o "${OBJS[@]}"
aarch64-linux-gnu-objcopy -O binary mb.elf "$OUT"

if [[ -n "$PERF_ONLY" ]]; then
  echo "==> perf 镜像：$OUT（$PERF_BASE，$(stat -c%s "$OUT") 字节）"
else
  echo "==> microbench 镜像：$OUT（$(stat -c%s "$OUT") 字节，$(ls "${OBJS[@]}" main.o | wc -l) 个测试目标）"
fi
