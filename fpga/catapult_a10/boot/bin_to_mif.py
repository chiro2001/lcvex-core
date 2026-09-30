#!/usr/bin/env python3
"""Convert one AArch64 binary image to byte HEX and an Intel MIF.

The BRAM is physically 64 KiB = 8192 x 64-bit words.  MIF byte lane zero is
the least-significant byte of each 64-bit word, matching the little-endian
byte HEX consumed by the behavioral BRAM model.  The generated MIF is fully
populated, so bytes beyond the ELF load image are deterministic zeroes.
"""

from __future__ import annotations

import argparse
import hashlib
import re
import sys
from pathlib import Path


DEFAULT_WIDTH = 64
DEFAULT_DEPTH = 8192
MIF_LINE = re.compile(r"^\s*([0-9A-Fa-f]+)\s*:\s*([0-9A-Fa-f]+)\s*;\s*$")


def _parent(path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)


def _word(data: bytes, offset: int, width_bytes: int) -> int:
    chunk = data[offset : offset + width_bytes]
    return int.from_bytes(chunk.ljust(width_bytes, b"\0"), "little")


def write_hex(data: bytes, path: Path) -> None:
    _parent(path)
    # One byte per line is the stable $readmemh/program-loader format.
    path.write_text("".join(f"{byte:02x}\n" for byte in data), encoding="ascii")


def read_hex_bytes(path: Path) -> bytes:
    values = []
    for line_number, raw in enumerate(path.read_text(encoding="ascii").splitlines(), 1):
        token = raw.strip()
        if not token:
            continue
        if len(token) != 2:
            raise ValueError(f"invalid byte HEX record at {path}:{line_number}")
        try:
            values.append(int(token, 16))
        except ValueError as exc:
            raise ValueError(f"invalid byte HEX record at {path}:{line_number}") from exc
    return bytes(values)


def write_mif(data: bytes, path: Path, width: int, depth: int) -> None:
    width_bytes = width // 8
    digits = (width + 3) // 4
    address_digits = max(1, ((depth - 1).bit_length() + 3) // 4)
    lines = [
        "-- LCVEX B25 BRAM image; byte lane 0 is DATA[7:0] (little endian)",
        f"WIDTH={width};",
        f"DEPTH={depth};",
        "ADDRESS_RADIX=HEX;",
        "DATA_RADIX=HEX;",
        "CONTENT BEGIN",
    ]
    for index in range(depth):
        value = _word(data, index * width_bytes, width_bytes)
        lines.append(f"{index:0{address_digits}X} : {value:0{digits}X};")
    lines.append("END;")
    _parent(path)
    path.write_text("\n".join(lines) + "\n", encoding="ascii")


def read_mif_bytes(path: Path, width: int, depth: int) -> bytes:
    """Read the explicit address records emitted by :func:`write_mif`."""

    width_bytes = width // 8
    values: list[int | None] = [None] * depth
    in_content = False
    for line_number, raw in enumerate(path.read_text(encoding="ascii").splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("--"):
            continue
        if line.upper() == "CONTENT BEGIN":
            in_content = True
            continue
        if line.upper() == "END;":
            break
        if not in_content:
            continue
        match = MIF_LINE.match(raw)
        if match is None:
            raise ValueError(f"invalid MIF record at {path}:{line_number}")
        address = int(match.group(1), 16)
        value = int(match.group(2), 16)
        if address >= depth:
            raise ValueError(f"MIF address 0x{address:X} exceeds depth {depth}")
        if value >= (1 << width):
            raise ValueError(f"MIF value at address 0x{address:X} exceeds width {width}")
        if values[address] is not None:
            raise ValueError(f"duplicate MIF address 0x{address:X}")
        values[address] = value
    if not in_content or any(value is None for value in values):
        raise ValueError("MIF does not contain one explicit record for every word")
    return b"".join(int(value).to_bytes(width_bytes, "little") for value in values)


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary_arg", nargs="?", type=Path, help="input binary")
    parser.add_argument("mif_arg", nargs="?", type=Path, help="output MIF")
    parser.add_argument("--input", "--bin", dest="binary", type=Path)
    parser.add_argument("--output", "--mif", dest="mif", type=Path)
    parser.add_argument("--hex", dest="hex_path", type=Path,
                        help="optional output byte HEX (one byte per line)")
    parser.add_argument("--width", type=int, default=DEFAULT_WIDTH)
    parser.add_argument("--depth", type=int, default=DEFAULT_DEPTH)
    parser.add_argument("--no-verify", action="store_true",
                        help="skip the post-write byte-for-byte MIF readback")
    args = parser.parse_args(argv)
    args.binary = args.binary or args.binary_arg
    args.mif = args.mif or args.mif_arg
    if args.binary is None or args.mif is None:
        parser.error("input binary and output MIF are required")
    if args.width <= 0 or args.width % 8:
        parser.error("--width must be a positive multiple of 8")
    if args.depth <= 0:
        parser.error("--depth must be positive")
    return args


def main(argv: list[str] | None = None) -> int:
    args = parse_args(sys.argv[1:] if argv is None else argv)
    data = args.binary.read_bytes()
    capacity = args.depth * (args.width // 8)
    if len(data) > capacity:
        raise ValueError(
            f"input image is {len(data)} bytes, larger than MIF capacity {capacity}"
        )
    write_mif(data, args.mif, args.width, args.depth)
    if args.hex_path is not None:
        write_hex(data, args.hex_path)
    if not args.no_verify:
        if args.hex_path is not None and read_hex_bytes(args.hex_path) != data:
            raise ValueError("byte HEX verification failed")
        image = read_mif_bytes(args.mif, args.width, args.depth)
        expected = data.ljust(capacity, b"\0")
        if image != expected:
            for index, (actual, wanted) in enumerate(zip(image, expected)):
                if actual != wanted:
                    raise ValueError(
                        f"MIF byte mismatch at offset 0x{index:X}: "
                        f"got 0x{actual:02X}, expected 0x{wanted:02X}"
                    )
            raise ValueError("MIF byte-for-byte verification failed")
    print(
        "BRAM_IMAGE_PASS "
        f"bin={args.binary} bytes={len(data)} "
        f"hex={args.hex_path if args.hex_path else '-'} "
        f"mif={args.mif} width={args.width} depth={args.depth} "
        f"bin_sha256={sha256(args.binary)} mif_sha256={sha256(args.mif)}"
    )
    if args.hex_path is not None:
        print(f"hex_sha256={sha256(args.hex_path)}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError) as exc:
        print(f"BRAM_IMAGE_FAIL: {exc}", file=sys.stderr)
        raise SystemExit(1)
