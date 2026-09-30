#!/usr/bin/env bash
# SCTLR_EL1 PAuth 脏 sys sidecar 联合恢复 smoke：
#
# 1) hard_sctlr_pauth 在 MSR SCTLR_EL1 提交后保存 checkpoint；下一条是 MRS；
# 2) 原始 QEMU vmstate/RAM/sys 均保持不变，仅复制 DUT 使用的 sys sidecar；
# 3) 按 sidecar 的实际 SYS_STATE_V1/V2/V3 布局，将 EnIA/EnIB/EnDA/EnDB
#    (0xc8002000) 注入该副本；
# 4) QEMU 由原始 vmstate incoming，DUT 由脏 sys 副本恢复，MRS 及后一条
#    普通提交仍必须严格锁步。
#
# 脏副本和 capture 链只存在于自动清理的 build/tmp/t047.XXXXXX 中，
# 不写 manifest，也绝不能作为可发布 checkpoint artifact。
set -euo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
QEMU_BIN="${QEMU_BIN:-$REPO/../qemu/build/qemu-system-aarch64}"
COORD="${COORD:-$REPO/build/verilator_lockstep/lockstep_coordinator}"
PLUGIN="${PLUGIN:-$REPO/qemu/plugins/lcvex_difftest.so}"
IMAGE="${IMAGE:-$REPO/build/difftest/hard_sctlr_pauth.bin}"
PYTHON="${PYTHON:-python3}"
CHECKPOINT_TOOL="$REPO/sim/difftest/checkpoint.py"
CAPTURE_COORD_PIN="${CAPTURE_COORD_PIN:-0}"
CAPTURE_QEMU_PIN="${CAPTURE_QEMU_PIN:-1}"
RESTORE_COORD_PIN="${RESTORE_COORD_PIN:-0}"
RESTORE_QEMU_PIN="${RESTORE_QEMU_PIN:-1}"
CAPTURE_SEQ=2
PAuth_MASK=0xc8002000
ORIGINAL_SCTLR=0x00c50838
DIRTY_SCTLR=0xc8c52838
MSR_SCTLR_PC=0x0000000044000008
MSR_SCTLR_INSN=0xd5181000
MRS_SCTLR_PC=0x000000004400000c
MRS_SCTLR_INSN=0xd5381001

for f in "$QEMU_BIN" "$COORD" "$PLUGIN" "$IMAGE" "$CHECKPOINT_TOOL"; do
  if [[ ! -f "$f" ]]; then
    echo "错误：找不到 $f" >&2
    exit 1
  fi
done

mkdir -p "$REPO/build/tmp"
# 保持 socket 路径在 AF_UNIX 108 字节限制以内。
RUN_DIR="$(mktemp -d "$REPO/build/tmp/t047.XXXXXX")"
COORD_PID=""
QEMU_PID=""

stop_pid() {
  local pid="${1:-}"
  [[ -z "$pid" ]] && return 0
  if kill -0 "$pid" 2>/dev/null; then
    kill -TERM "$pid" 2>/dev/null || true
    for _ in $(seq 1 40); do
      kill -0 "$pid" 2>/dev/null || break
      sleep 0.05
    done
    if kill -0 "$pid" 2>/dev/null; then
      kill -KILL "$pid" 2>/dev/null || true
    fi
  fi
  wait "$pid" 2>/dev/null || true
}

cleanup() {
  stop_pid "$QEMU_PID"
  stop_pid "$COORD_PID"
  # 仅删除由本 smoke 创建、名称固定的临时根，绝不清理共享 build 目录。
  find "$RUN_DIR" -mindepth 1 -delete 2>/dev/null || true
  rmdir "$RUN_DIR" 2>/dev/null || true
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM

run_pinned() {
  local pin="$1"
  shift
  if [[ -n "$pin" ]]; then
    # exec 使后台 $! 对应真实 taskset/QEMU 或 coordinator 进程，trap 可回收它。
    exec taskset -c "$pin" "$@"
  fi
  exec "$@"
}

CKPT_DIR="$RUN_DIR/chain"
mkdir -p "$CKPT_DIR"

# 第三条提交（seq=2）是 MSR SCTLR_EL1；保存后 checkpoint 的 next_pc 必为 MRS。
# capture 采用标准锁步入口，以原始 QEMU sidecar/vmstate/RAM 建立基线。
IMAGE="$IMAGE" DIFF_CKPT=1 CKPT_EVERY=3 CKPT_DIR="$CKPT_DIR" \
  RAM_FILE="$CKPT_DIR/ram-backend.bin" MAX_INSNS=6 PROGRESS_EVERY=0 \
  COORD_PIN="$CAPTURE_COORD_PIN" QEMU_PIN="$CAPTURE_QEMU_PIN" \
  bash "$REPO/sim/difftest/run_lockstep_step.sh" \
  >"$RUN_DIR/capture.log" 2>&1

RECORD="$(awk -F '\t' -v seq="$CAPTURE_SEQ" '$2 == seq {print; exit}' \
  "$CKPT_DIR/manifest.tsv")"
if [[ -z "$RECORD" ]]; then
  echo "FAIL: 未捕获 seq=$CAPTURE_SEQ 的 MSR SCTLR checkpoint" >&2
  exit 1
fi
MANIFEST_JSON="$CKPT_DIR/manifest.json"
MANIFEST_TSV="$CKPT_DIR/manifest.tsv"
if [[ ! -f "$MANIFEST_JSON" || ! -f "$MANIFEST_TSV" ]]; then
  echo "FAIL: capture 未发布 finalized manifest" >&2
  exit 1
fi
MANIFEST_JSON_SHA="$(sha256sum "$MANIFEST_JSON" | awk '{print $1}')"
MANIFEST_TSV_SHA="$(sha256sum "$MANIFEST_TSV" | awk '{print $1}')"
read -r ARCH_PC ARCH_INSN ARCH_NEXT_PC <<<"$("$PYTHON" "$CHECKPOINT_TOOL" read-arch \
  --chain "$CKPT_DIR" --seq "$CAPTURE_SEQ" | "$PYTHON" -c \
  'import json,sys; d=json.load(sys.stdin); print("0x%016x" % d["pc"], "0x%08x" % d["insn"], "0x%016x" % d["next_pc"])')"
if [[ "$ARCH_PC" != "$MSR_SCTLR_PC" || "$ARCH_INSN" != "$MSR_SCTLR_INSN" || \
      "$ARCH_NEXT_PC" != "$MRS_SCTLR_PC" ]]; then
  echo "FAIL: seq=$CAPTURE_SEQ arch 不是 MSR SCTLR：pc=$ARCH_PC insn=$ARCH_INSN next_pc=$ARCH_NEXT_PC" >&2
  exit 1
fi
MRS_WORD="$("$PYTHON" - "$IMAGE" "$MRS_SCTLR_PC" "$MRS_SCTLR_INSN" <<'PY'
import sys
from pathlib import Path

image = Path(sys.argv[1]).read_bytes()
pc = int(sys.argv[2], 0)
expected = int(sys.argv[3], 0)
base = 0x44000000
off = pc - base
if off < 0 or off + 4 > len(image):
    raise SystemExit(f"FAIL: MRS PC 0x{pc:x} 不在镜像内")
word = int.from_bytes(image[off:off + 4], "little")
if word != expected:
    raise SystemExit(f"FAIL: 镜像 0x{pc:x}=0x{word:08x}，不是 MRS SCTLR")
print(f"0x{word:08x}")
PY
)"
if [[ "$MRS_WORD" != "$MRS_SCTLR_INSN" ]]; then
  echo "FAIL: 镜像 MRS 编码读取异常：$MRS_WORD" >&2
  exit 1
fi
DEV_GZ="$(printf '%s\n' "$RECORD" | cut -f7)"
SYS_GZ="$(printf '%s\n' "$RECORD" | cut -f9)"
TIMER_GZ="$(printf '%s\n' "$RECORD" | cut -f10)"
GIC_GZ="$(printf '%s\n' "$RECORD" | cut -f11)"
for f in "$DEV_GZ" "$SYS_GZ" "$TIMER_GZ" "$GIC_GZ"; do
  if [[ ! -f "$f" ]]; then
    echo "FAIL: 保存点 sidecar 缺失：$f" >&2
    exit 1
  fi
done

RAM="$RUN_DIR/original.ram"
DEV_RAW="$RUN_DIR/original.dev"
TIMER_RAW="$RUN_DIR/original.timer"
DIRTY_SYS_GZ="$RUN_DIR/dut-sctlr-dirty.sys.gz"
SYS_RAW="$RUN_DIR/dut-sctlr-dirty.sys"
"$PYTHON" "$CHECKPOINT_TOOL" restore-ram --chain "$CKPT_DIR" \
  --seq "$CAPTURE_SEQ" --output "$RAM" >/dev/null
gzip -cd "$DEV_GZ" >"$DEV_RAW"
gzip -cd "$TIMER_GZ" >"$TIMER_RAW"

# 先逐字段验证原始 QEMU sys sidecar；然后复制其 gzip 文件，脏化副本。原链、
# manifest、QEMU incoming dev state 与 RAM 均不会被修改。
read -r ORIGINAL_VALUE ORIGINAL_NEXT_PC <<<"$("$PYTHON" "$CHECKPOINT_TOOL" read-sys \
  --chain "$CKPT_DIR" --seq "$CAPTURE_SEQ" | "$PYTHON" -c \
  'import json,sys; d=json.load(sys.stdin); print("0x%08x" % d["sctlr_el1"], "0x%016x" % d["next_pc"])')"
if [[ "$ORIGINAL_VALUE" != "$ORIGINAL_SCTLR" ]]; then
  echo "FAIL: 原始 QEMU sys SCTLR=$ORIGINAL_VALUE，期望 $ORIGINAL_SCTLR" >&2
  exit 1
fi
if [[ "$ORIGINAL_NEXT_PC" != "$MRS_SCTLR_PC" ]]; then
  echo "FAIL: 保存点 next_pc=$ORIGINAL_NEXT_PC，不是预期的 MRS SCTLR PC=$MRS_SCTLR_PC" >&2
  exit 1
fi
cp "$SYS_GZ" "$DIRTY_SYS_GZ"
gzip -cd "$DIRTY_SYS_GZ" >"$SYS_RAW"
"$PYTHON" - "$REPO" "$SYS_RAW" "$PAuth_MASK" "$ORIGINAL_SCTLR" "$DIRTY_SCTLR" <<'PY'
import sys
from pathlib import Path

repo = Path(sys.argv[1])
raw_path = Path(sys.argv[2])
mask = int(sys.argv[3], 0)
expected_original = int(sys.argv[4], 0)
expected_dirty = int(sys.argv[5], 0)
sys.path.insert(0, str(repo / "sim" / "difftest"))
import checkpoint

raw = raw_path.read_bytes()
layouts = (
    (checkpoint.SYS_STATE, b"LCVXSYS1", 1),
    (checkpoint.SYS_STATE_V2, b"LCVXSYS2", 2),
    (checkpoint.SYS_STATE_V3, b"LCVXSYS3", 3),
)
for layout, magic, version in layouts:
    if len(raw) != layout.size:
        continue
    values = list(layout.unpack(raw))
    if values[:3] != [magic, version, layout.size]:
        raise SystemExit("FAIL: SYS_STATE header 与实际 struct 不匹配")
    # header 后为 31 GPR，随后 25 个 QWORD；q[9] 即 SCTLR_EL1。
    sctlr_index = 3 + 31 + 9
    original = values[sctlr_index]
    if original != expected_original:
        raise SystemExit(f"FAIL: 原始 sidecar SCTLR=0x{original:08x}")
    dirty = original | mask
    if dirty != expected_dirty:
        raise SystemExit(f"FAIL: 脏 sidecar SCTLR=0x{dirty:08x}")
    values[sctlr_index] = dirty
    raw_path.write_bytes(layout.pack(*values))
    print(f"OK: {magic.decode()} 原始 SCTLR=0x{original:08x} 脏 SCTLR=0x{dirty:08x}")
    break
else:
    raise SystemExit(f"FAIL: 未识别的 SYS_STATE 长度 {len(raw)}")
PY
gzip -n -c "$SYS_RAW" >"$DIRTY_SYS_GZ.tmp"
mv "$DIRTY_SYS_GZ.tmp" "$DIRTY_SYS_GZ"

ORIGINAL_DEV_SHA="$(sha256sum "$DEV_RAW" | awk '{print $1}')"
ORIGINAL_RAM_SHA="$(sha256sum "$RAM" | awk '{print $1}')"
ORIGINAL_SYS_SHA="$(sha256sum "$SYS_GZ" | awk '{print $1}')"

SOCK="$RUN_DIR/step.sock"
if (( ${#SOCK} >= 108 )); then
  echo "FAIL: socket 路径过长：$SOCK" >&2
  exit 1
fi

# 不传 --restore-arch：协调器只从脏 SYS sidecar 恢复 DUT 的架构/system
# 状态。QEMU 则只消费未篡改的 original.dev incoming 状态和原始 RAM。
run_pinned "$RESTORE_COORD_PIN" "$COORD" --socket "$SOCK" \
  --image "$IMAGE" --base 0x44000000 \
  --restore-sys "$DIRTY_SYS_GZ" \
  --restore-timer "$TIMER_GZ" --restore-gic "$GIC_GZ" \
  --restore-ram "$RAM" --max-insns 2 --progress-every 0 \
  --timeout-ms 30000 --dump "$RUN_DIR/fail.txt" \
  >"$RUN_DIR/coord.log" 2>&1 &
COORD_PID=$!
for _ in $(seq 1 300); do
  [[ -S "$SOCK" ]] && break
  if ! kill -0 "$COORD_PID" 2>/dev/null; then
    cat "$RUN_DIR/coord.log" >&2 || true
    exit 1
  fi
  sleep 0.01
done
if [[ ! -S "$SOCK" ]]; then
  echo "FAIL: coordinator 未创建 socket" >&2
  cat "$RUN_DIR/coord.log" >&2 || true
  exit 1
fi

run_pinned "$RESTORE_QEMU_PIN" env LCVEX_DIFFTEST_STEP=1 \
  LCVEX_TIMER_RESTORE_PATH="$TIMER_RAW" "$QEMU_BIN" \
  -machine virt -cpu max,has_el3=false,has_el2=false \
  -accel tcg,thread=single,tb-size=64 -icount shift=0,align=off,sleep=off \
  -display none -incoming "exec:cat $DEV_RAW" \
  -object "memory-backend-file,id=lcvexram,size=128M,mem-path=$RAM,share=on" \
  -machine memory-backend=lcvexram \
  -plugin "file=$PLUGIN,mode=step,socket=$SOCK" \
  >"$RUN_DIR/qemu.log" 2>&1 &
QEMU_PID=$!

set +e
wait "$COORD_PID"
RC=$?
set -e
COORD_PID=""
if [[ $RC -ne 0 ]]; then
  cat "$RUN_DIR/coord.log" >&2 || true
  cat "$RUN_DIR/qemu.log" >&2 || true
  exit "$RC"
fi

if [[ "$(sha256sum "$DEV_RAW" | awk '{print $1}')" != "$ORIGINAL_DEV_SHA" || \
      "$(sha256sum "$RAM" | awk '{print $1}')" != "$ORIGINAL_RAM_SHA" || \
      "$(sha256sum "$SYS_GZ" | awk '{print $1}')" != "$ORIGINAL_SYS_SHA" ]]; then
  echo "FAIL: 原始 QEMU vmstate/RAM/sys 被意外修改" >&2
  exit 1
fi
if [[ "$(sha256sum "$MANIFEST_JSON" | awk '{print $1}')" != "$MANIFEST_JSON_SHA" || \
      "$(sha256sum "$MANIFEST_TSV" | awk '{print $1}')" != "$MANIFEST_TSV_SHA" ]] || \
      grep -Fq -- "$DIRTY_SYS_GZ" "$MANIFEST_JSON" "$MANIFEST_TSV"; then
  echo "FAIL: finalized manifest 被修改或引用了脏 SYS 副本" >&2
  exit 1
fi
echo "PASS: seq=$CAPTURE_SEQ（MSR=$ARCH_INSN @ $ARCH_PC，next_pc=$ORIGINAL_NEXT_PC，镜像 MRS=$MRS_WORD）后原始 QEMU SCTLR=$ORIGINAL_VALUE，DUT 脏 SYS=$DIRTY_SCTLR；MRS SCTLR 与后续提交严格锁步"
