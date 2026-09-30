#!/usr/bin/env bash
# P4/Q6 锁步（mode=step）：QEMU fork step hook + Verilator 协调器。
# QEMU 以 EL1h 复位（has_el3=false,has_el2=false），与 RTL 复位一致；
# 同步异常以 exc_valid/exc_code COMMIT 上报并比较。
#
# 用法：make lockstep-step（默认 q6_svc.bin）
#   IMAGE=... 指定测试镜像（build_p4b_*.bin）
#   MAX_INSNS=... 提交上限（默认 14）
#   INITRD=...（可选）Linux lite initramfs；主线默认不传入
#   PLUGIN=... 指定 QEMU difftest plugin；缺省使用当前 worktree 构建物
#   PIN=... 兼容入口：同时绑定协调器/QEMU；COORD_PIN/QEMU_PIN 可分别覆盖
#   P7_MAX_ADAPTER=1 仅允许 P7 required 的 max 低128-bit 无 checkpoint 诊断
set -euo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
QEMU_BIN="${QEMU_BIN:-$REPO/../qemu/build/qemu-system-aarch64}"
PLUGIN="${PLUGIN:-$REPO/qemu/plugins/lcvex_difftest.so}"
COORD="${COORD:-$REPO/build/verilator_lockstep/lockstep_coordinator}"
SOCK="${SOCK:-$REPO/build/difftest/step.sock}"
IMAGE="${IMAGE:-$REPO/build/difftest/q6_svc.bin}"
DUMP="${DUMP:-$REPO/build/difftest/step_fail.txt}"
COORD_LOG="${COORD_LOG:-$REPO/build/difftest/step_coord.log}"
QEMU_LOG="${QEMU_LOG:-$REPO/build/difftest/step_qemu.log}"
PYTHON="${PYTHON:-python3}"
CHECKPOINT_TOOL="$REPO/sim/difftest/checkpoint.py"
BASE=0x44000000
MAX_INSNS="${MAX_INSNS:-14}"
PROGRESS_EVERY="${PROGRESS_EVERY:-1}"
# P6 内核锁步模式：KERNEL=1 时 QEMU 用 -kernel + -append（无 -dtb，
# QEMU 自己生成 FDT，dtb-randomness=off 保证确定性）；协调器在
# 0x40000000 写 bootloader（x0=DTB@0x44000000、跳内核 0x40080000）、
# 加载内核 0x40080000 + DTB 0x44000000，init-pc=0x40000000。
# 注意：QEMU 对 -dtb 的 FDT 修改非幂等（每次启动注入随机 seed 并
# 重打包），协调器必须使用 QEMU 实际加载的 FDT（pmemsave 导出）。
KERNEL="${KERNEL:-0}"
INIT_PC="${INIT_PC:-}"
KERNEL_DTB="${KERNEL_DTB:-$REPO/build/difftest/qemu-gen-fdt-1m.bin}"
KERNEL_APPEND="${KERNEL_APPEND:-console=ttyAMA0,115200 earlycon=pl011,0x09000000 rdinit=/bin/sh nokaslr panic=-1}"
KERNEL_DTB_REGEN="${KERNEL_DTB_REGEN:-0}"
INITRD="${INITRD:-}"
BOOT_DTB="${BOOT_DTB:-0x44000000}"
BOOT_ENTRY="${BOOT_ENTRY:-0x40080000}"
# 标量核无 FP/NEON：lite 线用 vfp=off,neon=off,vfp-d32=off 让内核
# 走纯标量路径（fpsimd_save/load 仅在 system_supports_fpsimd() 时执行）。
QEMU_CPU_INPUT="${QEMU_CPU-}"
QEMU_CPU="${QEMU_CPU:-max,has_el3=false,has_el2=false}"
FP_NEON="${FP_NEON:-off}"
case "$FP_NEON" in
  off|required) ;;
  *) echo "错误：FP_NEON 只接受 off|required" >&2; exit 2 ;;
esac
P7_MAX_ADAPTER="${P7_MAX_ADAPTER:-0}"
if [[ "$FP_NEON" == "required" ]]; then
  # required 的默认路径必须是 P7 canonical A76；max 只保留给显式的、
  # 不发布 checkpoint 的兼容诊断，并且不能混入 Gate-F/P7 证据。
  if [[ -z "$QEMU_CPU_INPUT" ]]; then
    QEMU_CPU="cortex-a76,cntfrq=1000000000,has_el3=false,has_el2=false"
  elif [[ "$QEMU_CPU" == max,* || "$QEMU_CPU" == max ]]; then
    if [[ "$P7_MAX_ADAPTER" != "1" ]]; then
      echo "错误：P7 required 必须使用 Cortex-A76；max adapter 仅可显式设置 P7_MAX_ADAPTER=1 做兼容诊断" >&2
      exit 2
    fi
  elif [[ "$QEMU_CPU" != cortex-a76,* ]]; then
    echo "错误：P7 required 的 QEMU_CPU 必须是 cortex-a76 profile" >&2
    exit 2
  fi
fi
PIN="${PIN:-}"
COORD_PIN="${COORD_PIN-$PIN}"
QEMU_PIN="${QEMU_PIN-$PIN}"
# P6 checkpoint：CKPT_EVERY>0 时协调器每 N 条 OK 提交触发 QEMU
# monitor migrate（vmstate 保存到 CKPT_DIR/ckpt-<seq>.gz）。
CKPT_EVERY="${CKPT_EVERY:-0}"
CKPT_DIR="${CKPT_DIR:-$REPO/build/difftest/ckpt}"
MON_SOCK="${MON_SOCK:-$REPO/build/difftest/step.mon}"
# 差分 checkpoint：QEMU RAM 映射到显式共享文件，CKPT_REQ 协议让 QEMU
# fork hook 保存 CPU/设备状态。
# 默认关闭；开启时脚本会为本次运行创建一个明确的 128 MiB RAM 文件。
DIFF_CKPT="${DIFF_CKPT:-0}"
RAM_FILE="${RAM_FILE:-$CKPT_DIR/ram-backend.bin}"
DIFF_CKPT_RESET_RAM="${DIFF_CKPT_RESET_RAM:-1}"
DIFF_CKPT_KEEP_RAM="${DIFF_CKPT_KEEP_RAM:-0}"
# RTL 的 CNTFRQ_EL0 与既有 P6 协议固定为 1 GHz。QEMU 11.1 的 A76
# 默认属性仍可能是兼容用的 62.5 MHz；它可以做无 timer 的 required
# smoke，但不能发布可恢复的 P7 checkpoint。把标准 A76 写法规范化为
# 显式 1 GHz，并拒绝其他无法与 DUT 对齐的 P7 checkpoint profile。
if [[ "$FP_NEON" == "required" && "$P7_MAX_ADAPTER" == "1" && "$CKPT_EVERY" != "0" ]]; then
  echo "错误：max adapter 禁止任何 P7 checkpoint（CKPT_EVERY 必须为 0）" >&2
  exit 2
fi
if [[ "$FP_NEON" == "required" && "$CKPT_EVERY" != "0" && "$DIFF_CKPT" != "1" ]]; then
  echo "错误：P7 required checkpoint 必须使用 DIFF_CKPT=1 的 LCVXFP01 路径" >&2
  exit 2
fi
if [[ "$FP_NEON" == "required" && "$DIFF_CKPT" == "1" ]]; then
  if [[ "$QEMU_CPU" == "cortex-a76,has_el3=false,has_el2=false" ]]; then
    QEMU_CPU="cortex-a76,cntfrq=1000000000,has_el3=false,has_el2=false"
  fi
  if [[ "$QEMU_CPU" != *"cntfrq=1000000000"* ]]; then
    echo "错误：P7 checkpoint 的 QEMU_CPU 必须显式包含 cntfrq=1000000000" >&2
    exit 2
  fi
fi
# PL031 依赖 QEMU rtc_clock；固定 epoch + vm clock 后，C++ fabric 可只按
# 已退休指令计数推进 1 ns，与 -icount shift=0 保持确定性一致。
QEMU_RTC_ARGS=(-rtc "base=2000-01-01T00:00:00,clock=vm")

run_pinned() {
  local pin="$1"
  shift
  if [[ -n "$pin" ]]; then
    # 该函数通常在后台执行；exec 让调用方保存的 $! 就是真实
    # taskset/QEMU/coordinator PID，结束时 TERM 不会留下孤儿进程。
    exec taskset -c "$pin" "$@"
  else
    exec "$@"
  fi
}

# 差分 checkpoint 必须在导出 FDT 前创建 RAM backend：QEMU virt 的 FDT
# 会随 machine 配置变化。此前先以普通 virt 导出、再用 memory-backend 启动
# QEMU，导致 DTB header/size 与 DUT 镜像不同，Linux 稍后读取 DTB 时才分歧。
if [[ "$DIFF_CKPT" == "1" ]]; then
  if [[ "$CKPT_EVERY" == "0" ]]; then
    echo "错误：DIFF_CKPT=1 必须同时设置 CKPT_EVERY>0" >&2
    exit 1
  fi
  if [[ -e "$CKPT_DIR/manifest.tsv" || -e "$CKPT_DIR/manifest.json" ]]; then
    echo "错误：checkpoint 链目录非空，请为本次运行指定新的 CKPT_DIR：$CKPT_DIR" >&2
    exit 1
  fi
  mkdir -p "$CKPT_DIR" "$(dirname "$RAM_FILE")"
  if [[ "$DIFF_CKPT_RESET_RAM" == "1" ]]; then
    rm -f "$RAM_FILE"
    truncate -s 134217728 "$RAM_FILE"
  elif [[ ! -f "$RAM_FILE" ]]; then
    echo "错误：DIFF_CKPT_RESET_RAM=0 但 RAM_FILE 不存在：$RAM_FILE" >&2
    exit 1
  fi
fi

# KERNEL=1：导出 QEMU 生成 FDT（确定性；dtb-randomness=off 禁随机 seed）。
# 差分 checkpoint 使用每条链私有的 FDT，避免覆盖非 checkpoint 运行的输入，
# 并保证导出与实际锁步 QEMU 均带同一个 memory-backend。
DTB_NEEDS_EXPORT=0
if [[ "$KERNEL" == "1" ]]; then
  if [[ "$DIFF_CKPT" == "1" ]]; then
    KERNEL_DTB="$CKPT_DIR/qemu-fdt-raw.bin"
    DTB_NEEDS_EXPORT=1
  elif [[ "$KERNEL_DTB_REGEN" == "1" || ! -f "$KERNEL_DTB" ]]; then
    DTB_NEEDS_EXPORT=1
  fi
fi
if [[ "$DTB_NEEDS_EXPORT" == "1" ]]; then
  mkdir -p "$(dirname "$KERNEL_DTB")" "$REPO/build/difftest"
  DTB_HMP="${KERNEL_DTB}.hmp"
  DTB_RAW="$KERNEL_DTB"
  cat > "$DTB_HMP" <<EOF
pmemsave $BOOT_DTB 0x100000 "$DTB_RAW"
quit
EOF
  DTB_KERNEL_ARGS=(-kernel "$IMAGE")
  [[ -n "$INITRD" ]] && DTB_KERNEL_ARGS+=(-initrd "$INITRD")
  DTB_KERNEL_ARGS+=(-append "$KERNEL_APPEND")
  DTB_MACHINE="virt,gic-version=2,dtb-randomness=off"
  DTB_EXTRA=()
  if [[ "$DIFF_CKPT" == "1" ]]; then
    DTB_MACHINE+=",memory-backend=lcvexram"
    DTB_EXTRA=(-object "memory-backend-file,id=lcvexram,size=128M,mem-path=$RAM_FILE,share=on")
  fi
  timeout 30 "$QEMU_BIN" -machine "$DTB_MACHINE" \
    -cpu "$QEMU_CPU" -accel tcg,thread=single,tb-size=64 \
    -icount shift=0,align=off,sleep=off "${QEMU_RTC_ARGS[@]}" \
    "${DTB_EXTRA[@]}" "${DTB_KERNEL_ARGS[@]}" \
    -display none -serial null -S -monitor stdio \
    < "$DTB_HMP" > /dev/null 2>&1 || true
  if [[ ! -f "$DTB_RAW" ]]; then
    echo "错误：QEMU FDT 导出失败（$KERNEL_DTB 不存在且无法生成）" >&2
    exit 1
  fi
  KERNEL_DTB="$DTB_RAW"
  echo "QEMU FDT 已导出到 $KERNEL_DTB"
fi

for f in "$COORD" "$PLUGIN" "$IMAGE"; do
  if [[ ! -f "$f" ]]; then
    echo "错误：找不到 $f" >&2
    exit 1
  fi
done
if [[ -n "$INITRD" && ! -f "$INITRD" ]]; then
  echo "错误：找不到 INITRD=$INITRD" >&2
  exit 1
fi
if [[ "$KERNEL" == "1" && ! -f "$KERNEL_DTB" ]]; then
  echo "错误：找不到 KERNEL_DTB=$KERNEL_DTB" >&2
  exit 1
fi

mkdir -p "$(dirname "$SOCK")" "$CKPT_DIR"
rm -f "$SOCK" "$DUMP" "$COORD_LOG" "$QEMU_LOG"
if [[ "$DIFF_CKPT" == "1" ]]; then
  MANIFEST_INPUTS=(--input "image=$IMAGE")
  MANIFEST_INPUTS+=(--input "plugin=$PLUGIN")
  if [[ "$KERNEL" == "1" ]]; then
    MANIFEST_INPUTS+=(--input "dtb=$KERNEL_DTB")
    [[ -n "$INITRD" ]] && MANIFEST_INPUTS+=(--input "initrd=$INITRD")
  fi
  MANIFEST_MACHINE="virt,gic-version=2,dtb-randomness=off"
  [[ "$DIFF_CKPT" == "1" ]] && MANIFEST_MACHINE+=",memory-backend=lcvexram"
  MANIFEST_CONTEXT=(
    --context "kernel=$KERNEL"
    --context "base=$BASE"
    --context "max_insns=$MAX_INSNS"
    --context "ckpt_every=$CKPT_EVERY"
    --context "kernel_append=$KERNEL_APPEND"
    --context "manifest_lifecycle=strict"
    --context "provenance_kind=root"
    --context "global_seq_offset=0"
    --context "qemu_cpu=$QEMU_CPU"
    --context "fp_neon=$FP_NEON"
    --context "machine=$MANIFEST_MACHINE"
    --context "icount=shift=0,align=off,sleep=off"
    --context "boot_dtb=$BOOT_DTB"
    --context "boot_entry=$BOOT_ENTRY"
  )
  if [[ "$FP_NEON" == "required" ]]; then
    MANIFEST_CONTEXT+=(
      --context p7_state=LCVXFP01
      --context p7_cpu_profile=a76-v1
      --context p7_vector_bytes=16
    )
  fi
  "$PYTHON" "$CHECKPOINT_TOOL" init-manifest \
    --chain "$CKPT_DIR" --qemu "$QEMU_BIN" \
    --qemu-version "$REPO/qemu/VERSION" \
    "${MANIFEST_INPUTS[@]}" \
    "${MANIFEST_CONTEXT[@]}"
fi

if [[ "$KERNEL" == "1" ]]; then
  COORD_ARGS=(--base 0x40000000 \
    --boot-dtb "$BOOT_DTB" --boot-entry "$BOOT_ENTRY" \
    --image2 "$IMAGE" --image2-addr "$BOOT_ENTRY" \
    --image3 "$KERNEL_DTB" --image3-addr "$BOOT_DTB" \
    --init-pc 0x40000000)
else
  COORD_ARGS=(--image "$IMAGE" --base "$BASE")
fi
COORD_ARGS+=(--fp-neon "$FP_NEON")
COORD_EXTRA=()
if [[ "$DIFF_CKPT" == "1" ]]; then
  COORD_EXTRA=(--diff-ckpt --ram-file "$RAM_FILE")
fi
run_pinned "$COORD_PIN" "$COORD" --socket "$SOCK" "${COORD_ARGS[@]}" \
  --max-insns "$MAX_INSNS" --max-cycles-per-insn 1000 \
  --max-wait-cycles "${MAX_WAIT_CYCLES:-1000000}" \
  --progress-every "$PROGRESS_EVERY" \
  --timeout-ms 120000 --dump "$DUMP" \
  --cpu-profile "$QEMU_CPU" \
  --ckpt-dir "$CKPT_DIR" --ckpt-every "$CKPT_EVERY" \
  --monitor "$MON_SOCK" "${COORD_EXTRA[@]}" \
  > "$COORD_LOG" 2>&1 &
COORD_PID=$!

for _ in $(seq 1 1200); do
  [[ -S "$SOCK" ]] && break
  sleep 0.05
done

if [[ "$KERNEL" == "1" ]]; then
  QEMU_EXTRA=()
  QEMU_MACHINE="virt,gic-version=2,dtb-randomness=off"
  if [[ "$DIFF_CKPT" == "1" ]]; then
    QEMU_MACHINE+=",memory-backend=lcvexram"
    QEMU_EXTRA+=("-object" "memory-backend-file,id=lcvexram,size=128M,mem-path=$RAM_FILE,share=on")
  fi
  QEMU_KERNEL_ARGS=(-kernel "$IMAGE")
  [[ -n "$INITRD" ]] && QEMU_KERNEL_ARGS+=(-initrd "$INITRD")
  QEMU_KERNEL_ARGS+=(-append "$KERNEL_APPEND")
  run_pinned "$QEMU_PIN" env LCVEX_DIFFTEST_STEP=1 "$QEMU_BIN" \
    -machine "$QEMU_MACHINE" \
    -cpu "$QEMU_CPU" -accel tcg,thread=single,tb-size=64 \
    -icount shift=0,align=off,sleep=off "${QEMU_RTC_ARGS[@]}" \
    -nographic \
    -plugin "file=$PLUGIN,mode=step,socket=$SOCK,fp=$FP_NEON" \
    -monitor unix:$MON_SOCK,server,nowait \
    "${QEMU_EXTRA[@]}" "${QEMU_KERNEL_ARGS[@]}" \
    > "$QEMU_LOG" 2>&1 &
else
  QEMU_EXTRA=()
  QEMU_MACHINE="virt"
  if [[ "$DIFF_CKPT" == "1" ]]; then
    QEMU_MACHINE+=",memory-backend=lcvexram"
    QEMU_EXTRA+=("-object" "memory-backend-file,id=lcvexram,size=128M,mem-path=$RAM_FILE,share=on")
  fi
  run_pinned "$QEMU_PIN" env LCVEX_DIFFTEST_STEP=1 "$QEMU_BIN" -machine "$QEMU_MACHINE" \
    -cpu "$QEMU_CPU" -accel tcg,thread=single,tb-size=64 \
    -icount shift=0,align=off,sleep=off "${QEMU_RTC_ARGS[@]}" \
    -nographic \
    -plugin "file=$PLUGIN,mode=step,socket=$SOCK,fp=$FP_NEON" \
    -device "loader,file=$IMAGE,addr=$BASE,cpu-num=0,force-raw=on" \
    "${QEMU_EXTRA[@]}" \
    > "$QEMU_LOG" 2>&1 &
fi
QEMU_PID=$!

set +e
# KERNEL 锁步可达数十分钟（8M 条 ~12min、25M 条 ~40min）：等待上限
# 36000 次 × 0.1s（60 分钟），避免长首跑被提前强杀。
for _ in $(seq 1 36000); do
  if ! kill -0 "$COORD_PID" 2>/dev/null; then
    break
  fi
  sleep 0.1
done
if kill -0 "$COORD_PID" 2>/dev/null; then
  echo "错误：协调器超时未退出，强杀" >&2
  kill -TERM "$COORD_PID" 2>/dev/null
fi
wait "$COORD_PID"
COORD_RC=$?
kill -TERM "$QEMU_PID" 2>/dev/null
wait "$QEMU_PID" 2>/dev/null
set -e

if [[ $COORD_RC -ne 0 ]]; then
  if [[ $COORD_RC -eq 3 ]]; then
    echo "窗口以访客复位/关机终止（PSCI SYSTEM_RESET/SYSTEM_OFF，非 FAIL，"
    echo "需人工确认 qemu.log 中复位前的原因）"
    tail -30 "$COORD_LOG"
    echo "现场：$DUMP"
    if [[ "$DIFF_CKPT" == "1" && "$DIFF_CKPT_KEEP_RAM" != "1" ]]; then
      rm -f "$RAM_FILE"
    fi
    exit 3
  fi
  echo "FAIL: mode=step 锁步失败（协调器退出码 $COORD_RC）"
  tail -30 "$COORD_LOG"
  if [[ "$DIFF_CKPT" == "1" && "$DIFF_CKPT_KEEP_RAM" != "1" ]]; then
    rm -f "$RAM_FILE"
  fi
  exit 1
fi
if [[ "$DIFF_CKPT" == "1" ]]; then
  "$PYTHON" "$CHECKPOINT_TOOL" finalize-manifest \
    --chain "$CKPT_DIR"
fi
if [[ "$DIFF_CKPT" == "1" && "$DIFF_CKPT_KEEP_RAM" != "1" ]]; then
  # RAM backend 仅是运行时映射；压缩 base/diff 已发布后默认清理，避免
  # 每条测试在工作树留下 128 MiB 原始文件。恢复实验显式设置 KEEP_RAM=1。
  rm -f "$RAM_FILE"
fi
echo "PASS: mode=step 锁步 $MAX_INSNS 条与 QEMU 完全一致（$IMAGE）"
