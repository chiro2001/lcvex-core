#!/usr/bin/env python3
"""QEMU trace 反汇编 → 与 ISA_SCOPE 支持集比对（Linux 启动实证缺口）。

输入：QEMU 批量 trace（lcvex_difftest 插件 trace 模式产物，含
`insn=0x....` 与 `disas="..."`）。程序把 trace 中出现的去重指令编码
交给 aarch64-linux-gnu-objdump 反汇编，统计真实助记符，与
ISA_SCOPE.md 支持族比对，输出缺口清单。

用法：
  python3 scripts/kernel_trace_gap.py kernel.trace [--limit-insns N]
"""

import argparse
import os
import re
import subprocess
import sys
import tempfile
from collections import Counter
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "sim" / "difftest"))

from qemu_trace import parse_trace  # noqa: E402


# ISA_SCOPE.md 支持族（含别名归一，与 scripts/insn_coverage.py 一致并
# 补 Linux 启动常用别名/提示指令）
SUPPORTED = {
    "add", "adds", "sub", "subs", "neg", "cmp", "cmn",
    "and", "ands", "tst", "orr", "eor", "bic", "bics", "orn", "eon",
    "mov", "movz", "movk", "movn",
    "lsl", "lsr", "asr", "ror", "sbfm", "ubfm", "bfm", "bfi", "bfxil",
    "sbfiz", "sbfx", "ubfiz", "ubfx",
    "sxtb", "sxth", "sxtw", "uxtb", "uxth", "uxtw",
    "mul", "madd", "msub", "smaddl", "smsubl", "umaddl", "umsubl",
    "udiv", "sdiv",
    "csel", "csinc", "csinv", "csneg", "cinc", "cinv", "cneg",
    "cset", "csetm",
    "rev", "rev16", "rev32", "clz", "cls",
    "ccmp", "ccmn", "bti",
    "b", "bl", "br", "blr", "ret", "cbz", "cbnz", "tbz", "tbnz",
    "b.cond",
    "ldr", "str", "ldrb", "strb", "ldrh", "strh", "ldrsb", "ldrsh",
    "ldur", "stur", "ldurb", "sturb", "ldurh", "sturh", "ldursb",
    "ldursh", "ldursw", "prfum",
    "ldrsw", "ldp", "stp", "prfm", "ldxr", "stxr", "ldaxr", "stlxr",
    "clrex", "ldxp", "stxp",
    "adr", "adrp",
    "nop", "svc", "eret", "mrs", "msr", "isb", "dmb", "dsb", "sb",
    "ic", "dc", "tlbi", "udf", "hvc", "smc", "wfi", "wfe", "sev",
    "sevl", "brk",
}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("trace", nargs="+")
    ap.add_argument("--limit-insns", type=int, default=100000)
    ap.add_argument(
        "--tmp-dir",
        type=Path,
        default=Path(os.environ.get("LCVEX_TMP_DIR", REPO / "build/tmp")),
        help="反汇编临时文件目录（默认 LCVEX_TMP_DIR 或 build/tmp）",
    )
    args = ap.parse_args()

    enc_counter = Counter()
    disas_counter = Counter()
    for path in args.trace:
        for r in parse_trace(path):
            if r.get("tag") != "commit":
                continue
            enc_counter[r["insn"].replace("0x", "")] += 1
            disas_counter[r.get("disas", "?")] += 1
            if sum(enc_counter.values()) >= args.limit_insns:
                break

    encs = sorted(enc_counter)
    print(f"去重指令编码：{len(encs)}（总提交 {sum(enc_counter.values())}）")

    # 反汇编去重编码。显式指定目录，避免 tempfile 在空间较小的 /tmp
    # 创建中间文件；调用方仍可用 --tmp-dir 覆盖到专用工作盘。
    args.tmp_dir.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(
        "w", suffix=".txt", delete=False, dir=args.tmp_dir
    ) as f:
        for w in encs:
            f.write(f".inst 0x{w}\n")
        src = f.name
    obj = src[:-4] + ".o"
    try:
        subprocess.run(["aarch64-linux-gnu-as", "-o", obj, src], check=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        out = subprocess.run(["aarch64-linux-gnu-objdump", "-d", obj],
                             check=True, capture_output=True, text=True).stdout
    finally:
        Path(src).unlink(missing_ok=True)
        Path(obj).unlink(missing_ok=True)

    insn_by_word = {}
    for line in out.splitlines():
        m = re.match(r"\s*[0-9a-f]+:\s*([0-9a-f]{8})\s+([a-z0-9.]+)", line)
        if m:
            insn_by_word[m.group(1)] = m.group(2)

    mnem = Counter()
    unknown_words = []
    for w in encs:
        mn = insn_by_word.get(w)
        if mn is None:
            unknown_words.append(w)
            continue
        mnem[mn] += enc_counter[w]

    print("\n== 真实助记符（按提交次数） ==")
    gaps = []
    for mn, c in mnem.most_common():
        base = re.sub(r"\.[a-z]{2}$", ".cond", mn)
        base = re.sub(r"[bhw]$", "", base) if base not in SUPPORTED else base
        ok = base in SUPPORTED
        print(f"  {mn:12s} {c:8d}{'' if ok else '  <-- 缺口'}")
        if not ok:
            gaps.append(mn)
    if unknown_words:
        print(f"\n== 无法反汇编的编码：{len(unknown_words)} ==")
        for w in unknown_words[:20]:
            print(f"  0x{w}")
    print(f"\n== 缺口助记符：{len(gaps)} ==")
    for g in sorted(set(gaps)):
        print(f"  {g}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
