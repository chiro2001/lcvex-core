#!/usr/bin/env python3
"""Host-side format and hostile-descriptor tests for the Linux Flash payload."""

from __future__ import annotations

import copy
import struct
import subprocess
import sys
import tempfile
import unittest
import zlib
from pathlib import Path

from linux_image_format import (
    FormatError,
    build_payload,
    crc32_lookup_table,
    crc32_table_assembly,
    intel_hex,
    load_layout,
    loader_assembly_constants,
    parse_payload,
    validate_layout,
)


LAYOUT_PATH = Path(__file__).with_name("linux_flash_layout.json")


def make_image(text_offset: int = 0x800, image_size: int = 0x2000) -> bytes:
    image = bytearray(128)
    struct.pack_into("<Q", image, 8, text_offset)
    struct.pack_into("<Q", image, 16, image_size)
    struct.pack_into("<I", image, 56, 0x644D5241)
    return bytes(image)


def make_dtb(total_size: int = 64) -> bytes:
    dtb = bytearray(total_size)
    struct.pack_into(">II", dtb, 0, 0xD00DFEED, total_size)
    return bytes(dtb)


def recalculate_descriptor_crc(blob: bytearray) -> None:
    count = struct.unpack_from("<I", blob, 16)[0]
    metadata_size = 40 + count * 32
    struct.pack_into("<II", blob, metadata_size, zlib.crc32(blob[:metadata_size]) & 0xFFFFFFFF, 0)


class LinuxImageFormatTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.layout = load_layout(LAYOUT_PATH)
        cls.image = make_image()
        cls.dtb = make_dtb()
        cls.blob = build_payload(cls.layout, cls.image, cls.dtb)

    def test_builds_valid_aarch64_payload_and_crc_fields(self) -> None:
        parsed = parse_payload(self.blob, self.layout)
        values = validate_layout(self.layout)
        self.assertEqual(parsed["version"], 1)
        self.assertEqual(parsed["entry_address"], 0x40200800)
        self.assertEqual(parsed["dtb_address"], 0x47000000)
        self.assertEqual(len(parsed["segments"]), 2)

        kernel = next(s for s in parsed["segments"] if s["kind"] == values["kernel_kind"])
        dtb = next(s for s in parsed["segments"] if s["kind"] == values["dtb_kind"])
        self.assertEqual(kernel["flash_offset"], values["payload_offset"] + 0x1000)
        self.assertEqual(kernel["length"], 0x2000)  # padded to Image.image_size
        self.assertEqual(dtb["load_address"], values["dtb_address"])
        self.assertEqual(dtb["data"], self.dtb)
        self.assertEqual(kernel["data"][: len(self.image)], self.image)
        self.assertEqual(kernel["data"][len(self.image) :], bytes(0x2000 - len(self.image)))
        self.assertEqual(kernel["crc32"], zlib.crc32(kernel["data"]) & 0xFFFFFFFF)
        self.assertEqual(dtb["crc32"], zlib.crc32(self.dtb) & 0xFFFFFFFF)
        self.assertEqual(parsed["descriptor_crc32"], zlib.crc32(self.blob[:104]) & 0xFFFFFFFF)

    def test_crc_variant_is_crc32_iso_hdlc(self) -> None:
        self.assertEqual(zlib.crc32(b"123456789") & 0xFFFFFFFF, 0xCBF43926)

    def test_loader_crc_lookup_table_matches_zlib_and_assembly_output(self) -> None:
        table = crc32_lookup_table()
        self.assertEqual(len(table), 256)
        self.assertEqual(table[0], 0x00000000)
        self.assertEqual(table[1], 0x77073096)
        self.assertEqual(table[255], 0x2D02EF8D)

        def table_crc32(data: bytes) -> int:
            crc = 0xFFFFFFFF
            for byte in data:
                crc = (crc >> 8) ^ table[(crc ^ byte) & 0xFF]
            return crc ^ 0xFFFFFFFF

        for data in (b"", b"123456789", bytes(range(256)), bytes(range(256)) * 17):
            self.assertEqual(table_crc32(data), zlib.crc32(data) & 0xFFFFFFFF)

        assembly_words = [
            int(value, 16)
            for line in crc32_table_assembly().splitlines()
            if line.strip().startswith(".word ")
            for value in line.split(None, 1)[1].split(", ")
        ]
        self.assertEqual(assembly_words, list(table))

    def test_segment_payload_corruption_fails_its_crc(self) -> None:
        parsed = parse_payload(self.blob, self.layout)
        kernel = next(s for s in parsed["segments"] if s["kind"] == 1)
        damaged = bytearray(self.blob)
        damaged[int(kernel["relative_offset"]) + 17] ^= 0x80
        with self.assertRaisesRegex(FormatError, "kernel segment CRC32 mismatch"):
            parse_payload(bytes(damaged), self.layout)

    def test_descriptor_corruption_fails_descriptor_crc(self) -> None:
        damaged = bytearray(self.blob)
        damaged[24] ^= 0x01  # entry address
        with self.assertRaisesRegex(FormatError, "descriptor CRC32 mismatch"):
            parse_payload(bytes(damaged), self.layout)

    def test_rejects_absolute_flash_source_out_of_range(self) -> None:
        values = validate_layout(self.layout)
        damaged = bytearray(self.blob)
        struct.pack_into("<Q", damaged, 40, int(values["flash_capacity"]) - 0x1000)
        recalculate_descriptor_crc(damaged)
        with self.assertRaisesRegex(FormatError, "outside physical Flash/aperture"):
            parse_payload(bytes(damaged), self.layout)

    def test_rejects_flash_source_integer_overflow(self) -> None:
        damaged = bytearray(self.blob)
        struct.pack_into("<Q", damaged, 40, 0xFFFFFFFFFFFFF000)
        recalculate_descriptor_crc(damaged)
        with self.assertRaisesRegex(FormatError, "overflows a 64-bit address"):
            parse_payload(bytes(damaged), self.layout)

    def test_rejects_misaligned_ddr_destination(self) -> None:
        damaged = bytearray(self.blob)
        struct.pack_into("<Q", damaged, 48, 0x40200001)
        recalculate_descriptor_crc(damaged)
        with self.assertRaisesRegex(FormatError, "kernel destination is not aligned"):
            parse_payload(bytes(damaged), self.layout)

    def test_rejects_misaligned_flash_source(self) -> None:
        damaged = bytearray(self.blob)
        struct.pack_into("<Q", damaged, 40, 0x04001001)
        recalculate_descriptor_crc(damaged)
        with self.assertRaisesRegex(FormatError, "Flash source is not aligned"):
            parse_payload(bytes(damaged), self.layout)

    def test_rejects_overlapping_ddr_segments(self) -> None:
        damaged = bytearray(self.blob)
        struct.pack_into("<Q", damaged, 40 + 32 + 8, 0x40201000)
        struct.pack_into("<Q", damaged, 32, 0x40201000)
        recalculate_descriptor_crc(damaged)
        with self.assertRaisesRegex(FormatError, "DDR ranges overlap"):
            parse_payload(bytes(damaged), self.layout)

    def test_rejects_overlapping_flash_segments(self) -> None:
        parsed = parse_payload(self.blob, self.layout)
        kernel = next(s for s in parsed["segments"] if s["kind"] == 1)
        damaged = bytearray(self.blob)
        dtb_descriptor = 40 + 32
        struct.pack_into("<Q", damaged, dtb_descriptor, int(kernel["flash_offset"]))
        kernel_data = bytes(kernel["data"][: len(self.dtb)])
        struct.pack_into("<I", damaged, dtb_descriptor + 24, zlib.crc32(kernel_data) & 0xFFFFFFFF)
        recalculate_descriptor_crc(damaged)
        with self.assertRaisesRegex(FormatError, "Flash ranges overlap"):
            parse_payload(bytes(damaged), self.layout)

    def test_rejects_segment_reordering_unsupported_by_loader(self) -> None:
        damaged = bytearray(self.blob)
        first = bytes(damaged[40:72])
        second = bytes(damaged[72:104])
        damaged[40:72] = second
        damaged[72:104] = first
        recalculate_descriptor_crc(damaged)
        with self.assertRaisesRegex(FormatError, "segment order must be kernel followed by DTB"):
            parse_payload(bytes(damaged), self.layout)

    def test_rejects_out_of_range_ddr_span(self) -> None:
        damaged = bytearray(self.blob)
        struct.pack_into("<Q", damaged, 48, 0x47FFF000)
        recalculate_descriptor_crc(damaged)
        with self.assertRaisesRegex(FormatError, "kernel DDR range is outside configured memory"):
            parse_payload(bytes(damaged), self.layout)

    def test_builder_rejects_bad_linux_inputs_and_layout_overlap(self) -> None:
        bad_image = bytearray(self.image)
        struct.pack_into("<I", bad_image, 56, 0x12345678)
        with self.assertRaisesRegex(FormatError, "AArch64 Linux Image magic"):
            build_payload(self.layout, bytes(bad_image), self.dtb)

        overlap = copy.deepcopy(self.layout)
        overlap["ddr"]["dtb_address"] = "0x40201000"
        with self.assertRaisesRegex(FormatError, "kernel and DTB DDR ranges overlap"):
            build_payload(overlap, self.image, self.dtb)

    def test_layout_rejects_misaligned_payload_base(self) -> None:
        malformed = copy.deepcopy(self.layout)
        malformed["flash"]["payload_offset"] = "0x04000001"
        with self.assertRaisesRegex(FormatError, "payload_offset is not aligned"):
            validate_layout(malformed)

    def test_builder_rejects_hostile_image_size_without_padding_it(self) -> None:
        hostile = bytearray(self.image)
        struct.pack_into("<Q", hostile, 16, 0xFFFFFFFFFFFFFFF0)
        with self.assertRaisesRegex(FormatError, "image_size exceeds configured DDR/Flash capacity"):
            build_payload(self.layout, bytes(hostile), self.dtb)

    def test_cli_writes_bin_and_relative_hex(self) -> None:
        tool = Path(__file__).with_name("linux_image_format.py")
        with tempfile.TemporaryDirectory(prefix="lcvex-linux-payload-") as temp:
            root = Path(temp)
            image_path = root / "Image"
            dtb_path = root / "board.dtb"
            bin_path = root / "flash_data.bin"
            hex_path = root / "flash_data.hex"
            image_path.write_bytes(self.image)
            dtb_path.write_bytes(self.dtb)
            result = subprocess.run(
                [
                    sys.executable,
                    str(tool),
                    "build",
                    "--layout",
                    str(LAYOUT_PATH),
                    "--image",
                    str(image_path),
                    "--dtb",
                    str(dtb_path),
                    "--bin",
                    str(bin_path),
                    "--hex",
                    str(hex_path),
                ],
                check=False,
                text=True,
                capture_output=True,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(bin_path.read_bytes(), self.blob)
            first_hex_record = hex_path.read_text(encoding="ascii").splitlines()[0]
            self.assertEqual(first_hex_record, ":020000040000FA")

    def test_hex_records_are_blob_relative_and_checksum_valid(self) -> None:
        lines = intel_hex(self.blob).splitlines()
        self.assertEqual(lines[-1], ":00000001FF")
        current_upper = 0
        first_data_start: int | None = None
        last_data_end: int | None = None
        for line in lines:
            record = bytes.fromhex(line[1:])
            self.assertEqual(sum(record) & 0xFF, 0)
            kind = record[3]
            if kind == 4:
                current_upper = int.from_bytes(record[4:6], "big")
            elif kind == 0:
                address = int.from_bytes(record[1:3], "big")
                data_start = (current_upper << 16) + address
                first_data_start = data_start if first_data_start is None else first_data_start
                last_data_end = data_start + record[0] - 1
        self.assertEqual(first_data_start, 0)
        self.assertEqual(last_data_end, len(self.blob) - 1)
        self.assertEqual(current_upper, 0)
        self.assertLess(len(self.blob) - 1, int(validate_layout(self.layout)["payload_offset"]))

    def test_loader_constants_come_from_shared_layout(self) -> None:
        constants = loader_assembly_constants(self.layout)
        self.assertIn(".equ FLASH_APERTURE_BASE, 0x10000000", constants)
        self.assertIn(".equ FLASH_PAYLOAD_OFFSET, 0x4000000", constants)
        self.assertIn(".equ DDR_BASE, 0x40000000", constants)
        self.assertIn(".equ DDR_ALIGNMENT, 0x1000", constants)


if __name__ == "__main__":
    unittest.main(verbosity=2)
