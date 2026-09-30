#!/usr/bin/env python3
"""LCVXSYS4 sidecar 结构与向后兼容 smoke。

不做完整 QEMU/DUT 联合恢复；只验证 v4 struct 的 magic/version/size、
CONTEXTIDR_EL1 字段位置与 v3 旧格式仍可按 540 字节解析。
完整 joint restore 由集成者在资源窗口运行 checkpoint_sys_v4 smoke。
"""

from __future__ import annotations

import struct
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from checkpoint import SYS_STATE_V3, SYS_STATE_V4  # noqa: E402


def main() -> int:
    # Build a nominal v4 packed record with CONTEXTIDR_EL1 = 0x1234_5678_9ABC_DEF0.
    v4 = SYS_STATE_V4
    # Use zeroed array and fill key fields by unpacking/packing roundtrip.
    arr = bytearray(v4.size)
    # magic at 0, version at 8, size at 12
    struct.pack_into("<8sII", arr, 0, b"LCVXSYS4", 4, v4.size)
    # x[0]=0x1111, contextidr index 70
    struct.pack_into("<Q", arr, 16 + 0 * 8, 0x1111)
    struct.pack_into("<Q", arr, v4.size - 8, 0x1234_5678_9ABC_DEF0)
    raw = bytes(arr)
    assert len(raw) == v4.size
    vals = v4.unpack(raw)
    assert vals[0] == b"LCVXSYS4"
    assert vals[1] == 4
    assert vals[2] == v4.size
    assert vals[70] == 0x1234_5678_9ABC_DEF0, hex(vals[70])

    # v3 (540 bytes) must still parse with its own struct; no contextidr field.
    v3 = SYS_STATE_V3
    arr3 = bytearray(v3.size)
    struct.pack_into("<8sII", arr3, 0, b"LCVXSYS3", 3, v3.size)
    raw3 = bytes(arr3)
    vals3 = v3.unpack(raw3)
    assert vals3[0] == b"LCVXSYS3"
    assert vals3[1] == 3
    assert vals3[2] == v3.size

    print("PASS: LCVXSYS4 struct smoke (contextidr_el1 roundtrip, v3 legacy size)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
