#!/usr/bin/env python3
"""B4 裸机 C 反汇编覆盖表生成器。

输入：`build/b4_baremetal/<O0|O2|Os>/mb_all.dis`
输出：`build/coverage/b4_baremetal_cov.json`，并打印各优化等级归一化后的
支持族命中/未命中；未归一化助记符列入 `unknown_aliases`。

用途：B4 编译器/覆盖闭合，不开 QEMU、不启动 Quartus；只做静态反汇编审计。
"""

from __future__ import annotations

import json
import re
from collections import Counter
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
DIS_DIRS = [REPO / "build" / "b4_baremetal" / o for o in ("O0", "O2", "Os")]
OUT = REPO / "build" / "coverage" / "b4_baremetal_cov.json"

# GNU objdump 助记符 -> 支持族（LCVEX 已支持/别名）
NORMALIZE = {
    "add": "add", "adds": "adds", "sub": "sub", "subs": "subs",
    "cmp": "subs", "cmn": "adds", "neg": "sub", "negs": "subs",
    "and": "and", "ands": "ands", "orr": "orr", "eor": "eor",
    "bic": "bic", "bics": "bics", "orn": "orn", "eor": "eor",
    "eon": "eon", "mvn": "orn", "mov": "mov",
    "movk": "movk", "sbfm": "sbfm", "ubfm": "ubfm", "bfm": "bfm",
    "bfi": "bfm", "bfxil": "bfm", "ubfiz": "ubfm", "sbfiz": "sbfm",
    "lsl": "ubfm", "lsr": "ubfm", "asr": "sbfm",
    "sxtb": "sbfm", "sxth": "sbfm", "sxtw": "sbfm",
    "uxtb": "ubfm", "uxth": "ubfm", "uxtw": "ubfm",
    "tst": "ands",
    "mul": "mul", "umulh": "umulh", "smulh": "umulh",
    "udiv": "udiv", "sdiv": "sdiv",
    "madd": "madd", "msub": "msub",
    "umaddl": "umaddl", "umsubl": "umsubl",
    "smaddl": "smaddl", "smsubl": "smsubl",
    "umull": "umaddl",
    "csel": "csel", "cinc": "csel", "cset": "csinc",
    "csinc": "csinc", "csinv": "csinv", "csetm": "csinv",
    "csneg": "csneg", "cneg": "csneg",
    "rbit": "rbit", "rev": "rev", "rev16": "rev", "rev32": "rev",
    "clz": "clz", "cls": "clz",
    "b": "b", "bl": "bl", "br": "br", "blr": "blr", "ret": "ret",
    "cbz": "cbz", "cbnz": "cbnz", "tbz": "tbz", "tbnz": "tbnz",
    "adr": "adr", "adrp": "adrp",
    "ldr": "ldr", "str": "str", "ldrb": "ldrb", "strb": "strb",
    "ldrh": "ldrh", "strh": "strh", "ldrsw": "ldrsw",
    "ldrsb": "ldrsb", "ldrsh": "ldrsh",
    "ldp": "ldp", "stp": "stp", "prfm": "prfm", "nop": "nop",
    "ldxr": "ldxr", "ldaxr": "ldxr", "stxr": "stxr", "stlxr": "stxr",
    "clrex": "clrex",
    "ldar": "ldar", "ldarb": "ldar", "ldarh": "ldar",
    "stlr": "stlr", "stlrb": "stlr", "stlrh": "stlr",
    "mrs": "mrs", "msr": "msr", "svc": "svc", "eret": "eret",
    "isb": "isb", "dmb": "dmb", "dsb": "dsb", "sb": "sb",
    "ic": "ic", "dc": "dc", "tlbi": "tlbi", "at": "at",
    "udf": "udf",
}

SUPPORTED = set(NORMALIZE.values())


def normalize_cond(mnem: str) -> str | None:
    if re.fullmatch(r"b\.[a-z]{2}", mnem):
        return "b.cond"
    return NORMALIZE.get(mnem)


def parse_dis(path: Path) -> Counter:
    cnt: Counter = Counter()
    if not path.exists():
        return cnt
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        m = re.match(r"\s*[0-9a-f]+:\s+[0-9a-f ]+\s+(\S+)", line)
        if not m:
            continue
        mnem = m.group(1).rstrip(",")
        fam = normalize_cond(mnem)
        if fam:
            cnt[fam] += 1
    return cnt


def main() -> int:
    result = {
        "format": "LCVEX-B4-BAREMETAL-COV-1",
        "dis_dirs": [str(p) for p in DIS_DIRS],
        "opt_levels": {},
        "supported_families": sorted(SUPPORTED),
    }
    all_seen = set()
    for d in DIS_DIRS:
        name = d.name
        dis = d / "mb_all.dis"
        cnt = parse_dis(dis)
        all_seen.update(cnt)
        unknown = []
        # Re-parse raw for unknown aliases (e.g. .inst or section lines)
        for line in dis.read_text(encoding="utf-8", errors="replace").splitlines():
            m = re.match(r"\s*[0-9a-f]+:\s+[0-9a-f ]+\s+(\S+)", line)
            if not m:
                continue
            mnem = m.group(1).rstrip(",")
            if normalize_cond(mnem) is None and mnem not in {
                "section", "format", ".inst", ".word", ".hword", ".byte",
            }:
                unknown.append(mnem)
        result["opt_levels"][name] = {
            "families": dict(sorted(cnt.items())),
            "unique_supported": len(cnt),
            "unknown_aliases": sorted(set(unknown)),
        }
    result["all_supported_seen"] = sorted(all_seen)
    result["missing_supported"] = sorted(SUPPORTED - all_seen)
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(json.dumps(result, ensure_ascii=False, indent=2,
                              sort_keys=True) + "\n", encoding="utf-8")
    for name, info in result["opt_levels"].items():
        print(f"==> {name}: unique_supported={info['unique_supported']}; "
              f"unknown={info['unknown_aliases']}")
    print(f"==> all_supported_seen={len(result['all_supported_seen'])}")
    print(f"==> missing_supported={result['missing_supported']}")
    print(f"==> JSON: {OUT}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
