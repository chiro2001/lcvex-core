#!/usr/bin/env bash
# 工具链版本检查：与 env/environment.yml、docs/TOOLCHAIN.md 保持一致。
# 任一固定版本不匹配即退出非零，供本地和 CI 使用。
set -euo pipefail

CONDA_ENV="${CONDA_ENV:-lcvex}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

if command -v conda >/dev/null 2>&1; then
  run() { conda run --no-capture-output -n "$CONDA_ENV" "$@"; }
else
  run() { "$@"; }
fi

fail=0
check_version() {
  local name="$1" expect="$2" actual="$3"
  if [[ "$actual" == *"$expect"* ]]; then
    echo "OK   $name: $actual"
  else
    echo "FAIL $name: 期望 $expect，实际 $actual" >&2
    fail=1
  fi
}

check_version "verilator" "Verilator 5.050" "$(run verilator --version)"
check_version "cocotb"    "2.0.1"          "$(run cocotb-config --version)"
check_version "python"    "Python 3.12"    "$(run python --version)"
check_version "make"      "GNU Make"       "$(run make --version | head -1)"

# QEMU 固定版本记录必须存在
if [[ -f "$REPO_ROOT/qemu/VERSION" ]]; then
  echo "OK   qemu: $(grep '^QEMU_VERSION=' "$REPO_ROOT/qemu/VERSION")"
else
  echo "FAIL qemu/VERSION 缺失" >&2
  fail=1
fi

# 本地 QEMU fork（../qemu）存在时校验 HEAD 与固定版本一致
QEMU_DIR="${QEMU_DIR:-$REPO_ROOT/../qemu}"
if [[ -d "$QEMU_DIR/.git" ]]; then
  actual="$(git -C "$QEMU_DIR" rev-parse HEAD)"
  expected="$(grep '^QEMU_COMMIT=' "$REPO_ROOT/qemu/VERSION" | cut -d= -f2)"
  if [[ "$actual" == "$expected" ]]; then
    echo "OK   qemu fork: $actual"
  else
    echo "FAIL qemu fork HEAD $actual != $expected" >&2
    fail=1
  fi
else
  echo "WARN qemu fork 未克隆（$QEMU_DIR），P1 前运行 qemu/scripts/apply-patches.sh"
fi

# 交叉工具链：toolcheck 与 scripts/build-baremetal.sh 使用同一组
# aarch64-linux-gnu-gcc / aarch64-linux-gnu-objcopy 前缀；AARCH64_GCC
# 覆盖时会同步推导 objcopy，也可用 AARCH64_OBJCOPY 显式覆盖。
# 该工具链是发布模式 Gate D 的必需项；此处保持 WARN，避免非 Gate 开发被硬断。
AARCH64_GCC="${AARCH64_GCC:-aarch64-linux-gnu-gcc}"
if [[ -n "${AARCH64_OBJCOPY:-}" ]]; then
  AARCH64_OBJCOPY="$AARCH64_OBJCOPY"
elif [[ "$AARCH64_GCC" == *gcc ]]; then
  AARCH64_OBJCOPY="${AARCH64_GCC%gcc}objcopy"
else
  AARCH64_OBJCOPY=""
fi

if command -v "$AARCH64_GCC" >/dev/null 2>&1; then
  echo "OK   aarch64 gcc: $AARCH64_GCC ($($AARCH64_GCC --version | head -1))"
else
  echo "WARN aarch64 gcc 未安装：$AARCH64_GCC（Gate D 发布模式需要）" >&2
fi
if [[ -n "$AARCH64_OBJCOPY" ]] && command -v "$AARCH64_OBJCOPY" >/dev/null 2>&1; then
  echo "OK   aarch64 objcopy: $AARCH64_OBJCOPY ($($AARCH64_OBJCOPY --version | head -1))"
else
  echo "WARN aarch64 objcopy 未安装/未推导：${AARCH64_OBJCOPY:-<未设置>}（Gate D 发布模式需要）" >&2
fi

exit "$fail"
