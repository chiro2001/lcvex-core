#!/usr/bin/env python3
"""checkpoint manifest 的低资源正/反向校验 smoke。"""

from __future__ import annotations

import sys
from pathlib import Path
from tempfile import TemporaryDirectory

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent
sys.path.insert(0, str(HERE))
import checkpoint  # noqa: E402


def main() -> int:
    scratch = REPO / "build" / "difftest"
    scratch.mkdir(parents=True, exist_ok=True)
    with TemporaryDirectory(prefix="checkpoint-manifest-", dir=scratch) as raw:
        root = Path(raw)
        chain = root / "chain"
        image = root / "Image.bin"
        qemu = root / "qemu.bin"
        version = root / "VERSION"
        image.write_bytes(b"LCVX manifest image\n")
        qemu.write_bytes(b"LCVX qemu build\n")
        version.write_text("QEMU_VERSION=fixture\n", encoding="utf-8")
        checkpoint.init_manifest(
            chain, qemu, version, [("image", image)], {"kernel": "0"}
        )
        ram = chain / "base-0.ram.gz"
        dev = chain / "base-0.dev.gz"
        ram.write_bytes(b"ram fixture\n")
        dev.write_bytes(b"device fixture\n")
        (chain / "manifest.tsv").write_text(
            "base\t0\t18446744073709551615\t4096\t0\t"
            f"{ram}\t{dev}\n",
            encoding="utf-8",
        )
        checkpoint.finalize_manifest(chain)
        checkpoint.read_manifest(chain)
        dev.write_bytes(dev.read_bytes() + b"tamper\n")
        try:
            checkpoint.read_manifest(chain)
        except ValueError as exc:
            if "SHA256" not in str(exc) and "文件大小改变" not in str(exc):
                raise AssertionError(f"未命中文件完整性校验：{exc}") from exc
        else:
            raise AssertionError("篡改 checkpoint artifact 未被拒绝")
    print("PASS: checkpoint manifest 输入/链/artifact SHA256 校验")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
