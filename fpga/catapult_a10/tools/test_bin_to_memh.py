#!/usr/bin/env python3
"""Small byte-order and final-partial-word test for bin_to_memh.py."""

import tempfile
import unittest
from pathlib import Path

from bin_to_memh import convert


class BinToMemhTests(unittest.TestCase):
    def test_words_are_little_endian_and_last_word_is_zero_padded(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            source = root / "payload.bin"
            output = root / "nested" / "payload.memh"
            source.write_bytes(bytes(range(10)))

            self.assertEqual(convert(source, output), (10, 3))
            self.assertEqual(output.read_text().splitlines(), [
                "03020100", "07060504", "00000908"
            ])

    def test_512_bit_lines_preserve_little_endian_byte_lanes(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            source = root / "payload.bin"
            output = root / "payload.memh"
            payload = bytes(range(70))
            source.write_bytes(payload)

            self.assertEqual(convert(source, output, word_bytes=64), (70, 2))
            words = output.read_text().splitlines()
            self.assertEqual(len(words), 2)
            self.assertEqual(bytes.fromhex(words[0]), payload[:64][::-1])
            self.assertEqual(bytes.fromhex(words[1]), bytes(58) + payload[64:70][::-1])


if __name__ == "__main__":
    unittest.main(verbosity=2)
