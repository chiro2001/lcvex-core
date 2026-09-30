#!/usr/bin/env bash
# PR-fast 门禁：无需 QEMU 的快速检查。
# 覆盖：toolcheck / RTL lint / SV smoke / 提交背压 / 内存接口单元 /
#       Cocotb ALU / regfile / 背压。
# 用法：scripts/ci-fast.sh [--keep-logs]
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

CONDA_ENV="${CONDA_ENV:-lcvex}"
RUN() { conda run --no-capture-output -n "$CONDA_ENV" "$@"; }

LOG_DIR="${LOG_DIR:-build/ci-fast}"
mkdir -p "$LOG_DIR"

steps=(
  "toolcheck:make toolcheck"
  "lint:make compile"
  "sim-sv:make sim-sv"
  "backpressure-sv:make sim-sv-backpressure"
  "memif-sv:make sim-sv-memif"
  "cocotb-alu:make sim-cocotb"
  "cocotb-regfile:make sim-cocotb-regfile"
  "cocotb-backpressure:make sim-cocotb-backpressure"
)

fail=0
for entry in "${steps[@]}"; do
  name="${entry%%:*}"
  cmd="${entry#*:}"
  echo "===== [$name] $cmd ====="
  if eval "$cmd" >"$LOG_DIR/$name.log" 2>&1; then
    echo "PASS $name"
  else
    echo "FAIL $name（日志 $LOG_DIR/$name.log）" >&2
    tail -20 "$LOG_DIR/$name.log" >&2
    fail=1
  fi
done

if [[ $fail -eq 0 ]]; then
  echo "PASS: PR-fast 门禁全部通过（日志 $LOG_DIR/）"
else
  echo "FAIL: PR-fast 门禁有失败项" >&2
  exit 1
fi
