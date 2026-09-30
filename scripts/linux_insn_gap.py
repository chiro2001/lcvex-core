#!/usr/bin/env python3
"""Linux arm64 启动汇编指令缺口分析（P6 准备）。

输入：Linux 源码 arch/arm64/kernel/{head,entry}.S 与 arch/arm64/mm/proc.S
（早期启动路径：head.S -> __cpu_setup -> __enable_mmu -> start_kernel 前）。
输出：这些文件中出现的指令助记符与 MSR/MRS 系统寄存器清单，与
ISA_SCOPE.md 当前支持集比对，给出 P6 需补的指令/系统寄存器缺口。

用法：
  python3 scripts/linux_insn_gap.py \
      build/linux-src/head.S build/linux-src/proc.S build/linux-src/entry.S
"""

import re
import sys
from pathlib import Path


# ISA_SCOPE.md 当前支持族（与 scripts/insn_coverage.py 归一表一致）
SUPPORTED = {
    # 数据处理
    "add", "adds", "sub", "subs", "cmp", "cmn",
    "and", "ands", "orr", "eor", "bic", "bics", "orn", "eon", "mov",
    "movz", "movk", "movn",
    "lsl", "lsr", "asr", "sbfm", "ubfm", "bfm", "bfi", "bfxil",
    "mul", "madd", "msub", "smaddl", "smsubl", "umaddl", "umsubl",
    "udiv", "sdiv",
    "csel", "csinc", "csinv", "csneg",
    # 分支
    "b", "bl", "br", "blr", "ret", "cbz", "cbnz", "tbz", "tbnz",
    "b.cond",
    # 访存
    "ldr", "str", "ldrb", "strb", "ldrh", "strh", "ldrsb", "ldrsh",
    "ldrsw", "ldp", "stp", "prfm", "ldxr", "stxr", "ldaxr", "stlxr",
    "clrex", "ldr_lit",
    # 地址
    "adr", "adrp",
    # 系统
    "nop", "svc", "eret", "mrs", "msr", "isb", "dmb", "dsb",
    "ic", "dc", "tlbi", "udf", "hvc", "smc", "wfi", "wfe", "sev",
    "brk",
}

# 头文件/宏定义行不统计；只统计指令体
_MNEMONIC = re.compile(r"^\s*([a-z][a-z0-9_.]*)(?:\s|$)")
_MSR_MRS = re.compile(r"^\s*(mrs|msr)\s+([^,]+),\s*([A-Za-z0-9_]+)")
_SYSREG_RE = re.compile(r"\b([A-Za-z][A-Za-z0-9_]*(?:_EL[0-3])?)\b")


def extract(path):
    mnemonics = {}
    sysregs = set()
    for line in Path(path).read_text(encoding="utf-8").splitlines():
        s = line.split("//", 1)[0].split("/*", 1)[0].strip()
        if not s or s.startswith((".", "#", "/*", "*", "//")):
            continue
        m = _MNEMONIC.match(s)
        if m:
            mn = m.group(1)
            mnemonics[mn] = mnemonics.get(mn, 0) + 1
        # 系统寄存器（MRS/MSR 目标或源；跳过立即数与通用寄存器）
        if "msr" in s or "mrs" in s:
            mm = _MSR_MRS.match(s)
            if mm:
                reg = mm.group(3)
                if reg not in ("sp", "xzr", "x0", "x1", "x2", "x3", "x4",
                               "x5", "x6", "x7", "x8", "x9", "x10", "x11",
                               "x12", "x13", "x14", "x15", "x16", "x17",
                               "x18", "x19", "x20", "x21", "x22", "x23",
                               "x24", "x25", "x26", "x27", "x28", "x29",
                               "x30", "w0", "w1", "w2", "w3", "w4", "w5",
                               "w6", "w7", "w8", "w9", "w10", "w11", "w12",
                               "w13", "w14", "w15", "w16", "w17", "w18",
                               "w19", "w20", "w21", "w22", "w23", "w24",
                               "w25", "w26", "w27", "w28", "w29", "w30",
                               "lr", "fp", "spsel", "daifset", "daifclr",
                               "pan", "uao", "ssbs", "tco"):
                    sysregs.add(reg)
    return mnemonics, sysregs


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 1
    all_mn = {}
    all_sr = set()
    for p in sys.argv[1:]:
        mn, sr = extract(p)
        for k, v in mn.items():
            all_mn[k] = all_mn.get(k, 0) + v
        all_sr |= sr

    # 归一化：去掉 W/X 后缀与常见变体
    def norm(mn):
        return mn.replace("_w", "")

    missing = sorted(m for m in all_mn if norm(m) not in SUPPORTED)
    print("== 出现助记符（按次数） ==")
    for m, c in sorted(all_mn.items(), key=lambda kv: -kv[1]):
        flag = "" if norm(m) in SUPPORTED else "  <-- 缺口"
        print(f"  {m:12s} {c:5d}{flag}")
    print("\n== 系统寄存器访问 ==")
    for r in sorted(all_sr):
        print(f"  {r}")
    print(f"\n== 缺口助记符：{len(missing)} ==")
    for m in missing:
        print(f"  {m}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
