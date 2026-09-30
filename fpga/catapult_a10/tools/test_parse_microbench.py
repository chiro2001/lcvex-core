#!/usr/bin/env python3

import unittest

from parse_microbench import (
    EXPECTED_COMPILER_FLAGS,
    ParseError,
    parse_full,
    parse_microbench,
    parse_selfcheck,
)


CRC_FIELDS = "seed=0000E9F5 list=0000E714 matrix=00001FD7 state=00008E3A final=000065C5"


def full_transcript(result_line: str) -> str:
    return "\n".join((
        "2K performance run parameters for coremark.",
        "CoreMark Size    : 666",
        "Total ticks      : 250000000",
        "Total time (secs): 10",
        "Iterations/Sec   : 100",
        "Iterations       : 1000",
        "Compiler version : aarch64-linux-gnu-gcc 16.1.0",
        f"Compiler flags   : {EXPECTED_COMPILER_FLAGS}",
        "Memory location  : 64KiB M20K BRAM",
        "seedcrc          : 0xe9f5",
        "[0]crclist       : 0xe714",
        "[0]crcmatrix     : 0x1fd7",
        "[0]crcstate      : 0x8e3a",
        "[0]crcfinal      : 0x65c5",
        "Correct operation validated. See readme.txt for run and reporting rules.",
        result_line,
        "",
    ))


class MicrobenchParserTest(unittest.TestCase):
    def test_microbench_valid(self):
        parsed = parse_microbench("noise\r\nMBPASS 24 8679CF21\r\n")
        self.assertEqual(parsed["signature"], "8679CF21")

    def test_microbench_rejects_failure_or_wrong_signature(self):
        with self.assertRaises(ParseError):
            parse_microbench("MBFAIL 1 0 1\nMBPASS 24 8679CF21\n")
        with self.assertRaises(ParseError):
            parse_microbench("MBPASS 24 DEADBEEF\n")

    def test_selfcheck_valid_but_never_a_score(self):
        parsed = parse_selfcheck(
            f"CMSELF PASS {CRC_FIELDS} iterations=1 cycles=12345 score=INVALID\r\n"
        )
        self.assertEqual(parsed["score"], "INVALID")
        with self.assertRaises(ParseError):
            parse_selfcheck(
                f"CMSELF PASS {CRC_FIELDS} iterations=1 cycles=12345 score=VALID\n"
            )

    def test_full_valid_and_recomputed(self):
        line = (
            f"CMRESULT VALID {CRC_FIELDS} iterations=1000 cycles=250000000 "
            "hz=25000000 cms_x1000=100000 cmmhz_x1000=4000\n"
        )
        parsed = parse_full(full_transcript(line))
        self.assertEqual(parsed["coremark_per_second_x1000"], 100000)
        self.assertEqual(parsed["upstream_raw_crosscheck"], "PASS")

    def test_full_normalizes_only_verified_windows_right_margin_redraw(self):
        record = (
            "CMRESULT VALID seed=0000E9F5 list=0000E714 matrix=00001FD7 "
            "state=00008E3A final=00005275 iterations=300 cycles=442800996"
        )
        self.assertEqual(len(record), 120)
        wrapped = (
            record + "\r\n\x1b[29;120H" + record[-1]
            + " hz=25000000 cms_x1000=16937 cmmhz_x1000=677"
        )
        transcript = full_transcript(wrapped)
        transcript = transcript.replace(
            "Total ticks      : 250000000", "Total ticks      : 442800996"
        ).replace(
            "Total time (secs): 10", "Total time (secs): 17"
        ).replace(
            "Iterations/Sec   : 100", "Iterations/Sec   : 17"
        ).replace(
            "Iterations       : 1000", "Iterations       : 300"
        ).replace(
            "seedcrc          : 0xe9f5", "seedcrc          : 0xe9f5"
        ).replace(
            "[0]crcfinal      : 0x65c5", "[0]crcfinal      : 0x5275"
        )
        parsed = parse_full(transcript)
        self.assertEqual(parsed["cycles"], 442800996)
        self.assertEqual(parsed["coremark_per_second_x1000"], 16937)
        self.assertEqual(parsed["coremark_per_mhz_x1000"], 677)
        self.assertEqual(parsed["terminal_capture_normalization"], "windows_right_margin_redraw")

    def test_full_rejects_unverified_terminal_redraw(self):
        record = (
            "CMRESULT VALID seed=0000E9F5 list=0000E714 matrix=00001FD7 "
            "state=00008E3A final=00005275 iterations=300 cycles=442800996"
        )
        wrapped = (
            record + "\r\n\x1b[29;119H" + record[-1]
            + " hz=25000000 cms_x1000=16937 cmmhz_x1000=677"
        )
        transcript = full_transcript(wrapped)
        transcript = transcript.replace(
            "Total ticks      : 250000000", "Total ticks      : 442800996"
        ).replace(
            "Total time (secs): 10", "Total time (secs): 17"
        ).replace(
            "Iterations/Sec   : 100", "Iterations/Sec   : 17"
        ).replace(
            "Iterations       : 1000", "Iterations       : 300"
        ).replace(
            "[0]crcfinal      : 0x65c5", "[0]crcfinal      : 0x5275"
        )
        with self.assertRaisesRegex(ParseError, "unverified Windows terminal right-margin redraw"):
            parse_full(transcript)

    def test_full_rejects_short_crc_forgery_and_firmware_invalid(self):
        valid_tail = "iterations=1000 cycles=250000000 hz=25000000 cms_x1000=100000 cmmhz_x1000=4000"
        with self.assertRaises(ParseError):
            parse_full(full_transcript(
                f"CMRESULT VALID {CRC_FIELDS} iterations=1000 cycles=249999999 "
                "hz=25000000 cms_x1000=100000 cmmhz_x1000=4000\n"
            ))
        with self.assertRaises(ParseError):
            parse_full(full_transcript(f"CMRESULT VALID {CRC_FIELDS.replace('0000E714', '0000E715')} {valid_tail}"))
        with self.assertRaises(ParseError):
            parse_full(full_transcript(f"CMRESULT VALID {CRC_FIELDS} {valid_tail.replace('cms_x1000=100000', 'cms_x1000=99999')}"))
        with self.assertRaises(ParseError):
            parse_full(full_transcript(f"CMRESULT INVALID reason=00000002 {CRC_FIELDS} {valid_tail}"))

    def test_full_rejects_tampered_upstream_raw_report(self):
        line = (
            f"CMRESULT VALID {CRC_FIELDS} iterations=1000 cycles=250000000 "
            "hz=25000000 cms_x1000=100000 cmmhz_x1000=4000"
        )
        with self.assertRaises(ParseError):
            parse_full(full_transcript(line).replace("Total ticks      : 250000000", "Total ticks      : 250000001"))
        with self.assertRaises(ParseError):
            parse_full(full_transcript(line).replace("Correct operation validated.", "ERROR! operation invalid."))

    def test_duplicate_result_is_rejected(self):
        line = (
            f"CMRESULT VALID {CRC_FIELDS} iterations=1000 cycles=250000000 "
            "hz=25000000 cms_x1000=100000 cmmhz_x1000=4000\n"
        )
        with self.assertRaises(ParseError):
            parse_full(full_transcript(line) + full_transcript(line))


if __name__ == "__main__":
    unittest.main()
