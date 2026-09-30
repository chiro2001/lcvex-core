#!/usr/bin/env python3
"""生成并校验 QEMU virt/GICv2 的确定性 Device Tree。

DTB 只写入 build/difftest 或调用方指定目录，不把 1 MiB 原始 dump 长期留在
/tmp。校验目标是 LCVEX 当前 RTL 已实现的 PL011、Generic Timer、GICv2、PSCI
和 128 MiB RAM 布局；输出 compact DTB 的 SHA256，供双镜像锁步和 checkpoint
manifest 记录。
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import subprocess
import sys
from pathlib import Path


def run_checked(cmd: list[str], *, timeout: float) -> subprocess.CompletedProcess[str]:
    try:
        return subprocess.run(cmd, check=True, text=True, capture_output=True,
                              timeout=timeout)
    except subprocess.CalledProcessError as exc:
        detail = (exc.stderr or exc.stdout or "").strip()
        raise RuntimeError(f"命令失败：{' '.join(cmd)}\n{detail}") from exc
    except subprocess.TimeoutExpired as exc:
        raise RuntimeError(f"命令超时：{' '.join(cmd)}") from exc


def node_body(dts: str, name: str) -> str:
    match = re.search(rf"(?m)^\s*{re.escape(name)}\s*\{{(?P<body>.*?)^\s*\}};",
                      dts, re.S)
    if not match:
        raise ValueError(f"DTB 缺少节点 {name}")
    return match.group("body")


def require(body: str, pattern: str, what: str) -> None:
    if not re.search(pattern, body, re.S):
        raise ValueError(f"DTB {what} 不匹配")


def validate(dts: str, require_bootargs: str | None) -> list[str]:
    root = dts
    require(root, r'compatible\s*=\s*"linux,dummy-virt"', "virt compatible")
    memory = node_body(dts, r"memory@40000000")
    require(memory, r'reg\s*=\s*<0x0+\s+0x40000000\s+0x0+\s+0x8000000>',
            "128 MiB memory reg")
    uart = node_body(dts, r"pl011@9000000")
    require(uart, r'compatible\s*=\s*"arm,pl011"', "PL011 compatible")
    require(uart, r'reg\s*=\s*<0x0+\s+0x9000000\s+0x0+\s+0x1000>',
            "PL011 reg")
    gic = node_body(dts, r"intc@8000000")
    require(gic, r'compatible\s*=\s*"arm,cortex-a15-gic"', "GICv2 compatible")
    require(gic, r'reg\s*=\s*<0x0+\s+0x8000000\s+0x0+\s+0x10000\s+'
            r'0x0+\s+0x8010000\s+0x0+\s+0x10000>', "GICD/GICC reg")
    timer = node_body(dts, r"timer")
    require(timer, r'compatible\s*=\s*"arm,armv8-timer"', "Generic Timer compatible")
    psci = node_body(dts, r"psci")
    require(psci, r'method\s*=\s*"hvc"', "PSCI HVC conduit")
    node_body(dts, r"cpus")
    node_body(dts, r"cpu@0")
    if require_bootargs is not None:
        chosen = node_body(dts, r"chosen")
        require(chosen, rf'bootargs\s*=\s*"{re.escape(require_bootargs)}',
                "chosen.bootargs")
    return ["memory@40000000", "pl011@9000000", "intc@8000000",
            "timer", "psci", "cpus/cpu@0"]


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--qemu", type=Path, default=Path("../qemu/build/qemu-system-aarch64"))
    ap.add_argument("--dtc", type=str, default="dtc")
    ap.add_argument("--output", type=Path, required=True)
    ap.add_argument("--summary", type=Path)
    ap.add_argument("--gic-version", type=int, choices=(2,), default=2)
    ap.add_argument("--require-bootargs")
    ap.add_argument("--keep-raw", action="store_true")
    args = ap.parse_args()

    args.output.parent.mkdir(parents=True, exist_ok=True)
    raw = args.output.with_suffix(args.output.suffix + ".raw")
    compact_tmp = args.output.with_suffix(args.output.suffix + ".tmp")
    try:
        run_checked([str(args.qemu), "-machine",
                     f"virt,gic-version={args.gic_version},dtb-randomness=off,"
                     f"dumpdtb={raw}", "-cpu", "max,has_el3=false,has_el2=false",
                     "-display", "none", "-serial", "null"], timeout=30)
        run_checked([args.dtc, "-I", "dtb", "-O", "dts", str(raw), "-o",
                     str(compact_tmp.with_suffix(".dts"))], timeout=30)
        dts_path = compact_tmp.with_suffix(".dts")
        dts = dts_path.read_text(encoding="utf-8")
        nodes = validate(dts, args.require_bootargs)
        run_checked([args.dtc, "-I", "dts", "-O", "dtb", str(dts_path), "-o",
                     str(compact_tmp)], timeout=30)
        compact = compact_tmp.read_bytes()
        args.output.write_bytes(compact)
        digest = hashlib.sha256(compact).hexdigest()
        summary = {"format": "LCVX-virt-dtb-v1", "gic_version": args.gic_version,
                   "raw_bytes": raw.stat().st_size, "compact_bytes": len(compact),
                   "sha256": digest, "nodes": nodes, "output": str(args.output)}
        if args.summary is not None:
            args.summary.parent.mkdir(parents=True, exist_ok=True)
            args.summary.write_text(json.dumps(summary, ensure_ascii=False,
                                               sort_keys=True, indent=2) + "\n",
                                          encoding="utf-8")
        print(json.dumps(summary, ensure_ascii=False, sort_keys=True))
        return 0
    except (OSError, RuntimeError, ValueError) as exc:
        print(f"错误：{exc}", file=sys.stderr)
        return 1
    finally:
        if not args.keep_raw:
            raw.unlink(missing_ok=True)
        compact_tmp.unlink(missing_ok=True)
        compact_tmp.with_suffix(".dts").unlink(missing_ok=True)


if __name__ == "__main__":
    raise SystemExit(main())
