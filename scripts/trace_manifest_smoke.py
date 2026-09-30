#!/usr/bin/env python3
"""trace manifest/切片的低资源正反向 smoke。

所有文件都在 ``build/difftest`` 下的自动清理目录中生成；不启动 QEMU 或
Verilator，也不写系统 ``/tmp``。
"""

from __future__ import annotations

import argparse
import gzip
import json
import shutil
import sys
from argparse import Namespace
from pathlib import Path
from tempfile import TemporaryDirectory

HERE = Path(__file__).resolve().parent
REPO = HERE.parent
sys.path.insert(0, str(HERE))

from trace_manifest import (  # noqa: E402
    TraceManifestError,
    create_manifest,
    load_manifest,
    summarize_trace,
    verify_manifest,
)
from trace_slice import slice_trace  # noqa: E402


def _fixture_lines(count: int = 7) -> list[str]:
    lines = [
        "# lcvex-qemu-trace v1",
        "# fixture header=manifest-smoke",
        "init pc=0x0000000044000000 x0=0x0 sp=0x0 next_pc=0x44000000 nzcv=0x4 stores=0",
    ]
    for seq in range(count):
        pc = 0x44000000 + seq * 4
        insn = 0xD503201F + seq
        lines.append(
            f"commit pc=0x{pc:016x} insn=0x{insn:08x} "
            f"x0=0x{seq + 1:x} sp=0x0 next_pc=0x{pc + 4:016x} nzcv=0x4 stores=0"
        )
    return lines


def _write_trace(path: Path, lines: list[str], compressed: bool) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    if compressed:
        with gzip.open(path, "wt", encoding="utf-8", newline="\n") as stream:
            stream.write("\n".join(lines) + "\n")
    else:
        path.write_text("\n".join(lines) + "\n", encoding="utf-8", newline="\n")


def _args(trace: Path, out: Path, **kwargs: object) -> Namespace:
    values: dict[str, object] = {
        "trace": trace,
        "out": out,
        "parent": None,
        "start": None,
        "end": None,
        "seq_start": 0,
        "input": [],
        "qemu_commit": "fixture-qemu-11.1",
        "plugin_version": "fixture-plugin-v1",
        "command_line": "-machine virt -icount shift=0",
    }
    values.update(kwargs)
    return Namespace(**values)


def _expect_failure(fn, label: str) -> None:
    try:
        fn()
    except (TraceManifestError, OSError, ValueError):
        return
    raise AssertionError(label)


def _inputs(root: Path) -> list[str]:
    paths = {
        "image": root / "Image",
        "dtb": root / "virt.dtb",
        "qemu": root / "qemu-system-aarch64",
        "plugin": root / "lcvex_difftest.so",
        "qemu_version": root / "qemu-VERSION",
    }
    for role, path in paths.items():
        path.write_bytes(f"fixture-{role}\n".encode())
    return [f"{role}={path}" for role, path in paths.items()]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path,
                        help="临时目录父目录（默认 build/difftest）")
    args = parser.parse_args()
    scratch = (args.root or (REPO / "build" / "difftest")).resolve()
    scratch.mkdir(parents=True, exist_ok=True)
    with TemporaryDirectory(prefix="trace-manifest-", dir=scratch) as raw:
        root = Path(raw)
        inputs = _inputs(root)
        full = root / "full.trace.gz"
        full_plain = root / "full.trace"
        full_manifest = root / "full.trace.json"
        lines = _fixture_lines()
        _write_trace(full, lines, True)
        _write_trace(full_plain, lines, False)

        create_manifest(_args(full, full_manifest, input=inputs, seq_start=100))
        full_data = verify_manifest(full_manifest)
        assert full_data["compression"]["codec"] == "gzip"
        assert full_data["summary"]["seq_start"] == 100
        assert full_data["summary"]["seq_end"] == 107
        create_manifest(_args(full_plain, root / "full.trace.json.plain",
                              input=inputs, seq_start=0))
        assert verify_manifest(root / "full.trace.json.plain")["compression"]["codec"] == "none"

        sliced = root / "slice.trace.gz"
        sliced_manifest = root / "slice.trace.json"
        result = slice_trace(full, sliced, 102, 105, 100, 107)
        assert result["written"] == 3
        create_manifest(_args(sliced, sliced_manifest, parent=full_manifest,
                              start=102, end=105))
        child = verify_manifest(sliced_manifest)
        assert child["summary"]["seq_start"] == 102
        assert child["summary"]["seq_end"] == 105

        # parent manifest 本身被改写时，child 链必须失效。
        parent_bytes = full_manifest.read_bytes()
        full_manifest.write_bytes(parent_bytes + b" ")
        _expect_failure(lambda: verify_manifest(sliced_manifest),
                        "parent manifest 篡改未拒绝")
        full_manifest.write_bytes(parent_bytes)
        verify_manifest(sliced_manifest)

        # 二级切片保持全局 seq，不把 parent 的局部 ordinal 当全局值。
        nested = root / "nested.trace"
        nested_manifest = root / "nested.trace.json"
        slice_trace(sliced, nested, 103, 105, 102, 105)
        create_manifest(_args(nested, nested_manifest, parent=sliced_manifest,
                              start=103, end=105))
        assert verify_manifest(nested_manifest)["summary"]["seq_start"] == 103

        tail = root / "tail.trace.gz"
        tail_result = slice_trace(full, tail, 104, -1, 100, 107)
        assert tail_result["start"] == 104 and tail_result["end"] == 107

        # 相对路径在整个 release artifact 目录移动后仍有效。
        moved = root / "moved"
        shutil.copytree(root, moved, ignore=shutil.ignore_patterns("moved"))
        verify_manifest(moved / "full.trace.json")
        verify_manifest(moved / "slice.trace.json")
        verify_manifest(moved / "nested.trace.json")

        # 子 trace 内容、输入、parent manifest、compression metadata 篡改均拒绝。
        original = sliced.read_bytes()
        with gzip.open(sliced, "rt", encoding="utf-8") as stream:
            altered_lines = stream.read().splitlines()
        altered_lines = [line.replace("insn=0xd5032021", "insn=0xd50320ff", 1)
                         for line in altered_lines]
        _write_trace(sliced, altered_lines, True)
        _expect_failure(lambda: verify_manifest(sliced_manifest), "child payload 篡改未拒绝")
        sliced.write_bytes(original)
        with gzip.open(sliced, "rt", encoding="utf-8") as stream:
            altered_init = stream.read().replace("init pc=0x0000000044000000",
                                                   "init pc=0x0000000044000004", 1)
        with gzip.open(sliced, "wt", encoding="utf-8", newline="\n") as stream:
            stream.write(altered_init)
        _expect_failure(lambda: verify_manifest(sliced_manifest),
                        "child init 篡改未拒绝")
        sliced.write_bytes(original)
        input_path = root / "Image"
        input_path.write_bytes(b"tampered-image\n")
        _expect_failure(lambda: verify_manifest(full_manifest), "输入 hash 篡改未拒绝")
        input_path.write_bytes(b"fixture-image\n")
        bad = load_manifest(full_manifest)
        bad["compression"]["codec"] = "none"
        full_manifest.write_text(json.dumps(bad), encoding="utf-8")
        _expect_failure(lambda: verify_manifest(full_manifest), "compression metadata 篡改未拒绝")
        create_manifest(_args(full, full_manifest, input=inputs, seq_start=100))

        # 截断和尾垃圾必须在严格 gzip reader 中失败。
        truncated = root / "truncated.trace.gz"
        truncated.write_bytes(full.read_bytes()[:-3])
        _expect_failure(lambda: summarize_trace(truncated, 100), "gzip 截断未拒绝")
        trailing = root / "trailing.trace.gz"
        trailing.write_bytes(full.read_bytes() + b"tail")
        _expect_failure(lambda: summarize_trace(trailing, 100), "gzip 尾垃圾未拒绝")
        multi = root / "multi.trace.gz"
        multi.write_bytes(full.read_bytes() + full.read_bytes())
        _expect_failure(lambda: summarize_trace(multi, 100), "gzip 多 member 未拒绝")

        _expect_failure(lambda: slice_trace(full, full, 102, 103), "输入输出同路径未拒绝")
        empty = root / "empty.gz"
        _expect_failure(lambda: slice_trace(full, empty, 103, 103, 100, 107),
                        "空切片未拒绝")
        assert not empty.exists()
        _expect_failure(lambda: slice_trace(full, root / "reverse.gz", 105, 104, 100, 107),
                        "反向切片未拒绝")
        _expect_failure(lambda: slice_trace(full, root / "oob.gz", 99, 101, 100, 107),
                        "越界切片未拒绝")

    print("PASS: trace gzip/plain manifest、输入/artifact hash、全局/二级切片、")
    print("      gzip 完整性、篡改拒绝、移动恢复和原子边界 smoke")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
