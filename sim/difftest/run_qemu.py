#!/usr/bin/env python3
"""QEMU 差分 trace 生成与验证。

用法：
  make difftest           # P1 程序：两次运行 + 参考模型比较（确定性）
  run_qemu.py --trace-only --program p2 --out trace --limit N
                          # 生成单次 trace（RTL Cocotb 差分用）
要求：../qemu 已构建（aarch64-softmmu + plugins），插件已编译。
"""

import argparse
import os
import random
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent.parent
QEMU_DIR = Path(os.environ.get("QEMU_DIR", str(REPO.parent / "qemu")))
QEMU_BIN = Path(os.environ.get(
    "QEMU_BIN", str(QEMU_DIR / "build" / "qemu-system-aarch64")))
PLUGIN = REPO / "qemu" / "plugins" / "lcvex_difftest.so"
BUILD_DIR = REPO / "build" / "difftest"

sys.path.insert(0, str(Path(__file__).resolve().parent))

from qemu_trace import parse_trace  # noqa: E402
from state_model import A64State, compare_state  # noqa: E402
from a64 import Insn  # noqa: E402
from test_program import (BASE, P1_INSN_LIST, assemble, build_p1_program,  # noqa
                          build_p2_program, build_program, build_hazard_program,
                          hazard_program, p2_program)
import random_program  # noqa: E402


def run_qemu(trace_path, program, limit, timeout=10):
    cmd = [
        str(QEMU_BIN),
        "-machine", "virt",
        "-cpu", "max",
        "-accel", "tcg,thread=single",
        "-icount", "shift=0,align=off,sleep=off",
        "-nographic",
        "-plugin", f"file={PLUGIN},trace={trace_path},limit={limit}",
        "-device",
        f"loader,file={program},addr=0x{BASE:x},cpu-num=0,force-raw=on",
    ]
    print("==> " + " ".join(cmd))
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, text=True)
    try:
        proc.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        # Popen.communicate(timeout=...) 不会自动清理子进程。先发 SIGTERM，
        # 给 QEMU/plugin 的 atexit 回调机会关闭 gzip trace；只有仍不退出
        # 时才升级 SIGKILL。直接使用 subprocess.run(timeout=...) 会 SIGKILL，
        # 在 clean CI 上留下不存在或没有 footer 的 trace。
        proc.terminate()
        try:
            proc.communicate(timeout=2)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.communicate()


def validate(records):
    if not records:
        raise SystemExit("FAIL: trace 为空")
    init = records[0]
    if init["tag"] != "init":
        raise SystemExit(f"FAIL: 首行应为 init，实际 {init['tag']}")

    state = A64State(
        pc=int(init["pc"], 16),
        x=[int(init[f"x{i}"], 16) for i in range(31)],
        sp=int(init["sp"], 16),
        nzcv=int(init["nzcv"], 16),
    )

    commits = [r for r in records[1:] if r["tag"] == "commit"]
    print(f"==> init pc=0x{state.pc:x}，commit 记录 {len(commits)} 条")

    errors = []
    for idx, rec in enumerate(commits):
        insn = int(rec["insn"], 16)
        pc = int(rec["pc"], 16)
        label = f"commit[{idx}] pc=0x{pc:x} insn=0x{insn:08x}"
        try:
            next_pc, writes = state.step(insn, insn_pc=pc)
            state.pc = next_pc
            state.pending_writes = writes
        except ValueError as exc:
            errors.append(f"{label}: {exc}")
            continue
        errors.extend(compare_state(rec, state, label))

    if errors:
        for e in errors:
            print(f"FAIL: {e}")
        raise SystemExit(f"FAIL: {len(errors)} 个不一致")
    print("PASS: QEMU 差分导出与参考模型完全一致")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--program",
                        choices=("p1", "p2", "random", "q5exc", "hazard"),
                        default="p1")
    parser.add_argument("--trace-only", action="store_true",
                        help="只生成一次 trace，不做模型校验与确定性检查")
    parser.add_argument("--gen-only", action="store_true",
                        help="只生成测试程序，不运行 QEMU")
    parser.add_argument("--out", default=None, help="trace 输出路径")
    parser.add_argument("--limit", type=int, default=16,
                        help="commit 行数上限")
    parser.add_argument("--seed", type=int, default=1)
    parser.add_argument("--length", type=int, default=2000)
    args = parser.parse_args()

    BUILD_DIR.mkdir(parents=True, exist_ok=True)

    if args.program == "p1":
        program = BUILD_DIR / "p1.bin"
        build_p1_program(program)
        ninsns = len(assemble(P1_INSN_LIST, BASE))
    elif args.program == "p2":
        program = BUILD_DIR / "p2.bin"
        build_p2_program(program)
        ninsns = len(assemble(p2_program(), BASE))
    elif args.program == "q5exc":
        # Q5：movz x0, #0x5000, lsl #16; str x0, [x0]
        # RTL 两条都能提交；QEMU 对未映射地址 0x50000000 的 store
        # 触发数据 abort -> 插件上报 DISCON（P2 视为失败）。
        program = BUILD_DIR / "q5exc.bin"
        build_program(program, assemble([
            Insn("movz", 0, 0x5000, 1),
            Insn("str", 0, 0, 0),
        ], BASE))
        ninsns = 2
    elif args.program == "hazard":
        program = BUILD_DIR / "hazard.bin"
        build_hazard_program(program)
        ninsns = len(assemble(hazard_program(), BASE))
    else:
        program = BUILD_DIR / "random.bin"
        rng = random.Random(args.seed)
        insns = random_program.with_loop(
            random_program.gen_program(rng, args.length))
        ninsns = len(assemble(insns, BASE))
        build_program(program, assemble(insns, BASE))

    limit = ninsns if args.program in ("random", "hazard") else args.limit

    if args.gen_only:
        print(f"==> 程序已生成：{program}")
        return

    if not QEMU_BIN.exists():
        raise SystemExit(f"找不到 QEMU：{QEMU_BIN}（先构建 aarch64-softmmu）")
    if not PLUGIN.exists():
        raise SystemExit(f"找不到插件：{PLUGIN}（先 make -C qemu/plugins）")

    if args.trace_only:
        out = args.out or str(BUILD_DIR / f"{args.program}_run.trace")
        run_qemu(out, program, limit)
        print(f"==> trace 已写入 {out}")
        return

    traces = []
    for run in range(2):  # 跑两次，验证确定性
        trace = BUILD_DIR / f"{args.program}_run{run}.trace"
        run_qemu(trace, program, limit)
        records = parse_trace(trace)
        validate(records)
        traces.append(trace)

    if traces[0].read_bytes() == traces[1].read_bytes():
        print("PASS: 两次运行输出完全一致（确定性）")
    else:
        raise SystemExit("FAIL: 两次运行输出不一致")


if __name__ == "__main__":
    main()
