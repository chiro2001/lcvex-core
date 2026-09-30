#!/usr/bin/env python3
"""Convert a byte image to little-endian 32-bit or 512-bit $readmemh words."""

from __future__ import annotations

import argparse
from pathlib import Path


def convert(source: Path, destination: Path, word_bytes: int = 4) -> tuple[int, int]:
    if word_bytes not in (4, 64):
        raise ValueError("word_bytes must be 4 or 64")
    byte_count = 0
    word_count = 0
    destination.parent.mkdir(parents=True, exist_ok=True)
    with source.open("rb") as src, destination.open("w", encoding="ascii", newline="\n") as dst:
        while chunk := src.read(word_bytes):
            byte_count += len(chunk)
            word = int.from_bytes(chunk + bytes(word_bytes - len(chunk)), "little")
            dst.write(f"{word:0{word_bytes * 2}x}\n")
            word_count += 1
    return byte_count, word_count


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--word-bytes", type=int, choices=(4, 64), default=4)
    args = parser.parse_args()
    byte_count, word_count = convert(args.input, args.output, args.word_bytes)
    print(f"BIN_TO_MEMH_PASS bytes={byte_count} words={word_count} word_bytes={args.word_bytes} endian=little")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
