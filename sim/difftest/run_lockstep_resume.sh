#!/usr/bin/env bash
# P6 kernel 锁步续跑：从差分 checkpoint 链的 seq 恢复 QEMU（-incoming
# device vmstate + RAM）与 DUT（arch/sys/timer/gic sidecar 注入），
# 继续逐指令锁步到 max_insns。
#
# 用法：
#   CHAIN=build/difftest/xxx/chain RESUME_SEQ=9999999 \
#     MAX_INSNS=4800000 bash sim/difftest/run_lockstep_resume.sh
#
# 环境变量：
#   CHAIN         checkpoint 链目录（manifest.tsv 所在目录）
#   RESUME_SEQ    从链中哪个 seq 恢复（默认取链最后一条）
#   IMAGE         Linux Image（默认 /tmp/Image-t80000，须与链 manifest 一致）
#   INITRD        可选 initramfs（lite 线）；主线恢复留空
#   DTB           QEMU 实际加载的 FDT（默认 build/difftest/qemu-fdt-raw.bin）
#   MAX_INSNS     本次续跑提交条数（0=不限，默认 4800000，即总 ~14.8M）
#   CKPT_EVERY    续跑过程中每 N 条保存新 checkpoint（0=关闭，默认 0）
#   CKPT_DIR      新 checkpoint 输出目录（默认 $RUN_DIR/chain）
#   RESTORE_SMCR  诊断 override：仅在确认 QEMU 保存点 SMCR 值后使用
#                 （缺省留空；v1 链的 SMCR 按 0 恢复，QEMU 在 SVE/SME
#                 探测前 SMCR_EL1=0，旧 0xf 假设经 DBG 实证为错误）
#   PIN           兼容旧入口：同时绑定协调器/QEMU 的物理核（默认 0）
#   COORD_PIN     协调器独立物理核；未设置时回退 PIN
#   QEMU_PIN      QEMU 独立物理核；未设置时回退 PIN
#   TIMEOUT_MS    协调器单次 socket 等待超时（默认 120000；诊断短跑可调小）
#   MAX_CYCLES_PER_INSN  DUT 单条指令最大仿真周期（默认 1000；诊断短跑可调小）
#   MAX_WAIT_CYCLES WFI/WFE/WFIT/WFET 后恢复下一条所允许的 DUT 周期上限
#                   （默认 1000000；仅等待指令使用，不放宽普通指令）
#   QEMU_DEBUG    可选 QEMU `-d` 类别（例如 in_asm,exec），日志写入运行目录
#   SKIP_TIMER_RESTORE 诊断开关（1=不注入 timer offset，默认 0）
#   FP_NEON       P7 restore 模式（off|required；required 要求 manifest 第13列）
#   LCVEX_TMP_DIR      运行期未压缩 RAM/设备 sidecar 目录（默认 build/tmp）
#   KEEP_RESTORE_WORK  1=保留上述可重建的未压缩文件（默认 0）
set -euo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
QEMU_BIN="${QEMU_BIN:-$REPO/../qemu/build/qemu-system-aarch64}"
COORD="${COORD:-$REPO/build/verilator_lockstep_kernel/lockstep_coordinator}"
PLUGIN="${PLUGIN:-$REPO/qemu/plugins/lcvex_difftest.so}"
QEMU_VERSION="${QEMU_VERSION:-$REPO/qemu/VERSION}"
CHECKPOINT_TOOL="$REPO/sim/difftest/checkpoint.py"
IMAGE="${IMAGE:-/tmp/Image-t80000}"
INITRD="${INITRD:-}"
BOOT_DTB="${BOOT_DTB:-0x44000000}"
BOOT_ENTRY="${BOOT_ENTRY:-0x40080000}"
DTB="${DTB:-$REPO/build/difftest/qemu-fdt-raw.bin}"
CHAIN="${CHAIN:?错误：需要 CHAIN=<checkpoint 链目录>}"
RESUME_SEQ="${RESUME_SEQ:-}"
MAX_INSNS="${MAX_INSNS:-4800000}"
CKPT_EVERY="${CKPT_EVERY:-0}"
CKPT_DIR="${CKPT_DIR:-}"
MACHINE_CONTEXT="${MACHINE_CONTEXT:-virt,gic-version=2,dtb-randomness=off,memory-backend=lcvexram}"
ICOUNT_CONTEXT="${ICOUNT_CONTEXT:-shift=0,align=off,sleep=off}"
RESTORE_SMCR="${RESTORE_SMCR:-}"
PIN="${PIN:-0}"
COORD_PIN="${COORD_PIN-$PIN}"
QEMU_PIN="${QEMU_PIN-$PIN}"
KERNEL_APPEND="${KERNEL_APPEND:-console=ttyAMA0,115200 earlycon=pl011,0x09000000 rdinit=/bin/sh nokaslr panic=-1}"
# P6 标量目标不实现 ARMv8.3-A PAuth；默认保持历史 max 配置，必要时
# 用 QEMU_CPU=max,pauth=off,... 与 DUT 的 PAC HINT=NOP 语义对齐。
QEMU_CPU_INPUT="${QEMU_CPU-}"
QEMU_CPU="${QEMU_CPU:-max,has_el3=false,has_el2=false}"
FP_NEON="${FP_NEON:-off}"
case "$FP_NEON" in
  off|required) ;;
  *) echo "错误：FP_NEON 只接受 off|required" >&2; exit 2 ;;
esac
if [[ "$FP_NEON" == "required" && -z "$QEMU_CPU_INPUT" ]]; then
  QEMU_CPU="cortex-a76,cntfrq=1000000000,has_el3=false,has_el2=false"
fi
if [[ "$FP_NEON" == "required" && ( "$QEMU_CPU" == max || "$QEMU_CPU" == max,* ) ]]; then
  echo "错误：P7 resume 禁止使用 max adapter checkpoint" >&2
  exit 2
fi
if [[ "$FP_NEON" == "required" && "$QEMU_CPU" != cortex-a76,* ]]; then
  echo "错误：P7 resume 的 QEMU_CPU 必须是 cortex-a76 profile" >&2
  exit 2
fi
if [[ "$FP_NEON" == "required" && "$QEMU_CPU" != *"cntfrq=1000000000"* ]]; then
  echo "错误：P7 resume 的 QEMU_CPU 必须显式包含 cntfrq=1000000000" >&2
  exit 2
fi
PROGRESS_EVERY="${PROGRESS_EVERY:-50000}"
TIMEOUT_MS="${TIMEOUT_MS:-120000}"
MAX_CYCLES_PER_INSN="${MAX_CYCLES_PER_INSN:-1000}"
MAX_WAIT_CYCLES="${MAX_WAIT_CYCLES:-1000000}"
QEMU_DEBUG="${QEMU_DEBUG:-}"
SKIP_TIMER_RESTORE="${SKIP_TIMER_RESTORE:-0}"
TMP_ROOT="${LCVEX_TMP_DIR:-$REPO/build/tmp}"
KEEP_RESTORE_WORK="${KEEP_RESTORE_WORK:-0}"

for f in "$QEMU_BIN" "$QEMU_VERSION" "$COORD" "$PLUGIN" "$IMAGE" "$DTB"; do
  if [[ ! -f "$f" ]]; then
    echo "错误：找不到 $f" >&2
    exit 1
  fi
done
if [[ -n "$INITRD" && ! -f "$INITRD" ]]; then
  echo "错误：找不到 INITRD=$INITRD" >&2
  exit 1
fi
if [[ ! -f "$CHAIN/manifest.tsv" ]]; then
  echo "错误：$CHAIN/manifest.tsv 不存在" >&2
  exit 1
fi

mkdir -p "$TMP_ROOT"
# AF_UNIX sun_path 最多 108 字节（含 NUL）。checkpoint 调用方通常已把
# LCVEX_TMP_DIR 设为带日期的较深 build/tmp 路径，故运行目录必须保持短名，
# 否则 QEMU/协调器会各自静默截断到不同 socket 名而永久等待。
RUN_DIR="$(mktemp -d "$TMP_ROOT/r.XXXXXX")"
COORD_PID=""
QEMU_PID=""
FP_RAW=""
stop_pid() {
  local pid="$1"
  [[ -z "$pid" ]] && return 0
  kill -TERM "$pid" 2>/dev/null || true
  for _ in $(seq 1 40); do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 0.05
  done
  kill -KILL "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
}
cleanup() {
  if [[ -n "$QEMU_PID" ]]; then
    stop_pid "$QEMU_PID"
  fi
  if [[ -n "$COORD_PID" ]]; then
    stop_pid "$COORD_PID"
  fi
  # 128 MiB RAM 是从压缩 checkpoint 链临时展开的副本；正常情况下不应
  # 长期占用磁盘。需要保留现场时显式设置 KEEP_RESTORE_WORK=1。
  if [[ "$KEEP_RESTORE_WORK" != "1" ]]; then
    rm -f "$RUN_DIR/ram.bin" "$RUN_DIR/state.dev" "$RUN_DIR/timer.raw" "$RUN_DIR/state.fp"
  fi
}
trap cleanup EXIT

if [[ -z "$RESUME_SEQ" ]]; then
  RESUME_SEQ="$(tail -1 "$CHAIN/manifest.tsv" | cut -f2)"
fi
echo "==> 从 seq=$RESUME_SEQ 恢复（本次最多 $MAX_INSNS 条）"

# 从 manifest.tsv 取该 seq 的记录（kind seq parent ram_bytes pages
# ram dev arch sys timer gic mmio），兼容旧 11 列与新 12 列命名。
RECORD="$(awk -F '\t' -v s="$RESUME_SEQ" '$2 == s {print; exit}' \
  "$CHAIN/manifest.tsv")"
if [[ -z "$RECORD" ]]; then
  echo "错误：链中找不到 seq=$RESUME_SEQ" >&2
  exit 1
fi
DEV_GZ="$(echo "$RECORD" | cut -f7)"
ARCH_GZ="$(echo "$RECORD" | cut -f8)"
SYS_GZ="$(echo "$RECORD" | cut -f9)"
TIMER_GZ="$(echo "$RECORD" | cut -f10)"
GIC_GZ="$(echo "$RECORD" | cut -f11)"
MMIO_GZ="$(echo "$RECORD" | cut -f12)"
FP_GZ="$(echo "$RECORD" | cut -f13)"
if [[ "$FP_NEON" == "required" ]]; then
  if [[ -z "$FP_GZ" ]]; then
    echo "错误：FP_NEON=required 但 seq=$RESUME_SEQ 缺少 manifest 第13列 FP sidecar：$FP_GZ" >&2
    exit 1
  fi
  # read_manifest 同时验证 finalized manifest、全部 13 列路径、LCVXFP01
  # header/长度/seq，并把 chain-relative 路径解析为绝对路径。所有恢复
  # sidecar 一并从该解析结果取得，不能先用 shell 当前目录误判相对路径。
  RESTORE_PATHS="$(python3 - "$REPO" "$CHAIN" "$RESUME_SEQ" <<'PY'
import sys
from pathlib import Path

repo = Path(sys.argv[1]).resolve()
sys.path.insert(0, str(repo / "sim" / "difftest"))
import checkpoint  # noqa: E402

chain = Path(sys.argv[2]).resolve()
seq = int(sys.argv[3])
rows = checkpoint.read_manifest(chain)
row = checkpoint._selected_row(rows, seq)
paths = (row.dev_path, row.arch_path, row.sys_path, row.timer_path,
         row.gic_path, row.mmio_path, row.fp_path)
if any(path is None for path in paths[:5]) or paths[-1] is None:
    raise ValueError(f"seq={seq}: P7 restore sidecar 不完整")
print("\t".join(str(path) if path is not None else "-" for path in paths))
PY
)"
  IFS=$'\t' read -r DEV_GZ ARCH_GZ SYS_GZ TIMER_GZ GIC_GZ MMIO_GZ FP_GZ <<<"$RESTORE_PATHS"
  [[ "$MMIO_GZ" == "-" ]] && MMIO_GZ=""
elif [[ -n "$FP_GZ" ]]; then
  echo "错误：manifest 含第13列 FP sidecar，必须设置 FP_NEON=required" >&2
  exit 1
fi
for f in "$DEV_GZ" "$ARCH_GZ" "$SYS_GZ" "$TIMER_GZ" "$GIC_GZ"; do
  if [[ -z "$f" || ! -f "$f" ]]; then
    echo "错误：seq=$RESUME_SEQ 的 sidecar 缺失：$f" >&2
    exit 1
  fi
done
if [[ -n "$MMIO_GZ" && ! -f "$MMIO_GZ" ]]; then
  echo "错误：seq=$RESUME_SEQ 的 C++ MMIO sidecar 缺失：$MMIO_GZ" >&2
  exit 1
fi

RAM="$RUN_DIR/ram.bin"
python3 "$CHECKPOINT_TOOL" restore-ram \
  --chain "$CHAIN" --seq "$RESUME_SEQ" --output "$RAM" >/dev/null
# <kind>-<seq>.dev.gz 是 QEMU device vmstate；timer 是计数器偏移 sidecar。
DEV_RAW="$RUN_DIR/state.dev"
TIMER_RAW="$RUN_DIR/timer.raw"
gzip -cd "$DEV_GZ" >"$DEV_RAW"
gzip -cd "$TIMER_GZ" >"$TIMER_RAW"
if [[ "$FP_NEON" == "required" ]]; then
  FP_RAW="$RUN_DIR/state.fp"
  gzip -cd "$FP_GZ" >"$FP_RAW"
fi

SOCK="$RUN_DIR/step.sock"
MON_SOCK="$RUN_DIR/step.mon"
DUMP="$RUN_DIR/fail.txt"
if (( ${#SOCK} >= 108 || ${#MON_SOCK} >= 108 )); then
  echo "错误：UNIX socket 路径过长（须少于 108 字节）：$RUN_DIR" >&2
  exit 1
fi
if [[ -z "$CKPT_DIR" ]]; then
  CKPT_DIR="$RUN_DIR/chain"
elif [[ "$CKPT_DIR" != /* ]]; then
  # manifest.tsv 会保存 artifact 路径；若直接写相对路径，恢复工具
  # 会再次相对 CHAIN 拼接，形成重复前缀而无法恢复。统一发布绝对路径。
  CKPT_DIR="$REPO/$CKPT_DIR"
fi

PARENT_MANIFEST="$CHAIN/manifest.json"
PARENT_MANIFEST_SHA=""
PARENT_GLOBAL_SEQ=""
if [[ -f "$PARENT_MANIFEST" ]]; then
  PARENT_MANIFEST_SHA="$(sha256sum "$PARENT_MANIFEST" | awk '{print $1}')"
  # 当前运行时输入必须与 parent manifest 的实际摘要相同；这也会阻止
  # 错误 Image/DTB/QEMU 在不知情时启动恢复。
  RUNTIME_INPUTS=(--input "image=$IMAGE" --input "dtb=$DTB")
  [[ -n "$INITRD" ]] && RUNTIME_INPUTS+=(--input "initrd=$INITRD")
  RUNTIME_CONTEXT=(--context "qemu_cpu=$QEMU_CPU"
                   --context "fp_neon=$FP_NEON"
                   --context "machine=$MACHINE_CONTEXT"
                   --context "icount=$ICOUNT_CONTEXT")
  if [[ "$FP_NEON" == "required" ]]; then
    RUNTIME_CONTEXT+=(--context p7_state=LCVXFP01
                      --context p7_cpu_profile=a76-v1
                      --context p7_vector_bytes=16)
  fi
  python3 "$CHECKPOINT_TOOL" verify-runtime \
    --chain "$CHAIN" --qemu "$QEMU_BIN" --qemu-version "$QEMU_VERSION" \
    "${RUNTIME_INPUTS[@]}" \
    "${RUNTIME_CONTEXT[@]}" >/dev/null
else
  if [[ "$CKPT_EVERY" != "0" ]]; then
    echo "错误：CKPT_EVERY>0 要求 parent manifest.json，不能从无 provenance 旧链发布 child" >&2
    exit 1
  fi
  echo "警告：parent 没有 manifest.json，本次不启用 checkpoint 发布" >&2
fi

if [[ "$CKPT_EVERY" != "0" ]]; then
  if (( MAX_INSNS == 0 || MAX_INSNS < CKPT_EVERY )); then
    echo "错误：MAX_INSNS 必须不小于 CKPT_EVERY，避免空 child 链" >&2
    exit 1
  fi
  if [[ "$(realpath -m "$CKPT_DIR")" == "$(realpath -m "$CHAIN")" ]]; then
    echo "错误：CKPT_DIR 不能与 parent CHAIN 相同" >&2
    exit 1
  fi
  if [[ -e "$CKPT_DIR/manifest.json" || -e "$CKPT_DIR/manifest.tsv" ]]; then
    echo "错误：CKPT_DIR 已存在 manifest/TSV，拒绝追加混链：$CKPT_DIR" >&2
    exit 1
  fi
  mkdir -p "$CKPT_DIR"
  if [[ -n "$(find "$CKPT_DIR" -mindepth 1 -print -quit 2>/dev/null)" ]]; then
    echo "错误：CKPT_DIR 非空，拒绝发布 child：$CKPT_DIR" >&2
    exit 1
  fi
  PARENT_GLOBAL_SEQ="$(python3 - "$CHAIN" "$RESUME_SEQ" "$REPO" <<'PY'
import sys
from pathlib import Path
sys.path.insert(0, str(Path(sys.argv[3]).resolve() / "sim" / "difftest"))
import checkpoint
chain = Path(sys.argv[1]).resolve()
seq = int(sys.argv[2])
meta = checkpoint._read_manifest_meta(chain)
if meta is None:
    raise SystemExit("parent manifest 缺失")
rows = checkpoint.read_manifest(chain)
row = checkpoint._selected_row(rows, seq)
print(checkpoint._global_offset(meta) + row.seq)
PY
)"
  CHILD_INPUTS=(--input "image=$IMAGE" --input "dtb=$DTB" \
                --input "plugin=$PLUGIN")
  [[ -n "$INITRD" ]] && CHILD_INPUTS+=(--input "initrd=$INITRD")
  CHILD_CONTEXT=(
    --context manifest_lifecycle=strict
    --context provenance_kind=resume
    --context "parent_chain=$(realpath -m "$CHAIN")"
    --context "parent_manifest_sha256=$PARENT_MANIFEST_SHA"
    --context "parent_seq=$PARENT_GLOBAL_SEQ"
    --context "parent_local_seq=$RESUME_SEQ"
    --context "global_seq_offset=$((PARENT_GLOBAL_SEQ + 1))"
    --context local_window_start=0
    --context "local_window_end=$MAX_INSNS"
    --context local_window_end_semantics=exclusive
    --context artifact_range_semantics=inclusive
    --context "qemu_cpu=$QEMU_CPU"
    --context "fp_neon=$FP_NEON"
    --context "machine=$MACHINE_CONTEXT"
    --context "icount=$ICOUNT_CONTEXT"
    --context "boot_dtb=$BOOT_DTB"
    --context "boot_entry=$BOOT_ENTRY"
    --context "kernel_append=$KERNEL_APPEND"
    --context "initrd=$INITRD"
    --context "ckpt_every=$CKPT_EVERY"
    --context "max_insns=$MAX_INSNS"
  )
  if [[ "$FP_NEON" == "required" ]]; then
    CHILD_CONTEXT+=(
      --context p7_state=LCVXFP01
      --context p7_cpu_profile=a76-v1
      --context p7_vector_bytes=16
    )
  fi
  python3 "$CHECKPOINT_TOOL" init-manifest \
    --chain "$CKPT_DIR" --qemu "$QEMU_BIN" --qemu-version "$QEMU_VERSION" \
    "${CHILD_INPUTS[@]}" "${CHILD_CONTEXT[@]}" >/dev/null
else
  mkdir -p "$CKPT_DIR"
fi

COORD_ARGS=(--socket "$SOCK" \
  --base 0x40000000 --boot-dtb "$BOOT_DTB" --boot-entry "$BOOT_ENTRY" \
  --image2 "$IMAGE" --image2-addr "$BOOT_ENTRY" \
  --image3 "$DTB" --image3-addr "$BOOT_DTB" \
  --init-pc 0x40000000 \
  --restore-arch "$ARCH_GZ" \
  --restore-ram "$RAM" \
  --restore-sys "$SYS_GZ" \
  --restore-timer "$TIMER_GZ" \
  --restore-gic "$GIC_GZ")
COORD_ARGS+=(--fp-neon "$FP_NEON")
if [[ "$FP_NEON" == "required" ]]; then
  COORD_ARGS+=(--restore-fp "$FP_RAW")
fi
if [[ -n "$MMIO_GZ" ]]; then
  COORD_ARGS+=(--restore-mmio "$MMIO_GZ")
fi
if [[ -n "$RESTORE_SMCR" ]]; then
  COORD_ARGS+=(--restore-smcr "$RESTORE_SMCR")
fi
COORD_ARGS+=(--max-insns "$MAX_INSNS" --max-cycles-per-insn "$MAX_CYCLES_PER_INSN" \
  --max-wait-cycles "$MAX_WAIT_CYCLES" \
  --progress-every "$PROGRESS_EVERY" --timeout-ms "$TIMEOUT_MS" --dump "$DUMP")
if [[ "$CKPT_EVERY" != "0" ]]; then
  COORD_ARGS+=(--diff-ckpt --ram-file "$RAM" \
    --ckpt-dir "$CKPT_DIR" --ckpt-every "$CKPT_EVERY" \
    --monitor "$MON_SOCK")
fi

if [[ "$COORD_PIN" != "" ]]; then
  taskset -c "$COORD_PIN" "$COORD" "${COORD_ARGS[@]}" >"$RUN_DIR/coord.log" 2>&1 &
else
  "$COORD" "${COORD_ARGS[@]}" >"$RUN_DIR/coord.log" 2>&1 &
fi
COORD_PID=$!
for _ in $(seq 1 1200); do
  [[ -S "$SOCK" ]] && break
  if ! kill -0 "$COORD_PID" 2>/dev/null; then
    echo "错误：协调器提前退出" >&2
    cat "$RUN_DIR/coord.log" >&2 || true
    exit 1
  fi
  sleep 0.1
done
if [[ ! -S "$SOCK" ]]; then
  echo "错误：协调器未创建 socket" >&2
  cat "$RUN_DIR/coord.log" >&2 || true
  exit 1
fi

QEMU_ARGS=(-machine "virt,gic-version=2,dtb-randomness=off" \
  -cpu "$QEMU_CPU" -accel "tcg,thread=single,tb-size=64" \
  -icount "shift=0,align=off,sleep=off" \
  -rtc "base=2000-01-01T00:00:00,clock=vm" -nographic \
  -incoming "exec:cat $DEV_RAW" \
  -object "memory-backend-file,id=lcvexram,size=128M,mem-path=$RAM,share=on" \
  -machine "memory-backend=lcvexram" \
  -plugin "file=$PLUGIN,mode=step,socket=$SOCK,fp=$FP_NEON")
if [[ "$CKPT_EVERY" != "0" ]]; then
  QEMU_ARGS+=(-monitor "unix:$MON_SOCK,server,nowait")
fi
QEMU_ARGS+=(-kernel "$IMAGE")
[[ -n "$INITRD" ]] && QEMU_ARGS+=(-initrd "$INITRD")
QEMU_ARGS+=(-append "$KERNEL_APPEND")
if [[ -n "$QEMU_DEBUG" ]]; then
  QEMU_ARGS+=(-d "$QEMU_DEBUG" -D "$RUN_DIR/qemu-debug.log")
fi

if [[ "$QEMU_PIN" != "" ]]; then
  if [[ "$SKIP_TIMER_RESTORE" == "1" ]]; then
    taskset -c "$QEMU_PIN" env LCVEX_DIFFTEST_STEP=1 \
      "$QEMU_BIN" "${QEMU_ARGS[@]}" >"$RUN_DIR/qemu.log" 2>&1 &
  else
    taskset -c "$QEMU_PIN" env LCVEX_DIFFTEST_STEP=1 \
      LCVEX_TIMER_RESTORE_PATH="$TIMER_RAW" \
      "$QEMU_BIN" "${QEMU_ARGS[@]}" >"$RUN_DIR/qemu.log" 2>&1 &
  fi
else
  if [[ "$SKIP_TIMER_RESTORE" == "1" ]]; then
    LCVEX_DIFFTEST_STEP=1 "$QEMU_BIN" "${QEMU_ARGS[@]}" \
      >"$RUN_DIR/qemu.log" 2>&1 &
  else
    LCVEX_DIFFTEST_STEP=1 LCVEX_TIMER_RESTORE_PATH="$TIMER_RAW" \
      "$QEMU_BIN" "${QEMU_ARGS[@]}" >"$RUN_DIR/qemu.log" 2>&1 &
  fi
fi
QEMU_PID=$!

set +e
wait "$COORD_PID"
RC=$?
set -e
COORD_PID=""
echo "==> 协调器退出码 $RC"
if [[ $RC -eq 3 ]]; then
  echo "窗口以访客复位/关机终止（PSCI SYSTEM_RESET/SYSTEM_OFF，非 FAIL，"
  echo "需人工确认 qemu.log 中复位前的原因）"
  tail -40 "$RUN_DIR/coord.log" >&2 || true
  echo "现场：$DUMP" >&2
  echo "运行目录：$RUN_DIR" >&2
  exit 3
fi
if [[ $RC -ne 0 ]]; then
  tail -60 "$RUN_DIR/coord.log" >&2 || true
  tail -20 "$RUN_DIR/qemu.log" >&2 || true
  echo "失败明细：$DUMP" >&2
  echo "运行目录：$RUN_DIR" >&2
  exit "$RC"
fi
if [[ "$CKPT_EVERY" != "0" ]]; then
  # 只有协调器成功且所有 sidecar/TSV 已落盘才发布 complete manifest；失败
  # 路径保留 pending 现场，但 read_manifest 会拒绝将其作为恢复输入。
  python3 "$CHECKPOINT_TOOL" finalize-manifest --chain "$CKPT_DIR" >/dev/null
fi
echo "PASS: 从 seq=$RESUME_SEQ 续跑 $MAX_INSNS 条通过"
echo "运行目录：$RUN_DIR"
