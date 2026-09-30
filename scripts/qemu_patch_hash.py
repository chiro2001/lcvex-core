#!/usr/bin/env python3
"""QEMU patches canonical combined SHA256 计算器（AUD-06 / EXT-02-001）。

Canonical 定义：
- 文件范围：``qemu/patches/`` 下所有 ``*.patch``（当前应为 13 个）。
- 排序：按 ``sort`` 固定字节序（LC_ALL=C，按相对路径/文件名字节序）。
- 文件边界：不加文件名、不追加分隔符。
- 内容边界：只对每个 patch 的原始字节流做二进制串接；Git 工作区文件中的
  内容（含结尾换行）即参与哈希的字节。
- 组合摘要：对串接后的原始字节计算 SHA256。

等价 shell 命令（与外部审计 EXT-02-001 的复现命令一致）：

    LC_ALL=C find qemu/patches -maxdepth 1 -type f -name '*.patch' -print0 \\
      | sort -z | xargs -0 cat | sha256sum

用法：
    python3 scripts/qemu_patch_hash.py
    python3 scripts/qemu_patch_hash.py --check 340246a8...
    python3 scripts/qemu_patch_hash.py --json
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
from pathlib import Path

DEFAULT_PATCHES_DIR = Path("qemu/patches")
PATCH_RE = re.compile(r"^[0-9]{4}-.*\.patch$")
EXPECTED_COUNT = 13
CANONICAL_SHA256 = "b6b820249650b92ec9842da4e6492bdc8fb5dc12e2f2fc1ed0090069294e1119"


def collect_patches(patches_dir: Path) -> list[Path]:
    if not patches_dir.is_dir():
        raise SystemExit(f"{patches_dir}: not a directory")
    files = [
        p for p in patches_dir.iterdir()
        if p.is_file() and PATCH_RE.match(p.name)
    ]
    # Contract: stable byte-order sort by file name (relative path).
    files.sort(key=lambda p: (p.name.encode("utf-8"),))
    return files


def compute(files: list[Path]) -> tuple[dict[str, str], str, int]:
    h = hashlib.sha256()
    per_file = {}
    total_bytes = 0
    for path in files:
        data = path.read_bytes()
        per_file[path.name] = hashlib.sha256(data).hexdigest()
        h.update(data)
        total_bytes += len(data)
    return per_file, h.hexdigest(), total_bytes


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--patches-dir", type=Path, default=DEFAULT_PATCHES_DIR,
                    help="目录，默认 qemu/patches")
    ap.add_argument("--check", metavar="SHA256", default=None,
                    help="校验组合哈希是否等于给定值")
    ap.add_argument("--json", action="store_true",
                    help="以 JSON 输出")
    args = ap.parse_args(argv)

    files = collect_patches(args.patches_dir)
    if len(files) != EXPECTED_COUNT:
        print(f"ERROR: expected {EXPECTED_COUNT} patches, found {len(files)}",
              file=sys.stderr)
        return 2

    per_file, combined, total_bytes = compute(files)
    result = {
        "canonical": {
            "scope": "qemu/patches/*.patch",
            "sort": "LC_ALL=C byte-order by filename",
            "file_boundary": "no separator; raw file bytes concatenated",
            "content_boundary": "exact file bytes as stored in git worktree",
            "command": (
                "LC_ALL=C find qemu/patches -maxdepth 1 -type f "
                "-name '*.patch' -print0 | sort -z | xargs -0 cat | sha256sum"
            ),
            "files": [p.name for p in files],
        },
        "file_count": len(files),
        "total_bytes": total_bytes,
        "per_file_sha256": per_file,
        "combined_sha256": combined,
        "expected_canonical_sha256": CANONICAL_SHA256,
    }

    if args.json:
        print(json.dumps(result, ensure_ascii=False, indent=2, sort_keys=True))
    else:
        for name in [p.name for p in files]:
            print(f"{per_file[name]}  {name}")
        print(f"combined: {combined}")
        print(f"expected: {CANONICAL_SHA256}")
        print(f"match: {combined == CANONICAL_SHA256}")

    if args.check:
        if combined != args.check:
            print(f"ERROR: combined {combined} != expected {args.check}",
                  file=sys.stderr)
            return 1

    if combined != CANONICAL_SHA256:
        print(f"ERROR: canonical mismatch (computed {combined})",
              file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
