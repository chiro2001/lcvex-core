#!/usr/bin/env python3
"""Host-side tests for the EPCQL1024 COF generator."""

from __future__ import annotations

import json
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ElementTree
from pathlib import Path

from linux_flash_cof import CofError, build_cof, intel_hex_extent, load_layout


LAYOUT_PATH = Path(__file__).with_name("linux_flash_layout.json")


def write_hex(path: Path, payload: bytes, record_bytes: int = 16) -> None:
    lines = []
    upper = 0
    offset = 0
    while offset < len(payload):
        absolute = offset
        next_upper = absolute >> 16
        if next_upper != upper:
            upper = next_upper
            lines.append(
                f":02000004{upper:04X}"
                + f"{(-(6 + (upper >> 8) + (upper & 0xFF))) & 0xFF:02X}"
            )
        low = absolute & 0xFFFF
        count = min(record_bytes, len(payload) - offset, 0x10000 - low)
        chunk = payload[offset : offset + count]
        body = bytes([count]) + low.to_bytes(2, "big") + b"\x00" + chunk
        lines.append(":" + body.hex().upper() + f"{(-sum(body)) & 0xFF:02X}")
        offset += count
    lines.append(":00000001FF")
    path.write_text("\n".join(lines) + "\n", encoding="ascii")


class CofGeneratorTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.layout = json.loads(LAYOUT_PATH.read_text(encoding="utf-8"))
        self.sof = self.root / "catapult_a10.sof"
        self.sof.write_bytes(b"SOF" * 64)

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def test_extent_reports_zero_based_payload(self) -> None:
        blob = bytes(range(256)) * 400
        hex_path = self.root / "payload.hex"
        write_hex(hex_path, blob)
        self.assertEqual(intel_hex_extent(hex_path), (0, len(blob)))

    def test_build_emits_relative_offset_and_absolute_end(self) -> None:
        blob = b"\x5a" * (3 * 0x10000 + 7)
        hex_path = self.root / "payload.hex"
        write_hex(hex_path, blob)
        cof_path = self.root / "linux_flash.cof"
        summary = build_cof(
            layout=self.layout,
            sof=self.sof,
            hex_path=hex_path,
            cof_path=cof_path,
            jic_name="lcvex_linux.jic",
        )
        offset = int(self.layout["flash"]["payload_offset"], 0)
        self.assertEqual(summary["payload_bytes"], len(blob))
        self.assertEqual(summary["payload_end"], offset + len(blob))

        root = ElementTree.parse(cof_path).getroot()
        self.assertEqual(root.findtext("eprom_name"), "EPCQL1024")
        self.assertEqual(root.findtext("flash_loader_device"), "10AX115N4")
        self.assertEqual(root.findtext("output_filename"), "lcvex_linux.jic")
        self.assertEqual(root.findtext("sof_data/bit0/sof_filename"), self.sof.as_posix())
        self.assertEqual(root.findtext("hex_block/hex_filename"), hex_path.as_posix())
        self.assertEqual(root.findtext("hex_block/hex_addressing"), "relative")
        self.assertEqual(int(root.findtext("hex_block/hex_offset")), offset)

    def test_rejects_payload_that_overflows_flash(self) -> None:
        capacity = int(self.layout["flash"]["physical_capacity"], 0)
        offset = int(self.layout["flash"]["payload_offset"], 0)
        blob = b"\x00" * (capacity - offset + 1)
        hex_path = self.root / "payload.hex"
        write_hex(hex_path, blob)
        with self.assertRaises(CofError):
            build_cof(
                layout=self.layout,
                sof=self.sof,
                hex_path=hex_path,
                cof_path=self.root / "overflow.cof",
                jic_name="overflow.jic",
            )

    def test_rejects_relative_hex_that_does_not_start_at_zero(self) -> None:
        hex_path = self.root / "offset.hex"
        hex_path.write_text(
            ":1000100000000000000000000000000000000000FA\n:00000001FF\n",
            encoding="ascii",
        )
        with self.assertRaises(CofError):
            build_cof(
                layout=self.layout,
                sof=self.sof,
                hex_path=hex_path,
                cof_path=self.root / "offset.cof",
                jic_name="offset.jic",
            )

    def test_rejects_missing_sof(self) -> None:
        hex_path = self.root / "payload.hex"
        write_hex(hex_path, b"\x11" * 32)
        with self.assertRaises(CofError):
            build_cof(
                layout=self.layout,
                sof=self.root / "absent.sof",
                hex_path=hex_path,
                cof_path=self.root / "absent.cof",
                jic_name="absent.jic",
            )

    def test_missing_layout_field_is_reported(self) -> None:
        layout = json.loads(LAYOUT_PATH.read_text(encoding="utf-8"))
        del layout["flash"]["payload_offset"]
        path = self.root / "bad_layout.json"
        path.write_text(json.dumps(layout), encoding="utf-8")
        with self.assertRaises(CofError):
            load_layout(path)


if __name__ == "__main__":
    sys.exit(unittest.main(verbosity=2))
