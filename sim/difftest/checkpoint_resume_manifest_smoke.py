#!/usr/bin/env python3
"""resume checkpoint parent/global provenance 的低资源 fixture smoke。"""

from __future__ import annotations

import gzip
import json
import shutil
import sys
from pathlib import Path
from tempfile import TemporaryDirectory

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent
sys.path.insert(0, str(HERE))
import checkpoint  # noqa: E402


def _write_sidecars(chain: Path, seq: int, parent: int) -> None:
    ram = chain / f"base-{seq}.ram.gz"
    dev = chain / f"base-{seq}.dev.gz"
    header = checkpoint.HEADER.pack(checkpoint.MAGIC, checkpoint.VERSION,
                                    checkpoint.PAGE, seq, parent, checkpoint.PAGE,
                                    0, 0)
    with gzip.open(ram, "wb") as stream:
        stream.write(header)
    with gzip.open(dev, "wb") as stream:
        stream.write(b"device fixture\n")
    (chain / "manifest.tsv").write_text(
        f"base\t{seq}\t{parent}\t{checkpoint.PAGE}\t0\t{ram}\t{dev}\n",
        encoding="utf-8",
    )


def _inputs(root: Path) -> tuple[Path, Path, Path, Path]:
    image, dtb, plugin, version = (root / name for name in
                                   ("Image", "dtb", "plugin.so", "VERSION"))
    image.write_bytes(b"image fixture\n")
    dtb.write_bytes(b"dtb fixture\n")
    plugin.write_bytes(b"plugin fixture\n")
    version.write_text("QEMU_VERSION=fixture\n", encoding="utf-8")
    return image, dtb, plugin, version


def _expect_error(fn, label: str) -> None:
    try:
        fn()
    except (ValueError, FileNotFoundError, OSError):
        return
    raise AssertionError(label)


def main() -> int:
    scratch = REPO / "build" / "difftest"
    scratch.mkdir(parents=True, exist_ok=True)
    with TemporaryDirectory(prefix="resume-manifest-", dir=scratch) as raw:
        root = Path(raw)
        image, dtb, plugin, version = _inputs(root)
        qemu = root / "qemu.bin"
        qemu.write_bytes(b"qemu fixture\n")
        parent = root / "parent"
        parent.mkdir()
        checkpoint.init_manifest(
            parent, qemu, version,
            [("image", image), ("dtb", dtb), ("plugin", plugin)],
            {"manifest_lifecycle": "strict", "provenance_kind": "root",
             "global_seq_offset": "0", "qemu_cpu": "fixture"},
        )
        _write_sidecars(parent, 999, (1 << 64) - 1)
        checkpoint.finalize_manifest(parent)
        assert checkpoint._global_offset(checkpoint._read_manifest_meta(parent)) == 0

        child = root / "child"
        child.mkdir()
        parent_hash = checkpoint._sha256_file(parent / "manifest.json")
        checkpoint.init_manifest(
            child, qemu, version,
            [("image", image), ("dtb", dtb), ("plugin", plugin)],
            {
                "manifest_lifecycle": "strict", "provenance_kind": "resume",
                "parent_chain": str(parent.resolve()),
                "parent_manifest_sha256": parent_hash,
                "parent_seq": "999", "parent_local_seq": "999",
                "global_seq_offset": "1000", "local_window_start": "0",
                "local_window_end": "3", "qemu_cpu": "fixture",
            },
        )
        _write_sidecars(child, 2, (1 << 64) - 1)
        checkpoint.finalize_manifest(child)
        rows = checkpoint.read_manifest(child)
        meta = checkpoint._read_manifest_meta(child)
        assert rows[-1].seq == 2
        assert checkpoint._global_offset(meta) == 1000
        assert meta["context"]["artifact_global_first"] == 1002
        out = root / "restored.bin"
        checkpoint.restore_ram(child, 2, out)
        assert out.stat().st_size == checkpoint.PAGE

        # A late provenance failure must not publish the child's pending
        # manifest.  Keep the parent plugin at A and bind the child to plugin
        # B; both chains still have valid sidecars and TSV rows, so the only
        # failure is the existing parent-input binding check.
        plugin_a = root / "plugin-a.so"
        plugin_b = root / "plugin-b.so"
        plugin_a.write_bytes(b"plugin A fixture\n")
        plugin_b.write_bytes(b"plugin B fixture\n")
        atomic_parent = root / "atomic-parent"
        atomic_parent.mkdir()
        checkpoint.init_manifest(
            atomic_parent, qemu, version,
            [("image", image), ("dtb", dtb), ("plugin", plugin_a)],
            {"manifest_lifecycle": "strict", "provenance_kind": "root",
             "global_seq_offset": "0", "qemu_cpu": "fixture"},
        )
        _write_sidecars(atomic_parent, 7, (1 << 64) - 1)
        checkpoint.finalize_manifest(atomic_parent)
        atomic_parent_hash = checkpoint._sha256_file(
            atomic_parent / "manifest.json")

        atomic_child = root / "atomic-child"
        atomic_child.mkdir()
        checkpoint.init_manifest(
            atomic_child, qemu, version,
            [("image", image), ("dtb", dtb), ("plugin", plugin_b)],
            {
                "manifest_lifecycle": "strict", "provenance_kind": "resume",
                "parent_chain": str(atomic_parent.resolve()),
                "parent_manifest_sha256": atomic_parent_hash,
                "parent_seq": "7", "parent_local_seq": "7",
                "global_seq_offset": "8", "local_window_start": "0",
                "local_window_end": "3", "qemu_cpu": "fixture",
            },
        )
        _write_sidecars(atomic_child, 2, (1 << 64) - 1)
        pending_bytes = (atomic_child / "manifest.json").read_bytes()
        pending_meta = json.loads(pending_bytes)
        try:
            checkpoint.finalize_manifest(atomic_child)
        except ValueError as exc:
            assert "输入 plugin 与 parent 摘要不匹配" in str(exc), \
                f"未命中 parent/plugin 摘要校验：{exc}"
        else:
            raise AssertionError("parent/plugin provenance 不匹配未拒绝")
        assert (atomic_child / "manifest.json").read_bytes() == pending_bytes, \
            "late provenance failure 发布了 manifest.json"
        after_pending = checkpoint._read_manifest_meta(atomic_child)
        assert after_pending is not None
        for key in checkpoint.MANIFEST_STATUS_KEYS:
            assert after_pending.get(key) == pending_meta.get(key), \
                f"late provenance failure 改变了 {key} 状态"
        _expect_error(lambda: checkpoint.read_manifest(atomic_child),
                      "失败后的 pending manifest 被错误接受")

        # pending/incomplete manifest 不能作为恢复输入。
        pending = root / "pending"
        pending.mkdir()
        checkpoint.init_manifest(
            pending, qemu, version, [("image", image), ("dtb", dtb), ("plugin", plugin)],
            {"manifest_lifecycle": "strict", "provenance_kind": "root",
             "global_seq_offset": "0"},
        )
        _expect_error(lambda: checkpoint.read_manifest(pending),
                      "pending manifest 被错误接受")

        # child artifact/parent manifest 篡改必须沿 provenance 链拒绝。
        child_ram = child / "base-2.ram.gz"
        child_ram.write_bytes(child_ram.read_bytes() + b"tamper")
        _expect_error(lambda: checkpoint.read_manifest(child),
                      "child artifact 篡改未拒绝")
        child_ram.write_bytes(child_ram.read_bytes()[:-6])
        # 重新生成 child manifest 以恢复 fixture，再篡改 parent JSON。
        checkpoint.finalize_manifest(child)
        parent_json = parent / "manifest.json"
        parent_json.write_text(parent_json.read_text(encoding="utf-8") + " ",
                               encoding="utf-8")
        _expect_error(lambda: checkpoint.read_manifest(child),
                      "parent manifest 篡改未拒绝")

        # 目录冲突由 init_manifest 拒绝，不能追加到 parent。
        _expect_error(lambda: checkpoint.init_manifest(
            parent, qemu, version, [("image", image)], {}),
                      "已有 parent 目录未拒绝")

    print("PASS: resume checkpoint pending/complete、parent hash、local/global seq、")
    print("      artifact tamper、restore 和路径冲突 fixture")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
