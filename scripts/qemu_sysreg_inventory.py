#!/usr/bin/env python3
"""从固定 QEMU 生成 AArch64 系统寄存器编码/读值清单。

该工具只做参考模型取证，不把 QEMU 的所有 feature 宣称为 RTL 已实现。
输出中的 exception/ec 用于后续按 RAZ/WI、陷阱和有状态寄存器分类。
"""

from __future__ import annotations

import argparse
import json
import re
import struct
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
DEF_RE = re.compile(
    r"^\s*DEF\(\s*([A-Za-z0-9_]+)\s*,\s*([0-7])\s*,\s*([0-7])\s*,"
    r"\s*([0-9]+)\s*,\s*([0-9]+)\s*,\s*([0-7])\s*\)"
)
COMMIT_RE = re.compile(
    r"commit pc=0x([0-9a-f]+) insn=0x([0-9a-f]+) next=0x([0-9a-f]+) "
    r"exc=(\d+) ec=0x([0-9a-f]+) (?P<regs>.*) nzcv=0x([0-9a-f]+)"
)
REG_RE = re.compile(r"x(\d+)=0x([0-9a-f]+)")


def parse_defs(path: Path) -> list[dict[str, object]]:
    regs = []
    for line in path.read_text(encoding="utf-8").splitlines():
        match = DEF_RE.match(line)
        if not match:
            continue
        name, op0, op1, crn, crm, op2 = match.groups()
        # QEMU 的保留槽也保留在清单中；它们应当验证 RAZ/陷阱语义。
        regs.append({
            "name": name,
            "tuple": [int(op0), int(op1), int(crn), int(crm), int(op2)],
        })
    if not regs:
        raise ValueError(f"{path}: 没有解析到 DEF 系统寄存器")
    return regs


def encode_mrs(reg: dict[str, object], rt: int) -> int:
    op0, op1, crn, crm, op2 = reg["tuple"]
    return (0xD5000000 | (1 << 21) | (op0 << 19) | (op1 << 16) |
            (crn << 12) | (crm << 8) | (op2 << 5) | rt)


def build_probe(regs: list[dict[str, object]], path: Path) -> None:
    words = []
    for index, reg in enumerate(regs):
        reg["rt"] = index % 11
        reg["insn"] = encode_mrs(reg, int(reg["rt"]))
        words.append(int(reg["insn"]))
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(struct.pack(f"<{len(words)}I", *words))


def run_probe(args: argparse.Namespace, regs: list[dict[str, object]],
              image: Path) -> list[dict[str, object]]:
    cmd = [
        sys.executable, str(REPO / "sim/difftest/qemu_probe.py"),
        "--image", str(image), "--max-insns", str(len(regs)),
        "--base", "0x44000000", "--el1",
        "--qemu", str(args.qemu),
        "--icount", "shift=0,align=off,sleep=off",
    ]
    proc = subprocess.run(cmd, cwd=REPO, text=True,
                          stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                          check=False)
    lines = [line for line in proc.stdout.splitlines()
             if line.startswith("commit ")]
    for index, line in enumerate(lines[:len(regs)]):
        match = COMMIT_RE.match(line)
        if not match:
            continue
        pc, insn, next_pc, exc, ec, reg_text, nzcv = match.groups()
        values = {int(r): int(v, 16) for r, v in REG_RE.findall(reg_text)}
        regs[index]["pc"] = int(pc, 16)
        regs[index]["next_pc"] = int(next_pc, 16)
        regs[index]["exception"] = bool(int(exc))
        regs[index]["ec"] = int(ec, 16)
        regs[index]["nzcv"] = int(nzcv, 16)
        regs[index]["value"] = values.get(int(regs[index]["rt"]))
    if proc.returncode != 0 and not lines:
        raise RuntimeError(f"QEMU probe 失败（rc={proc.returncode}）：\n{proc.stdout}")
    return regs


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--qemu", type=Path,
                    default=REPO / "../qemu/build/qemu-system-aarch64")
    ap.add_argument("--defs", type=Path,
                    default=REPO / "../qemu/target/arm/cpu-sysregs.h.inc")
    ap.add_argument("--output", type=Path,
                    default=REPO / "build/difftest/qemu-sysreg-inventory.json")
    ap.add_argument("--image", type=Path,
                    default=REPO / "build/difftest/qemu-sysreg-probe.bin")
    args = ap.parse_args()
    regs = parse_defs(args.defs)
    build_probe(regs, args.image)
    regs = run_probe(args, regs, args.image)
    result = {
        "format": "LCVX-qemu-sysreg-inventory-v1",
        "qemu": str(args.qemu.resolve()),
        "defs": str(args.defs.resolve()),
        "count": len(regs),
        "registers": regs,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, ensure_ascii=False, indent=2,
                                      sort_keys=True) + "\n", encoding="utf-8")
    complete = sum("value" in reg for reg in regs)
    print(json.dumps({"format": result["format"], "count": len(regs),
                      "observed": complete, "output": str(args.output)},
                     ensure_ascii=False, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
