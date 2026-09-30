#!/usr/bin/env python3
"""指令覆盖记账：QEMU trace 助记符 ↔ ISA_SCOPE 支持矩阵比对。

输入：一个或多个 QEMU 批量 trace 文件（run_qemu.py --trace-only 产物，
记录含 `disas="..."` 字段）；程序对每条 COMMIT 记录的助记符做别名归一，
统计各支持族的出现次数，并与期望覆盖集比对。

用法：
  python3 scripts/insn_coverage.py --expect random \
      build/difftest/random_1.trace build/difftest/random_2.trace ...
  python3 scripts/insn_coverage.py --expect all build/difftest/*.trace
  python3 scripts/insn_coverage.py --warn-only ...   # 缺失只告警不失败

输出：build/coverage/insn_map.txt（默认，或 --out 指定）：
  每个归一化族的出现次数 + `expected_hit=X/Y`、
  `observed_families=Z` 和缺失/未见族列表。
退出码：缺失族时 1（除非 --warn-only）。
"""

import argparse
import re
import sys
from collections import Counter
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "sim" / "difftest"))

from qemu_trace import parse_trace  # noqa: E402


# disas 助记符 -> 归一化族（覆盖 ISA_SCOPE.md 支持的指令与汇编器别名）
_NORMALIZE = {
    # 数据处理
    "add": "add", "cmn": "add",
    "adds": "adds",
    "sub": "sub", "neg": "sub",
    "subs": "subs", "negs": "subs", "cmp": "subs",
    "and": "and",
    "ands": "ands", "tst": "ands",
    "orr": "orr",
    "eor": "eor",
    "bic": "bic",
    "bics": "bics",
    "orn": "orn", "mvn": "orn",
    "eon": "eon",
    "sbfm": "sbfm", "asr": "sbfm", "sxtb": "sbfm", "sxth": "sbfm",
    "sxtw": "sbfm", "sbfx": "sbfm", "sbfiz": "sbfm",
    "ubfm": "ubfm", "lsl": "ubfm", "lsr": "ubfm", "ubfx": "ubfm",
    "ubfiz": "ubfm",
    "uxtb": "ubfm", "uxth": "ubfm", "uxtw": "ubfm", "uxtx": "ubfm",
    "bfm": "bfm", "bfi": "bfm", "bfxil": "bfm", "bfc": "bfm",
    "movn": "movn",
    "movz": "movz",
    "movk": "movk",
    "mul": "mul",
    "umulh": "umulh", "smulh": "umulh",
    "udiv": "udiv",
    "sdiv": "sdiv",
    "madd": "madd",
    "msub": "msub",
    "smaddl": "smaddl",
    "smsubl": "smsubl",
    "umaddl": "umaddl",
    "umsubl": "umsubl",
    "csel": "csel",
    "csinc": "csinc", "cinc": "csinc",
    "csinv": "csinv", "cinv": "csinv",
    "csneg": "csneg", "cneg": "csneg",
    # P6：Linux 启动缺口
    "rev": "rev", "rev16": "rev", "rev32": "rev",
    "rbit": "rbit",
    "clz": "clz", "cls": "clz",
    "ccmp": "ccmp", "ccmn": "ccmn",
    "bti": "bti",
    # 分支
    "b": "b",
    "bl": "bl",
    "br": "br",
    "blr": "blr",
    "ret": "ret",
    "cbz": "cbz",
    "cbnz": "cbnz",
    "tbz": "tbz",
    "tbnz": "tbnz",
    # 访存
    "ldr": "ldr",
    "str": "str",
    "ldrb": "ldrb",
    "strb": "strb",
    "ldrh": "ldrh",
    "strh": "strh",
    "ldrsb": "ldrsb",
    "ldrsh": "ldrsh",
    "ldrsw": "ldrsw",
    "ldp": "ldp",
    "stp": "stp",
    "ldxrb": "ldxr", "ldxrh": "ldxr", "ldxr": "ldxr",
    "ldaxrb": "ldxr", "ldaxrh": "ldxr", "ldaxr": "ldxr",
    "stxrb": "stxr", "stxrh": "stxr", "stxr": "stxr",
    "stlxrb": "stxr", "stlxrh": "stxr", "stlxr": "stxr",
    "clrex": "clrex",
    "prfm": "prfm",
    # 地址
    "adr": "adr",
    "adrp": "adrp",
    # 系统
    "svc": "svc",
    "eret": "eret",
    "mrs": "mrs",
    "msr": "msr",
    "nop": "nop",
    "isb": "isb",
    "dmb": "dmb",
    "dsb": "dsb",
    "ic": "ic",
    "dc": "dc",
    "tlbi": "tlbi",
    "udf": "udf",
}


def normalize(mnemonic, insn=None):
    """把 disas 助记符归一为支持族；B.cond 单独处理。"""
    if re.fullmatch(r"b\.[a-z]{2}", mnemonic):
        return "b.cond"
    if mnemonic == "mov" and insn is not None:
        # QEMU 把 MOVN/MOVZ 都反汇编成 "mov"：按指令 opc 区分
        # （opc[30:29]：00=movn，10=movz，11=movk；01=保留）。
        opc = (int(insn, 16) >> 29) & 3
        return {0: "movn", 2: "movz", 3: "movk"}.get(opc)
    return _NORMALIZE.get(mnemonic)


# 随机生成器（random_program.py）应覆盖的族
EXPECT_RANDOM = {
    "add", "adds", "sub", "subs", "and", "ands", "orr", "eor",
    "bic", "bics", "orn", "eon", "sbfm", "ubfm", "bfm",
    "movn", "movz", "movk", "mul", "umulh", "udiv", "sdiv", "madd", "msub",
    "smaddl", "smsubl", "umaddl", "umsubl",
    "csel", "csinc", "csinv", "csneg",
    "rev", "rbit", "clz", "ccmp", "ccmn", "bti",
    "b", "b.cond", "cbz", "cbnz", "tbz", "tbnz",
    "adr", "adrp", "ldr", "str", "ldrb", "strb", "ldrh", "strh",
    "ldrsb", "ldrsh", "ldrsw", "ldp", "stp", "prfm", "nop",
    "ldxr", "stxr", "clrex",
}

# ISA_SCOPE.md 当前全部支持族（L2/L3 定向+随机共同覆盖）
EXPECT_ALL = EXPECT_RANDOM | {
    "bl", "br", "blr", "ret", "svc", "eret", "mrs", "msr",
    "isb", "dmb", "dsb", "ic", "dc", "tlbi", "udf",
}


def collect(traces):
    """解析 trace 文件，返回 {归一化族: 计数} 与未知助记符集合。"""
    seen = Counter()
    unknown = Counter()
    for path in traces:
        for rec in parse_trace(str(path)):
            if rec["tag"] != "commit":
                continue
            disas = rec.get("disas", "").strip('"')
            if not disas:
                continue
            mnem = disas.split()[0]
            fam = normalize(mnem, rec.get("insn"))
            if fam:
                seen[fam] += 1
            else:
                unknown[mnem] += 1
    return seen, unknown


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("traces", nargs="+", help="QEMU trace 文件")
    ap.add_argument("--expect", choices=("random", "all"), default="random",
                    help="期望覆盖集（默认 random=随机生成器覆盖范围）")
    ap.add_argument("--out", default=str(REPO / "build" / "coverage" /
                                         "insn_map.txt"))
    ap.add_argument("--warn-only", action="store_true",
                    help="缺失只告警，不改变退出码")
    args = ap.parse_args()

    paths = [Path(p) for p in args.traces]
    missing_paths = [p for p in paths if not p.exists()]
    if missing_paths:
        for p in missing_paths:
            print(f"错误：trace 不存在 {p}", file=sys.stderr)
        return 2

    seen, unknown = collect(paths)
    expected = EXPECT_RANDOM if args.expect == "random" else EXPECT_ALL
    missing = sorted(expected - set(seen))
    extra = sorted(set(seen) - EXPECT_ALL)  # 支持的但没有记入矩阵的族
    expected_hit = len(expected & set(seen))
    observed_families = len(seen)

    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    with open(out, "w", encoding="utf-8") as f:
        f.write("# lcvex 指令覆盖记账（QEMU trace 助记符归一统计）\n")
        f.write(f"# traces: {', '.join(str(p) for p in paths)}\n")
        f.write(f"# expect: {args.expect}（{len(expected)} 族）\n\n")
        f.write(f"# expected_hit: {expected_hit}/{len(expected)}\n")
        f.write(f"# observed_families: {observed_families}\n\n")
        for fam, cnt in sorted(seen.items()):
            f.write(f"{fam:10s} {cnt}\n")
        f.write("\n# 未见（期望但缺失）\n")
        for fam in missing:
            f.write(f"- {fam}\n")

    print(f"==> 覆盖统计：expected_hit={expected_hit}/{len(expected)}，"
          f"observed_families={observed_families}，"
          f"总提交 {sum(seen.values())} 条")
    for fam, cnt in sorted(seen.items()):
        print(f"  {fam:10s} {cnt}")
    if unknown:
        print(f"==> 未知助记符（不在归一表）: {dict(unknown)}")
    if missing:
        print(f"==> 缺失（期望但未见）: {', '.join(missing)}")
        if args.warn_only:
            print("    (--warn-only，不计失败)")
            return 0
        return 1
    if extra:
        print(f"==> 提示：出现但未列入 EXPECT_ALL 的族: {', '.join(extra)}")
    print("PASS: 期望覆盖集全部命中")
    return 0


if __name__ == "__main__":
    sys.exit(main())
