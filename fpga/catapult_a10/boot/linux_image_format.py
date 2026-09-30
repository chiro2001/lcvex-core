#!/usr/bin/env python3
"""Build and validate the versioned AArch64 Linux Flash payload."""

from __future__ import annotations

import argparse
import json
import struct
import sys
import zlib
from pathlib import Path
from typing import Any


U32_MAX = (1 << 32) - 1
U64_MAX = (1 << 64) - 1
CRC32_POLY = 0xEDB88320


class FormatError(ValueError):
    """Raised for a malformed layout, Linux input, or payload descriptor."""


def _uint(value: Any, name: str, bits: int = 64) -> int:
    if isinstance(value, bool):
        raise FormatError(f"{name} must be an unsigned {bits}-bit integer")
    if isinstance(value, int):
        result = value
    elif isinstance(value, str):
        try:
            result = int(value, 0)
        except ValueError as exc:
            raise FormatError(f"{name} is not an integer: {value!r}") from exc
    else:
        raise FormatError(f"{name} must be an unsigned {bits}-bit integer")
    if result < 0 or result > (1 << bits) - 1:
        raise FormatError(f"{name} does not fit in unsigned {bits}-bit field")
    return result


def _add_u64(left: int, right: int, name: str) -> int:
    result = left + right
    if result > U64_MAX:
        raise FormatError(f"{name} overflows a 64-bit address")
    return result


def _align_up(value: int, alignment: int, name: str) -> int:
    if alignment <= 0 or alignment & (alignment - 1):
        raise FormatError(f"{name} alignment must be a nonzero power of two")
    result = (value + alignment - 1) & ~(alignment - 1)
    if result > U64_MAX:
        raise FormatError(f"{name} alignment overflows a 64-bit address")
    return result


def _section(layout: dict[str, Any], name: str) -> dict[str, Any]:
    section = layout.get(name)
    if not isinstance(section, dict):
        raise FormatError(f"layout field {name!r} must be an object")
    return section


def load_layout(path: str | Path) -> dict[str, Any]:
    try:
        layout = json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise FormatError(f"cannot read layout {path}: {exc}") from exc
    if not isinstance(layout, dict):
        raise FormatError("layout root must be an object")
    validate_layout(layout)
    return layout


def validate_layout(layout: dict[str, Any]) -> dict[str, int | bytes]:
    if _uint(layout.get("schema_version"), "schema_version", 32) != 1:
        raise FormatError("unsupported layout schema_version")

    fmt = _section(layout, "format")
    flash = _section(layout, "flash")
    ddr = _section(layout, "ddr")
    bram = _section(layout, "bram")
    regs = _section(layout, "registers")
    image = _section(layout, "linux_image")

    try:
        magic = fmt["magic_ascii"].encode("ascii")
    except (KeyError, AttributeError, UnicodeEncodeError) as exc:
        raise FormatError("format.magic_ascii must be exactly 8 ASCII bytes") from exc
    if len(magic) != 8:
        raise FormatError("format.magic_ascii must be exactly 8 ASCII bytes")
    version = _uint(fmt.get("version"), "format.version", 32)
    header_size = _uint(fmt.get("header_size"), "format.header_size", 32)
    segment_size = _uint(fmt.get("segment_size"), "format.segment_size", 32)
    trailer_size = _uint(fmt.get("trailer_size"), "format.trailer_size", 32)
    segment_count = _uint(fmt.get("segment_count"), "format.segment_count", 32)
    kinds = _section(fmt, "segment_kinds")
    kernel_kind = _uint(kinds.get("kernel"), "format.segment_kinds.kernel", 32)
    dtb_kind = _uint(kinds.get("dtb"), "format.segment_kinds.dtb", 32)
    if (header_size, segment_size, trailer_size, segment_count) != (40, 32, 8, 2):
        raise FormatError("this loader requires a 40-byte header, two 32-byte segments, and an 8-byte trailer")
    if kernel_kind == dtb_kind or kernel_kind == 0 or dtb_kind == 0:
        raise FormatError("kernel and DTB segment kinds must be distinct nonzero values")

    flash_capacity = _uint(flash.get("physical_capacity"), "flash.physical_capacity")
    aperture_base = _uint(flash.get("aperture_base"), "flash.aperture_base")
    aperture_size = _uint(flash.get("aperture_size"), "flash.aperture_size")
    payload_offset = _uint(flash.get("payload_offset"), "flash.payload_offset")
    payload_alignment = _uint(flash.get("payload_alignment"), "flash.payload_alignment")
    segment_alignment = _uint(flash.get("segment_alignment"), "flash.segment_alignment")
    if aperture_size == 0:
        raise FormatError("Flash aperture size must be nonzero")
    aperture_end = _add_u64(aperture_base, aperture_size, "Flash aperture end")
    if flash_capacity == 0 or flash_capacity > aperture_size:
        raise FormatError("Flash physical capacity must fit in its CPU aperture")
    if payload_offset >= flash_capacity:
        raise FormatError("payload_offset must be inside physical Flash")
    if payload_alignment == 0 or payload_alignment & (payload_alignment - 1):
        raise FormatError("flash.payload_alignment must be a power of two")
    if payload_offset % payload_alignment:
        raise FormatError("payload_offset is not aligned to flash.payload_alignment")
    if segment_alignment < 4 or segment_alignment & (segment_alignment - 1):
        raise FormatError("flash.segment_alignment must be a power of two of at least four bytes")
    if aperture_end <= aperture_base:
        raise FormatError("Flash aperture end is outside the 64-bit address space")

    ddr_base = _uint(ddr.get("base"), "ddr.base")
    ddr_size = _uint(ddr.get("size"), "ddr.size")
    kernel_address = _uint(ddr.get("kernel_address"), "ddr.kernel_address")
    dtb_address = _uint(ddr.get("dtb_address"), "ddr.dtb_address")
    destination_alignment = _uint(ddr.get("destination_alignment"), "ddr.destination_alignment")
    ddr_end = _add_u64(ddr_base, ddr_size, "DDR end")
    if ddr_size == 0:
        raise FormatError("DDR size must be nonzero")
    if destination_alignment < 4 or destination_alignment & (destination_alignment - 1):
        raise FormatError("ddr.destination_alignment must be a power of two of at least four bytes")
    for name, address in (("kernel_address", kernel_address), ("dtb_address", dtb_address)):
        if address % destination_alignment:
            raise FormatError(f"ddr.{name} is not destination aligned")
        if address < ddr_base or address >= ddr_end:
            raise FormatError(f"ddr.{name} is outside the DDR range")

    bram_size = _uint(bram.get("size"), "bram.size")
    stack_start = _uint(bram.get("stack_start"), "bram.stack_start")
    stack_top = _uint(bram.get("stack_top"), "bram.stack_top")
    loader_max_bytes = _uint(bram.get("loader_max_bytes"), "bram.loader_max_bytes")
    if bram_size != 0x10000 or stack_top != bram_size or not 0 < stack_start < stack_top:
        raise FormatError("loader BRAM must be 64 KiB with a valid reserved stack range")
    if loader_max_bytes != stack_start or loader_max_bytes > bram_size:
        raise FormatError("loader_max_bytes must end at the reserved stack start")

    register_values: dict[str, int] = {}
    for name in (
        "uart_data",
        "uart_control",
        "platform_status",
        "cycle_counter",
        "cal_ready_mask",
        "cal_failed_mask",
        "calibration_timeout_cycles",
        "uart_tx_wait_limit",
    ):
        register_values[name] = _uint(regs.get(name), f"registers.{name}")
    if register_values["cal_ready_mask"] == 0 or register_values["cal_failed_mask"] == 0:
        raise FormatError("calibration status masks must be nonzero")
    if register_values["cal_ready_mask"] & register_values["cal_failed_mask"]:
        raise FormatError("calibration ready and failed masks overlap")
    if register_values["calibration_timeout_cycles"] == 0:
        raise FormatError("calibration timeout must be nonzero")

    image_values = {
        "magic_offset": _uint(image.get("magic_offset"), "linux_image.magic_offset", 32),
        "magic": _uint(image.get("magic"), "linux_image.magic", 32),
        "text_offset_field": _uint(image.get("text_offset_field"), "linux_image.text_offset_field", 32),
        "image_size_field": _uint(image.get("image_size_field"), "linux_image.image_size_field", 32),
    }

    return {
        "magic": magic,
        "magic_le": int.from_bytes(magic, "little"),
        "version": version,
        "header_size": header_size,
        "segment_size": segment_size,
        "trailer_size": trailer_size,
        "segment_count": segment_count,
        "kernel_kind": kernel_kind,
        "dtb_kind": dtb_kind,
        "flash_capacity": flash_capacity,
        "aperture_base": aperture_base,
        "aperture_size": aperture_size,
        "payload_offset": payload_offset,
        "payload_alignment": payload_alignment,
        "segment_alignment": segment_alignment,
        "ddr_base": ddr_base,
        "ddr_size": ddr_size,
        "ddr_end": ddr_end,
        "kernel_address": kernel_address,
        "dtb_address": dtb_address,
        "destination_alignment": destination_alignment,
        "bram_size": bram_size,
        "stack_start": stack_start,
        "stack_top": stack_top,
        "loader_max_bytes": loader_max_bytes,
        "image_magic_offset": image_values["magic_offset"],
        "image_magic": image_values["magic"],
        "image_text_offset_field": image_values["text_offset_field"],
        "image_size_field": image_values["image_size_field"],
        **register_values,
    }


def _read_linux_image(data: bytes, values: dict[str, int | bytes]) -> tuple[int, int, bytes]:
    magic_offset = int(values["image_magic_offset"])
    text_field = int(values["image_text_offset_field"])
    size_field = int(values["image_size_field"])
    magic = int(values["image_magic"])
    if len(data) < max(magic_offset + 4, text_field + 8, size_field + 8):
        raise FormatError("AArch64 Image is too short to contain its boot header")
    if struct.unpack_from("<I", data, magic_offset)[0] != magic:
        raise FormatError("input kernel does not have the AArch64 Linux Image magic")
    text_offset = struct.unpack_from("<Q", data, text_field)[0]
    image_size = struct.unpack_from("<Q", data, size_field)[0]
    if image_size == 0:
        raise FormatError("AArch64 Image header image_size must be nonzero")
    if image_size < len(data):
        raise FormatError("AArch64 Image header image_size is smaller than the input file")
    max_ddr_span = int(values["ddr_end"]) - int(values["kernel_address"])
    max_flash_span = int(values["flash_capacity"]) - int(values["payload_offset"])
    if image_size > min(max_ddr_span, max_flash_span):
        raise FormatError("AArch64 Image header image_size exceeds configured DDR/Flash capacity")
    if text_offset >= image_size or text_offset & 3:
        raise FormatError("AArch64 Image text_offset must be word aligned and inside image_size")
    return text_offset, image_size, data.ljust(image_size, b"\0")


def _read_dtb(data: bytes) -> bytes:
    if len(data) < 8 or struct.unpack_from(">I", data, 0)[0] != 0xD00DFEED:
        raise FormatError("input DTB does not have the flattened device tree magic")
    total_size = struct.unpack_from(">I", data, 4)[0]
    if total_size < 40 or total_size > len(data):
        raise FormatError("DTB totalsize is outside the input file")
    return data[:total_size]


def _check_ddr_span(
    address: int,
    length: int,
    values: dict[str, int | bytes],
    name: str,
) -> tuple[int, int]:
    if length <= 0:
        raise FormatError(f"{name} segment length must be nonzero")
    alignment = int(values["destination_alignment"])
    if address % alignment:
        raise FormatError(f"{name} destination is not aligned to 0x{alignment:x}")
    end = _add_u64(address, length, f"{name} DDR destination end")
    if address < int(values["ddr_base"]) or end > int(values["ddr_end"]):
        raise FormatError(f"{name} DDR range is outside configured memory")
    return address, end


def build_payload(layout: dict[str, Any], image_bytes: bytes, dtb_bytes: bytes) -> bytes:
    values = validate_layout(layout)
    text_offset, kernel_size, kernel_data = _read_linux_image(image_bytes, values)
    dtb_data = _read_dtb(dtb_bytes)
    kernel_start = int(values["kernel_address"])
    dtb_start = int(values["dtb_address"])
    entry = _add_u64(kernel_start, text_offset, "AArch64 kernel entry")
    kernel_span = _check_ddr_span(kernel_start, kernel_size, values, "kernel")
    dtb_span = _check_ddr_span(dtb_start, len(dtb_data), values, "DTB")
    if kernel_span[0] < dtb_span[1] and dtb_span[0] < kernel_span[1]:
        raise FormatError("kernel and DTB DDR ranges overlap")
    if entry & 3 or not kernel_span[0] <= entry < kernel_span[1]:
        raise FormatError("AArch64 kernel entry is not word aligned inside the kernel range")

    header_size = int(values["header_size"])
    segment_size = int(values["segment_size"])
    trailer_size = int(values["trailer_size"])
    count = int(values["segment_count"])
    metadata_size = header_size + segment_size * count
    data_alignment = int(values["segment_alignment"])
    cursor = _align_up(metadata_size + trailer_size, data_alignment, "first segment offset")

    segment_specs = (
        ("kernel", kernel_start, kernel_data, int(values["kernel_kind"])),
        ("dtb", dtb_start, dtb_data, int(values["dtb_kind"])),
    )
    segments: list[tuple[int, int, int, int, int, bytes]] = []
    for name, destination, payload, kind in segment_specs:
        cursor = _align_up(cursor, data_alignment, f"{name} Flash offset")
        source_offset = _add_u64(int(values["payload_offset"]), cursor, f"{name} absolute Flash offset")
        source_end = _add_u64(source_offset, len(payload), f"{name} Flash range end")
        if source_end > int(values["flash_capacity"]) or source_end > int(values["aperture_size"]):
            raise FormatError(f"{name} Flash data exceeds configured physical Flash/aperture")
        segments.append((source_offset, destination, len(payload), zlib.crc32(payload) & U32_MAX, kind, payload))
        cursor = _add_u64(cursor, len(payload), f"{name} payload end")

    if cursor > int(values["flash_capacity"]) - int(values["payload_offset"]):
        raise FormatError("payload exceeds remaining Flash capacity after payload_offset")
    if cursor > int(values["aperture_size"]) - int(values["payload_offset"]):
        raise FormatError("payload exceeds remaining CPU Flash aperture after payload_offset")

    magic = bytes(values["magic"])
    header = struct.pack(
        "<8sIIIIQQ",
        magic,
        int(values["version"]),
        header_size,
        count,
        segment_size,
        entry,
        dtb_start,
    )
    segment_table = b"".join(
        struct.pack("<QQQII", source, destination, length, crc, kind)
        for source, destination, length, crc, kind, _payload in segments
    )
    descriptor_crc = zlib.crc32(header + segment_table) & U32_MAX
    trailer = struct.pack("<II", descriptor_crc, 0)

    blob = bytearray(cursor)
    blob[:header_size] = header
    blob[header_size : header_size + len(segment_table)] = segment_table
    blob[metadata_size : metadata_size + trailer_size] = trailer
    payload_base = int(values["payload_offset"])
    for source, _destination, _length, _crc, _kind, payload in segments:
        relative = source - payload_base
        blob[relative : relative + len(payload)] = payload

    parse_payload(bytes(blob), layout)
    return bytes(blob)


def parse_payload(blob: bytes, layout: dict[str, Any]) -> dict[str, Any]:
    """Validate a payload as the BRAM loader does and return decoded fields."""
    values = validate_layout(layout)
    header_size = int(values["header_size"])
    segment_size = int(values["segment_size"])
    trailer_size = int(values["trailer_size"])
    if len(blob) < header_size + segment_size + trailer_size:
        raise FormatError("payload is too short for a descriptor")

    fields = struct.unpack_from("<8sIIIIQQ", blob, 0)
    magic, version, encoded_header_size, count, encoded_segment_size, entry, dtb_address = fields
    if magic != values["magic"]:
        raise FormatError("descriptor magic mismatch")
    if version != values["version"]:
        raise FormatError("unsupported descriptor version")
    if encoded_header_size != header_size or encoded_segment_size != segment_size:
        raise FormatError("descriptor field widths do not match this loader")
    if count != values["segment_count"]:
        raise FormatError("descriptor segment count is not the required kernel + DTB pair")

    metadata_size = header_size + count * segment_size
    trailer_end = metadata_size + trailer_size
    if trailer_end > len(blob):
        raise FormatError("descriptor trailer is truncated")
    descriptor_crc, reserved = struct.unpack_from("<II", blob, metadata_size)
    if reserved != 0:
        raise FormatError("descriptor reserved field must be zero")
    if zlib.crc32(blob[:metadata_size]) & U32_MAX != descriptor_crc:
        raise FormatError("descriptor CRC32 mismatch")

    minimum_relative = _align_up(metadata_size + trailer_size, int(values["segment_alignment"]), "descriptor end")
    minimum_source = _add_u64(int(values["payload_offset"]), minimum_relative, "first permitted Flash segment")
    segments: list[dict[str, Any]] = []
    kinds: set[int] = set()
    payload_offset = int(values["payload_offset"])
    for index in range(count):
        off = header_size + index * segment_size
        source, destination, length, crc, kind = struct.unpack_from("<QQQII", blob, off)
        name = "kernel" if kind == values["kernel_kind"] else "DTB" if kind == values["dtb_kind"] else f"segment {index}"
        if kind not in (values["kernel_kind"], values["dtb_kind"]):
            raise FormatError(f"{name} has an unknown segment kind")
        if kind in kinds:
            raise FormatError(f"duplicate {name} segment kind")
        kinds.add(kind)
        if length == 0:
            raise FormatError(f"{name} segment length is zero")
        if source < minimum_source:
            raise FormatError(f"{name} source overlaps descriptor metadata or its alignment gap")
        alignment = int(values["segment_alignment"])
        if source % alignment:
            raise FormatError(f"{name} Flash source is not aligned to 0x{alignment:x}")
        source_end = _add_u64(source, length, f"{name} Flash source end")
        if source_end > int(values["flash_capacity"]) or source_end > int(values["aperture_size"]):
            raise FormatError(f"{name} Flash source is outside physical Flash/aperture")
        relative = source - payload_offset
        relative_end = relative + length
        if relative_end > len(blob):
            raise FormatError(f"{name} Flash source extends past the payload BIN")
        start, end = _check_ddr_span(destination, length, values, name)
        segment_data = memoryview(blob)[relative:relative_end]
        if zlib.crc32(segment_data) & U32_MAX != crc:
            raise FormatError(f"{name} segment CRC32 mismatch")
        segments.append(
            {
                "flash_offset": source,
                "load_address": destination,
                "length": length,
                "crc32": crc,
                "kind": kind,
                "relative_offset": relative,
                "data": segment_data,
                "ddr_start": start,
                "ddr_end": end,
                "flash_end": source_end,
            }
        )

    if kinds != {int(values["kernel_kind"]), int(values["dtb_kind"])}:
        raise FormatError("descriptor must contain exactly one kernel and one DTB segment")
    if int(segments[0]["kind"]) != int(values["kernel_kind"]) or int(segments[1]["kind"]) != int(values["dtb_kind"]):
        raise FormatError("descriptor segment order must be kernel followed by DTB")
    for left, right, label in ((segments[0], segments[1], "Flash"), (segments[0], segments[1], "DDR")):
        left_start = int(left["flash_offset"] if label == "Flash" else left["ddr_start"])
        left_end = int(left["flash_end"] if label == "Flash" else left["ddr_end"])
        right_start = int(right["flash_offset"] if label == "Flash" else right["ddr_start"])
        right_end = int(right["flash_end"] if label == "Flash" else right["ddr_end"])
        if left_start < right_end and right_start < left_end:
            raise FormatError(f"kernel and DTB {label} ranges overlap")

    by_kind = {int(segment["kind"]): segment for segment in segments}
    kernel = by_kind[int(values["kernel_kind"])]
    dtb = by_kind[int(values["dtb_kind"])]
    kernel_start = int(kernel["ddr_start"])
    kernel_end = int(kernel["ddr_end"])
    if entry & 3 or not kernel_start <= entry < kernel_end:
        raise FormatError("descriptor entry is not word aligned inside the kernel DDR segment")
    if dtb_address != int(dtb["load_address"]):
        raise FormatError("descriptor DTB address does not name the DTB segment")

    final_end = max(int(segment["relative_offset"]) + int(segment["length"]) for segment in segments)
    if final_end != len(blob):
        raise FormatError("payload BIN has trailing bytes outside described Flash segments")
    if len(blob) > int(values["flash_capacity"]) - payload_offset:
        raise FormatError("payload BIN exceeds the remaining physical Flash capacity")
    if len(blob) > int(values["aperture_size"]) - payload_offset:
        raise FormatError("payload BIN exceeds the remaining CPU Flash aperture")

    return {
        "version": version,
        "entry_address": entry,
        "dtb_address": dtb_address,
        "descriptor_crc32": descriptor_crc,
        "segments": segments,
    }


def iter_intel_hex(blob: bytes, record_bytes: int = 16):
    if record_bytes <= 0 or record_bytes > 255:
        raise FormatError("Intel HEX record size must be in 1..255")

    def record(address: int, kind: int, data: bytes) -> str:
        raw = bytes((len(data),)) + address.to_bytes(2, "big") + bytes((kind,)) + data
        checksum = (-sum(raw)) & 0xFF
        return ":" + (raw + bytes((checksum,))).hex().upper()

    current_upper: int | None = None
    offset = 0
    while offset < len(blob):
        upper = offset >> 16
        if upper != current_upper:
            yield record(0, 4, upper.to_bytes(2, "big"))
            current_upper = upper
        low = offset & 0xFFFF
        count = min(record_bytes, len(blob) - offset, 0x10000 - low)
        yield record(low, 0, blob[offset : offset + count])
        offset += count
    yield ":00000001FF"


def intel_hex(blob: bytes, record_bytes: int = 16) -> str:
    return "\n".join(iter_intel_hex(blob, record_bytes)) + "\n"


def loader_assembly_constants(layout: dict[str, Any]) -> str:
    values = validate_layout(layout)
    constants = {
        "BRAM_SIZE": values["bram_size"],
        "STACK_START": values["stack_start"],
        "STACK_TOP": values["stack_top"],
        "LOADER_MAX_BYTES": values["loader_max_bytes"],
        "UART_DATA": values["uart_data"],
        "UART_CONTROL": values["uart_control"],
        "PLATFORM_STATUS": values["platform_status"],
        "CYCLE_COUNTER": values["cycle_counter"],
        "CAL_READY_MASK": values["cal_ready_mask"],
        "CAL_FAILED_MASK": values["cal_failed_mask"],
        "CAL_TIMEOUT_CYCLES": values["calibration_timeout_cycles"],
        "UART_TX_WAIT_LIMIT": values["uart_tx_wait_limit"],
        "FLASH_APERTURE_BASE": values["aperture_base"],
        "FLASH_APERTURE_SIZE": values["aperture_size"],
        "FLASH_CAPACITY": values["flash_capacity"],
        "FLASH_PAYLOAD_OFFSET": values["payload_offset"],
        "DDR_BASE": values["ddr_base"],
        "DDR_SIZE": values["ddr_size"],
        "FORMAT_MAGIC_LE": values["magic_le"],
        "FORMAT_VERSION": values["version"],
        "HEADER_SIZE": values["header_size"],
        "SEGMENT_SIZE": values["segment_size"],
        "TRAILER_SIZE": values["trailer_size"],
        "SEGMENT_COUNT": values["segment_count"],
        "SEGMENT_ALIGNMENT": values["segment_alignment"],
        "DDR_ALIGNMENT": values["destination_alignment"],
        "SEG_KERNEL": values["kernel_kind"],
        "SEG_DTB": values["dtb_kind"],
        "CRC32_POLY": CRC32_POLY,
    }
    lines = ["// Generated from linux_flash_layout.json; do not edit."]
    lines.extend(f".equ {name}, 0x{int(value):X}" for name, value in constants.items())
    return "\n".join(lines) + "\n"


def crc32_lookup_table() -> tuple[int, ...]:
    """Return the reflected CRC-32/ISO-HDLC byte lookup table."""
    table: list[int] = []
    for value in range(256):
        crc = value
        for _ in range(8):
            crc = (crc >> 1) ^ (CRC32_POLY if crc & 1 else 0)
        table.append(crc & U32_MAX)
    return tuple(table)


def crc32_table_assembly() -> str:
    """Emit the loader's generated CRC table as a GNU AArch64 assembly include."""
    table = crc32_lookup_table()
    lines = [
        "// Generated CRC-32/ISO-HDLC table; do not edit.",
        ".section .rodata",
        ".balign 4",
        "crc32_table:",
    ]
    for offset in range(0, len(table), 4):
        words = ", ".join(f"0x{value:08X}" for value in table[offset : offset + 4])
        lines.append(f"    .word {words}")
    return "\n".join(lines) + "\n"


def _build_command(args: argparse.Namespace) -> None:
    layout = load_layout(args.layout)
    try:
        image = Path(args.image).read_bytes()
        dtb = Path(args.dtb).read_bytes()
    except OSError as exc:
        raise FormatError(f"cannot read Linux input: {exc}") from exc
    blob = build_payload(layout, image, dtb)
    bin_path = Path(args.bin)
    hex_path = Path(args.hex)
    bin_path.parent.mkdir(parents=True, exist_ok=True)
    hex_path.parent.mkdir(parents=True, exist_ok=True)
    bin_path.write_bytes(blob)
    with hex_path.open("w", encoding="ascii", newline="\n") as hex_file:
        for line in iter_intel_hex(blob):
            hex_file.write(line)
            hex_file.write("\n")
    parsed = parse_payload(blob, layout)
    print(
        "LINUX_FLASH_PAYLOAD_PASS "
        f"bytes={len(blob)} entry=0x{parsed['entry_address']:016X} "
        f"dtb=0x{parsed['dtb_address']:016X} "
        f"payload_offset=0x{validate_layout(layout)['payload_offset']:08X}"
    )


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    build = subparsers.add_parser("build", help="create payload BIN and blob-relative Intel HEX")
    build.add_argument("--layout", required=True)
    build.add_argument("--image", required=True, help="AArch64 Linux Image input")
    build.add_argument("--dtb", required=True, help="board DTB input")
    build.add_argument("--bin", required=True, help="payload BIN output")
    build.add_argument("--hex", required=True, help="blob-relative Intel HEX output")
    build.set_defaults(func=_build_command)

    def emit_command(args: argparse.Namespace) -> None:
        Path(args.output).write_text(
            loader_assembly_constants(load_layout(args.layout)), encoding="ascii"
        )

    emit = subparsers.add_parser("emit-asm", help="emit loader constants from the shared JSON layout")
    emit.add_argument("--layout", required=True)
    emit.add_argument("--output", required=True)
    emit.set_defaults(func=emit_command)

    def emit_crc32_table_command(args: argparse.Namespace) -> None:
        Path(args.output).write_text(crc32_table_assembly(), encoding="ascii")

    emit_crc32_table = subparsers.add_parser(
        "emit-crc32-table", help="emit the loader's reflected CRC-32 lookup table"
    )
    emit_crc32_table.add_argument("--output", required=True)
    emit_crc32_table.set_defaults(func=emit_crc32_table_command)

    args = parser.parse_args(argv)
    try:
        result = args.func(args)
    except (FormatError, OSError, struct.error) as exc:
        print(f"LINUX_FLASH_PAYLOAD_ERROR {exc}", file=sys.stderr)
        return 2
    return result if isinstance(result, int) else 0


if __name__ == "__main__":
    raise SystemExit(main())
