#!/usr/bin/env python3
"""Generate the EPCQL1024 conversion file for the LCVEX Linux Flash image.

The COF combines the FPGA configuration (SOF) with the payload-relative
Intel HEX built by ``linux_image_format.py``.  ``hex_offset`` is the absolute
Flash byte offset of the payload and is applied exactly once, which is why the
HEX itself stays relative to the payload start.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path


class CofError(RuntimeError):
    """Raised when the requested conversion inputs violate the layout."""


def load_layout(path: Path) -> dict:
    try:
        layout = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise CofError(f"cannot read layout {path}: {exc}") from exc
    flash = layout.get("flash") or {}
    for field in ("physical_capacity", "payload_offset"):
        if field not in flash:
            raise CofError(f"layout flash.{field} is missing")
    return layout


def parse_int(value: str) -> int:
    return int(value, 0)


def intel_hex_extent(path: Path) -> tuple[int, int]:
    """Return (lowest, exclusive-highest) byte address referenced by a HEX file."""
    lowest = None
    highest = 0
    upper = 0
    for number, raw in enumerate(path.read_text(encoding="ascii").splitlines(), 1):
        line = raw.strip()
        if not line:
            continue
        if not line.startswith(":"):
            raise CofError(f"{path}:{number}: record does not start with ':'")
        try:
            payload = bytes.fromhex(line[1:])
        except ValueError as exc:
            raise CofError(f"{path}:{number}: malformed record: {exc}") from exc
        if len(payload) < 5:
            raise CofError(f"{path}:{number}: record is too short")
        length = payload[0]
        offset = int.from_bytes(payload[1:3], "big")
        kind = payload[3]
        data = payload[4 : 4 + length]
        if len(data) != length:
            raise CofError(f"{path}:{number}: truncated data field")
        if kind == 0:
            start = (upper << 16) + offset
            if lowest is None or start < lowest:
                lowest = start
            highest = max(highest, start + length)
        elif kind == 4:
            upper = int.from_bytes(data, "big")
    if lowest is None:
        raise CofError(f"{path}: no data records")
    return lowest, highest


def build_cof(
    *,
    layout: dict,
    sof: Path,
    hex_path: Path,
    cof_path: Path,
    jic_name: str,
) -> dict:
    flash = layout["flash"]
    payload_offset = parse_int(str(flash["payload_offset"]))
    capacity = parse_int(str(flash["physical_capacity"]))
    if payload_offset % 0x10000:
        raise CofError(f"payload_offset {payload_offset:#x} is not 64 KiB aligned")
    low, high = intel_hex_extent(hex_path)
    if low != 0:
        raise CofError(f"HEX must start at payload-relative address 0, got {low:#x}")
    if payload_offset + high > capacity:
        raise CofError(
            f"payload end {payload_offset + high:#x} exceeds Flash capacity {capacity:#x}"
        )
    if not sof.is_file():
        raise CofError(f"SOF not found: {sof}")

    cof = f"""<?xml version="1.0" encoding="US-ASCII" standalone="yes"?>
<cof>
\t<eprom_name>EPCQL1024</eprom_name>
\t<flash_loader_device>10AX115N4</flash_loader_device>
\t<output_filename>{jic_name}</output_filename>
\t<n_pages>1</n_pages>
\t<width>1</width>
\t<mode>13</mode>
\t<sof_data>
\t\t<user_name>Page_0</user_name>
\t\t<page_flags>1</page_flags>
\t\t<bit0>
\t\t\t<sof_filename>{sof.as_posix()}</sof_filename>
\t\t</bit0>
\t</sof_data>
\t<hex_block>
\t\t<hex_filename>{hex_path.as_posix()}</hex_filename>
\t\t<hex_addressing>relative</hex_addressing>
\t\t<hex_offset>{payload_offset}</hex_offset>
\t\t<hex_little_endian>0</hex_little_endian>
\t</hex_block>
\t<version>10</version>
\t<create_cvp_file>0</create_cvp_file>
\t<create_hps_iocsr>0</create_hps_iocsr>
\t<auto_create_rpd>0</auto_create_rpd>
\t<rpd_little_endian>1</rpd_little_endian>
\t<options>
\t\t<map_file>1</map_file>
\t\t<boot_page>Page_0</boot_page>
\t</options>
\t<advanced_options>
\t\t<ignore_epcs_id_check>1</ignore_epcs_id_check>
\t\t<ignore_condone_check>2</ignore_condone_check>
\t\t<plc_adjustment>0</plc_adjustment>
\t\t<post_chain_bitstream_pad_bytes>-1</post_chain_bitstream_pad_bytes>
\t\t<post_device_bitstream_pad_bytes>-1</post_device_bitstream_pad_bytes>
\t\t<bitslice_pre_padding>1</bitslice_pre_padding>
\t</advanced_options>
</cof>
"""
    cof_path.parent.mkdir(parents=True, exist_ok=True)
    cof_path.write_text(cof, encoding="ascii")
    return {
        "cof": str(cof_path),
        "payload_offset": payload_offset,
        "payload_bytes": high,
        "payload_end": payload_offset + high,
        "flash_capacity": capacity,
        "jic_name": jic_name,
    }


def build_command(args: argparse.Namespace) -> int:
    layout = load_layout(args.layout)
    summary = build_cof(
        layout=layout,
        sof=args.sof,
        hex_path=args.hex,
        cof_path=args.cof_out,
        jic_name=args.jic_name,
    )
    print(
        "LINUX_FLASH_COF "
        f"cof={summary['cof']} jic={summary['jic_name']} "
        f"payload_offset={summary['payload_offset']:#x} "
        f"payload_bytes={summary['payload_bytes']} "
        f"payload_end={summary['payload_end']:#x} "
        f"capacity={summary['flash_capacity']:#x}"
    )
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    build = sub.add_parser("build", help="emit the EPCQL1024 COF")
    build.add_argument("--layout", type=Path, required=True)
    build.add_argument("--sof", type=Path, required=True)
    build.add_argument("--hex", type=Path, required=True)
    build.add_argument("--cof-out", type=Path, required=True)
    build.add_argument("--jic-name", default="lcvex_linux.jic")
    build.set_defaults(func=build_command)
    args = parser.parse_args(argv)
    try:
        return args.func(args)
    except CofError as exc:
        print(f"LINUX_FLASH_COF_ERROR: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
