#!/usr/bin/env python3
"""Independent B25 BRAM image provenance and cross-artifact checker.

The expected image is derived from ELF64 PT_LOAD bytes, never from the DUT,
the byte HEX or the MIF.  ``--emit`` writes a 64 KiB byte-HEX expected image
and a hash-bound manifest.  ``--check`` is read-only and verifies that the
manifest, expected image, ELF structure, BIN, HEX and MIF still agree.
"""

from __future__ import annotations

import argparse
import copy
import hashlib
import json
import re
import struct
import sys
from pathlib import Path
from typing import Any


BRAM_BYTES = 0x10000
MIF_WIDTH = 64
MIF_DEPTH = BRAM_BYTES // (MIF_WIDTH // 8)
ELF_HEADER_SIZE = 64
ELF_PHDR_SIZE = 56
ELF_SHDR_SIZE = 64
ELF_SYM_SIZE = 24
PT_LOAD = 1
SHT_SYMTAB = 2
SHT_DYNSYM = 11
AARCH64_MACHINE = 183

MONITOR_PAGE_CONTRACT = {
    "version": "B25-RX-FIRMWARE-COMMAND-TRACE-V1",
    "pages": {
        "RXDBG": {"line_bytes": 25, "rotation": 0},
        "RXPATH": {"line_bytes": 44, "rotation": 1},
        "RXCPU": {"line_bytes": 43, "rotation": 2},
    },
    "hardware_offsets": {
        "bridge_response": "0x09003018",
        "poc_response": "0x09003020",
        "dmem_response": "0x09003028",
        "path_events": "0x09003030",
        "tx_event": "0x09003038",
    },
    "software_packing": {
        "getc_event": "bits31:16=valid-count,bits15:0=last-raw-low16",
        "dispatch_event": "bits31:16=dispatch-count,bits15:8=class,bits7:0=byte",
        "putc_event": "bits31:16=successful-data-writes,bits15:0=drop-count",
    },
}


class ContractError(RuntimeError):
    """A deterministic image-contract failure."""


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def require_file(path: Path, label: str) -> bytes:
    if not path.is_file():
        raise ContractError(f"{label} missing: {path}")
    try:
        return path.read_bytes()
    except OSError as exc:
        raise ContractError(f"cannot read {label} {path}: {exc}") from exc


def u16(body: bytes, offset: int) -> int:
    return struct.unpack_from("<H", body, offset)[0]


def u64(body: bytes, offset: int) -> int:
    return struct.unpack_from("<Q", body, offset)[0]


def section_headers(body: bytes) -> list[dict[str, int]]:
    """Decode the ELF64 section table needed for symbol lookup."""

    if len(body) < ELF_HEADER_SIZE:
        raise ContractError("ELF header is truncated")
    shoff = u64(body, 40)
    shentsize = u16(body, 58)
    shnum = u16(body, 60)
    if shnum == 0:
        raise ContractError("ELF has no section headers; __stack_top cannot be proven")
    if shentsize < ELF_SHDR_SIZE:
        raise ContractError(f"ELF section entry size is {shentsize}, expected at least {ELF_SHDR_SIZE}")
    end = shoff + shentsize * shnum
    if shoff > len(body) or end > len(body):
        raise ContractError("ELF section table is outside the file")
    result: list[dict[str, int]] = []
    for index in range(shnum):
        offset = shoff + index * shentsize
        fields = struct.unpack_from("<IIQQQQIIQQ", body, offset)
        result.append(
            {
                "name": fields[0],
                "type": fields[1],
                "flags": fields[2],
                "addr": fields[3],
                "offset": fields[4],
                "size": fields[5],
                "link": fields[6],
                "info": fields[7],
                "addralign": fields[8],
                "entsize": fields[9],
            }
        )
    return result


def symbol_table(body: bytes, sections: list[dict[str, int]]) -> dict[str, int]:
    symbols: dict[str, int] = {}
    for section in sections:
        if section["type"] not in (SHT_SYMTAB, SHT_DYNSYM):
            continue
        offset = section["offset"]
        size = section["size"]
        entsize = section["entsize"] or ELF_SYM_SIZE
        if entsize < ELF_SYM_SIZE or offset + size > len(body):
            raise ContractError("ELF symbol table is malformed")
        link = section["link"]
        if link >= len(sections):
            raise ContractError("ELF symbol string-table link is invalid")
        strtab = sections[link]
        str_start = strtab["offset"]
        str_end = str_start + strtab["size"]
        if str_start > len(body) or str_end > len(body):
            raise ContractError("ELF symbol string table is outside the file")
        names = body[str_start:str_end]
        for item in range(0, size, entsize):
            if item + ELF_SYM_SIZE > size:
                raise ContractError("ELF symbol table has a partial entry")
            entry = offset + item
            name_offset, _info, _other, _shndx, value, _sym_size = struct.unpack_from(
                "<IBBHQQ", body, entry
            )
            if name_offset >= len(names):
                continue
            end = names.find(b"\0", name_offset)
            if end < 0:
                continue
            name = names[name_offset:end].decode("ascii", errors="replace")
            if name not in ("_start", "__stack_top"):
                continue
            previous = symbols.get(name)
            if previous is not None and previous != value:
                raise ContractError(f"ELF symbol {name} has conflicting values")
            symbols[name] = value
    return symbols


def sign_extend(value: int, bits: int) -> int:
    sign = 1 << (bits - 1)
    return value - (1 << bits) if value & sign else value


def decode_reset(expected: bytes, stack_top: int, load_extent: int) -> dict[str, Any]:
    if len(expected) < 8:
        raise ContractError("ELF load image is shorter than the two reset instructions")
    first = int.from_bytes(expected[0:4], "little")
    second = int.from_bytes(expected[4:8], "little")

    # LDR X<t>, literal: fixed 64-bit literal-load opcode, Rt=X0.
    if (first & 0xFF000000) != 0x58000000 or (first & 0x1F) != 0:
        raise ContractError(f"reset word 0 is not LDR X0 literal: 0x{first:08x}")
    imm19 = (first >> 5) & 0x7FFFF
    offset = sign_extend(imm19, 19) << 2
    target = offset  # PC is the entry address 0.
    if target < 0 or target + 8 > load_extent or target % 4:
        raise ContractError(
            f"LDR X0 literal target 0x{target:x} is outside ELF load bytes"
        )
    literal = int.from_bytes(expected[target : target + 8], "little")
    if literal != stack_top:
        raise ContractError(
            f"LDR X0 literal at 0x{target:x} is 0x{literal:x}, expected __stack_top 0x{stack_top:x}"
        )

    # ADD (immediate), sf=1, S=0, shift=0, imm12=0, Rn=X0, Rd=SP.
    if (second & 0x7F000000) != 0x11000000:
        raise ContractError(f"reset word 1 is not ADD-immediate: 0x{second:08x}")
    if (
        ((second >> 31) & 1) != 1
        or ((second >> 30) & 1) != 0
        or ((second >> 29) & 1) != 0
        or ((second >> 22) & 1) != 0
        or ((second >> 10) & 0xFFF) != 0
        or ((second >> 5) & 0x1F) != 0
        or (second & 0x1F) != 31
    ):
        raise ContractError(
            f"reset word 1 is not MOV SP,X0 (ADD XSP,X0,#0): 0x{second:08x}"
        )

    return {
        "first_instruction": f"0x{first:08x}",
        "second_instruction": f"0x{second:08x}",
        "imm19": imm19,
        "imm19_hex": f"0x{imm19:05x}",
        "signed_byte_offset": offset,
        "literal_target": f"0x{target:x}",
        "literal_value": f"0x{literal:016x}",
        "stack_top": f"0x{stack_top:x}",
    }


def verify_monitor_output_contract(expected: bytes) -> dict[str, Any]:
    """Bind the rotating firmware page ABI to the ELF-derived image."""

    pages = MONITOR_PAGE_CONTRACT["pages"]
    if list(pages) != ["RXDBG", "RXPATH", "RXCPU"]:
        raise ContractError("monitor page rotation contract is not RXDBG/RXPATH/RXCPU")
    if any(int(page["line_bytes"]) >= 64 for page in pages.values()):
        raise ContractError("monitor diagnostic page reaches the 64-byte TX FIFO limit")

    required_strings = {
        "RXDBG": b"RXDBG ",
        "RXPATH": b"RXPATH ",
        "RXCPU": b"RXCPU ",
    }
    string_offsets: dict[str, str] = {}
    for label, token in required_strings.items():
        offset = expected.find(token)
        if offset < 0:
            raise ContractError(f"monitor page prefix missing from ELF image: {label}")
        string_offsets[label] = f"0x{offset:x}"

    literal_offsets: dict[str, str] = {}
    for label, address in MONITOR_PAGE_CONTRACT["hardware_offsets"].items():
        value = int(address, 16).to_bytes(8, "little")
        offset = expected.find(value)
        if offset < 0:
            raise ContractError(f"monitor hardware offset literal missing: {label}={address}")
        literal_offsets[label] = f"0x{offset:x}"

    return {
        **MONITOR_PAGE_CONTRACT,
        "page_prefix_offsets": string_offsets,
        "hardware_literal_offsets": literal_offsets,
        "startup_page": "RXDBG",
        "startup_advances_rotation": False,
        "first_autonomous_page": "RXDBG",
        "autonomous_rotation": ["RXDBG", "RXPATH", "RXCPU"],
        "command_debug_page": "RXDBG",
        "all_lines_below_vendor_fifo": True,
    }


def parse_elf(path: Path) -> tuple[bytes, dict[str, Any], dict[str, int]]:
    body = require_file(path, "ELF")
    if len(body) < ELF_HEADER_SIZE or body[0:4] != b"\x7fELF":
        raise ContractError(f"{path} is not an ELF file")
    ident = body[:16]
    if ident[4] != 2 or ident[5] != 1:
        raise ContractError("ELF must be 64-bit little-endian")
    if u16(body, 16) != 2:
        raise ContractError("ELF must be an executable image")
    if u16(body, 18) != AARCH64_MACHINE:
        raise ContractError(f"ELF machine is {u16(body, 18)}, expected AArch64 ({AARCH64_MACHINE})")

    entry = u64(body, 24)
    phoff = u64(body, 32)
    phentsize = u16(body, 54)
    phnum = u16(body, 56)
    if phentsize < ELF_PHDR_SIZE or phnum == 0:
        raise ContractError("ELF has no usable program-header table")
    ph_end = phoff + phentsize * phnum
    if phoff > len(body) or ph_end > len(body):
        raise ContractError("ELF program-header table is outside the file")

    expected = bytearray(BRAM_BYTES)
    written: dict[int, int] = {}
    segments: list[dict[str, Any]] = []
    load_extent = 0
    load_start: int | None = None
    for index in range(phnum):
        offset = phoff + index * phentsize
        p_type, p_flags, p_offset, p_vaddr, p_paddr, p_filesz, p_memsz, p_align = struct.unpack_from(
            "<IIQQQQQQ", body, offset
        )
        if p_type != PT_LOAD:
            continue
        if p_filesz > p_memsz:
            raise ContractError(f"PT_LOAD {index} has filesz > memsz")
        if p_offset + p_filesz > len(body):
            raise ContractError(f"PT_LOAD {index} bytes are outside the ELF file")
        if p_vaddr + p_memsz > BRAM_BYTES:
            raise ContractError(f"PT_LOAD {index} exceeds the 64 KiB BRAM window")
        if p_vaddr + p_filesz > BRAM_BYTES:
            raise ContractError(f"PT_LOAD {index} file bytes exceed the 64 KiB BRAM window")
        if load_start is None or p_vaddr < load_start:
            load_start = p_vaddr
        load_extent = max(load_extent, p_vaddr + p_filesz)
        segment_bytes = body[p_offset : p_offset + p_filesz]
        for byte_index, value in enumerate(segment_bytes):
            address = p_vaddr + byte_index
            previous = written.get(address)
            if previous is not None and previous != value:
                raise ContractError(f"overlapping PT_LOAD bytes disagree at 0x{address:x}")
            written[address] = value
            expected[address] = value
        segments.append(
            {
                "index": index,
                "offset": f"0x{p_offset:x}",
                "vaddr": f"0x{p_vaddr:x}",
                "filesz": p_filesz,
                "memsz": p_memsz,
                "flags": f"0x{p_flags:x}",
                "align": f"0x{p_align:x}",
            }
        )

    if not segments or load_start != 0 or entry != 0:
        raise ContractError(
            f"ELF must have a PT_LOAD starting at 0 and entry 0 (segments={len(segments)}, start={load_start}, entry=0x{entry:x})"
        )

    sections = section_headers(body)
    symbols = symbol_table(body, sections)
    if symbols.get("_start") != 0:
        raise ContractError(f"ELF _start is {symbols.get('_start')!r}, expected 0")
    if symbols.get("__stack_top") != BRAM_BYTES:
        raise ContractError(
            f"ELF __stack_top is {symbols.get('__stack_top')!r}, expected 0x{BRAM_BYTES:x}"
        )
    reset = decode_reset(bytes(expected), BRAM_BYTES, load_extent)
    monitor_contract = verify_monitor_output_contract(bytes(expected))
    metadata = {
        "entry": f"0x{entry:x}",
        "load_extent": load_extent,
        "load_start": load_start,
        "segments": segments,
        "symbols": {
            "_start": f"0x{symbols['_start']:x}",
            "__stack_top": f"0x{symbols['__stack_top']:x}",
        },
        "reset": reset,
        "monitor_contract": monitor_contract,
    }
    return bytes(expected), metadata, symbols


def parse_byte_hex(path: Path, label: str) -> bytes:
    body = require_file(path, label)
    try:
        text = body.decode("ascii")
    except UnicodeDecodeError as exc:
        raise ContractError(f"{label} is not ASCII byte HEX: {path}") from exc
    lines = text.splitlines()
    if not lines:
        raise ContractError(f"{label} is empty: {path}")
    values = bytearray()
    for line_number, raw in enumerate(lines, 1):
        token = raw.strip()
        if not token or re.fullmatch(r"[0-9A-Fa-f]{2}", token) is None:
            raise ContractError(f"invalid {label} byte record at {path}:{line_number}")
        values.append(int(token, 16))
    return bytes(values)


def parse_mif(path: Path) -> tuple[bytes, dict[str, Any]]:
    body = require_file(path, "MIF")
    try:
        lines = body.decode("ascii").splitlines()
    except UnicodeDecodeError as exc:
        raise ContractError(f"MIF is not ASCII: {path}") from exc
    width: int | None = None
    depth: int | None = None
    address_radix: str | None = None
    data_radix: str | None = None
    records: dict[int, int] = {}
    in_content = False
    ended = False
    record_pattern = re.compile(r"^([0-9A-Fa-f]+)\s*:\s*([0-9A-Fa-f]+)\s*;\s*$")
    header_pattern = re.compile(r"^([A-Za-z_]+)\s*=\s*([^;]+)\s*;\s*$")
    for line_number, raw in enumerate(lines, 1):
        line = raw.strip()
        if not line or line.startswith("--"):
            continue
        upper = line.upper()
        if ended:
            raise ContractError(f"unexpected MIF data after END at {path}:{line_number}")
        if not in_content:
            if upper == "CONTENT BEGIN":
                in_content = True
                continue
            match = header_pattern.fullmatch(line)
            if match is None:
                raise ContractError(f"invalid MIF header at {path}:{line_number}")
            key, value = match.groups()
            key = key.upper()
            value = value.strip()
            if key == "WIDTH":
                width = int(value, 10)
            elif key == "DEPTH":
                depth = int(value, 10)
            elif key == "ADDRESS_RADIX":
                address_radix = value.upper()
            elif key == "DATA_RADIX":
                data_radix = value.upper()
            continue
        if upper == "END;":
            ended = True
            in_content = False
            continue
        match = record_pattern.fullmatch(line)
        if match is None:
            raise ContractError(f"invalid MIF record at {path}:{line_number}")
        address = int(match.group(1), 16)
        value_token = match.group(2)
        if len(value_token) != MIF_WIDTH // 4:
            raise ContractError(f"MIF record at {path}:{line_number} is not 64-bit wide")
        value = int(value_token, 16)
        if address in records:
            raise ContractError(f"duplicate MIF address 0x{address:x}")
        if address >= MIF_DEPTH:
            raise ContractError(f"MIF address 0x{address:x} exceeds depth {MIF_DEPTH}")
        records[address] = value
    if not ended or in_content:
        raise ContractError(f"MIF is missing CONTENT END: {path}")
    if width != MIF_WIDTH or depth != MIF_DEPTH:
        raise ContractError(f"MIF contract is WIDTH={width} DEPTH={depth}, expected WIDTH=64 DEPTH=8192")
    if address_radix != "HEX" or data_radix != "HEX":
        raise ContractError("MIF must use hexadecimal address and data radices")
    if set(records) != set(range(MIF_DEPTH)):
        missing = sorted(set(range(MIF_DEPTH)) - set(records))[:4]
        extra = sorted(set(records) - set(range(MIF_DEPTH)))[:4]
        raise ContractError(f"MIF must contain exactly 8192 records (missing={missing}, extra={extra})")
    payload = b"".join(records[index].to_bytes(8, "little") for index in range(MIF_DEPTH))
    return payload, {
        "width": width,
        "depth": depth,
        "records": len(records),
        "payload_sha256": sha256_bytes(payload),
        "little_endian_lane_zero": True,
    }


def path_string(path: Path) -> str:
    return str(path.resolve())


def artifact_record(path: Path, data: bytes, kind: str) -> dict[str, Any]:
    return {
        "path": path_string(path),
        "kind": kind,
        "bytes": len(data),
        "sha256": sha256_bytes(data),
    }


def canonical_manifest_hash(manifest: dict[str, Any]) -> str:
    body = copy.deepcopy(manifest)
    body["manifest_sha256"] = ""
    encoded = (json.dumps(body, ensure_ascii=False, sort_keys=True, indent=2) + "\n").encode("utf-8")
    return sha256_bytes(encoded)


def load_manifest(path: Path) -> dict[str, Any]:
    raw = require_file(path, "manifest")
    try:
        manifest = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise ContractError(f"invalid manifest JSON: {path}") from exc
    if not isinstance(manifest, dict):
        raise ContractError("manifest root must be an object")
    if manifest.get("schema_version") != 1:
        raise ContractError("manifest schema_version must be 1")
    expected_hash = manifest.get("manifest_sha256")
    if not isinstance(expected_hash, str) or expected_hash != canonical_manifest_hash(manifest):
        raise ContractError("manifest SHA-256 binding mismatch")
    return manifest


def source_records(paths: list[Path]) -> list[dict[str, Any]]:
    records = []
    seen: set[str] = set()
    for path in paths:
        absolute = path.resolve()
        key = str(absolute)
        if key in seen:
            raise ContractError(f"duplicate source path {absolute}")
        seen.add(key)
        data = require_file(absolute, "source")
        records.append({"path": key, "bytes": len(data), "sha256": sha256_bytes(data)})
    return records


def verify_source_records(records: object) -> None:
    if not isinstance(records, list) or not records:
        raise ContractError("manifest source records are missing")
    for record in records:
        if not isinstance(record, dict):
            raise ContractError("malformed manifest source record")
        path = Path(str(record.get("path", "")))
        data = require_file(path, "source")
        if record.get("bytes") != len(data) or record.get("sha256") != sha256_bytes(data):
            raise ContractError(f"source hash binding mismatch: {path}")


def common_inputs(args: argparse.Namespace) -> tuple[bytes, dict[str, Any], dict[str, int], bytes, bytes, bytes, dict[str, Any]]:
    elf_path = Path(args.elf)
    bin_path = Path(args.bin)
    hex_path = Path(args.hex)
    mif_path = Path(args.mif)
    expected, elf_meta, symbols = parse_elf(elf_path)
    bin_data = require_file(bin_path, "boot.bin")
    hex_data = parse_byte_hex(hex_path, "boot.hex")
    mif_payload, mif_meta = parse_mif(mif_path)
    load_extent = int(elf_meta["load_extent"])
    if len(bin_data) != load_extent or bin_data != expected[:load_extent]:
        raise ContractError(
            f"boot.bin does not equal ELF PT_LOAD payload (bytes={len(bin_data)}, expected={load_extent})"
        )
    if hex_data != bin_data:
        raise ContractError("boot.hex does not equal boot.bin byte-for-byte")
    if mif_payload != expected:
        mismatch = next(
            (index for index, (actual, wanted) in enumerate(zip(mif_payload, expected)) if actual != wanted),
            None,
        )
        raise ContractError(f"boot.mif little-endian payload differs from ELF-derived 64 KiB image at offset {mismatch}")
    return expected, elf_meta, symbols, bin_data, hex_data, mif_payload, mif_meta


def expected_hex_write(path: Path, expected: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    try:
        path.write_text("".join(f"{byte:02x}\n" for byte in expected), encoding="ascii")
    except OSError as exc:
        raise ContractError(f"cannot write expected image {path}: {exc}") from exc


def build_manifest(
    args: argparse.Namespace,
    expected: bytes,
    elf_meta: dict[str, Any],
    bin_data: bytes,
    hex_data: bytes,
    mif_payload: bytes,
    mif_meta: dict[str, Any],
    sources: list[dict[str, Any]],
) -> dict[str, Any]:
    elf_path = Path(args.elf)
    bin_path = Path(args.bin)
    hex_path = Path(args.hex)
    mif_path = Path(args.mif)
    expected_path = Path(args.expected)
    expected_file = require_file(expected_path, "expected image")
    return {
        "schema_version": 1,
        "contract": "B25-BRAM-IMAGE-ELF-DERIVED-V1",
        "bram_bytes": BRAM_BYTES,
        "mif_width": MIF_WIDTH,
        "mif_depth": MIF_DEPTH,
        "elf": artifact_record(elf_path, require_file(elf_path, "ELF"), "elf64-aarch64"),
        "boot_bin": artifact_record(bin_path, bin_data, "load-image"),
        "boot_hex": {
            **artifact_record(hex_path, require_file(hex_path, "boot.hex"), "byte-hex"),
            "decoded_bytes": len(hex_data),
            "decoded_sha256": sha256_bytes(hex_data),
        },
        "boot_mif": {
            **artifact_record(mif_path, require_file(mif_path, "boot.mif"), "mif"),
            **mif_meta,
            "decoded_payload_bytes": len(mif_payload),
        },
        "expected_image": {
            "path": path_string(expected_path),
            "kind": "elf-derived-byte-hex",
            "bytes": len(expected_file),
            "sha256": sha256_bytes(expected_file),
            "decoded_bytes": len(expected),
            "decoded_sha256": sha256_bytes(expected),
            "zero_pad_bytes": BRAM_BYTES - int(elf_meta["load_extent"]),
        },
        "elf_layout": elf_meta,
        "sources": sources,
        "manifest_sha256": "",
    }


def write_manifest(path: Path, manifest: dict[str, Any]) -> None:
    manifest["manifest_sha256"] = canonical_manifest_hash(manifest)
    path.parent.mkdir(parents=True, exist_ok=True)
    try:
        path.write_text(
            json.dumps(manifest, ensure_ascii=False, sort_keys=True, indent=2) + "\n",
            encoding="utf-8",
        )
    except OSError as exc:
        raise ContractError(f"cannot write manifest {path}: {exc}") from exc


def compare_manifest(
    manifest: dict[str, Any],
    args: argparse.Namespace,
    expected: bytes,
    elf_meta: dict[str, Any],
    bin_data: bytes,
    hex_data: bytes,
    mif_payload: bytes,
    mif_meta: dict[str, Any],
) -> None:
    if manifest.get("contract") != "B25-BRAM-IMAGE-ELF-DERIVED-V1":
        raise ContractError("manifest contract name mismatch")
    if manifest.get("bram_bytes") != BRAM_BYTES or manifest.get("mif_width") != MIF_WIDTH or manifest.get("mif_depth") != MIF_DEPTH:
        raise ContractError("manifest BRAM/MIF geometry mismatch")
    path_map = {
        "elf": Path(args.elf),
        "boot_bin": Path(args.bin),
        "boot_hex": Path(args.hex),
        "boot_mif": Path(args.mif),
    }
    for key, path in path_map.items():
        record = manifest.get(key)
        if not isinstance(record, dict) or record.get("path") != path_string(path):
            raise ContractError(f"manifest path binding mismatch for {key}: {path}")
    expected_record = manifest.get("expected_image")
    expected_path = Path(args.expected)
    if not isinstance(expected_record, dict) or expected_record.get("path") != path_string(expected_path):
        raise ContractError(f"manifest path binding mismatch for expected image: {expected_path}")
    records = {
        "elf": require_file(Path(args.elf), "ELF"),
        "boot_bin": bin_data,
        "boot_hex": require_file(Path(args.hex), "boot.hex"),
        "boot_mif": require_file(Path(args.mif), "boot.mif"),
    }
    for key, data in records.items():
        record = manifest[key]
        if record.get("bytes") != len(data) or record.get("sha256") != sha256_bytes(data):
            raise ContractError(f"manifest artifact hash binding mismatch for {key}")
    expected_file_data = require_file(expected_path, "expected image")
    if expected_record.get("bytes") != len(expected_file_data) or expected_record.get("sha256") != sha256_bytes(expected_file_data):
        raise ContractError("manifest expected-image file hash binding mismatch")
    expected_decoded = parse_byte_hex(expected_path, "expected image")
    if expected_decoded != expected:
        raise ContractError("expected image does not equal ELF-derived 64 KiB image")
    if expected_record.get("decoded_bytes") != len(expected_decoded) or expected_record.get("decoded_sha256") != sha256_bytes(expected_decoded):
        raise ContractError("manifest expected-image decoded hash binding mismatch")
    elf_record = manifest["elf_layout"]
    if elf_record != elf_meta:
        raise ContractError("manifest ELF layout/reset binding mismatch")
    mif_record = manifest["boot_mif"]
    if mif_record.get("width") != mif_meta["width"] or mif_record.get("depth") != mif_meta["depth"] or mif_record.get("records") != mif_meta["records"] or mif_record.get("payload_sha256") != mif_meta["payload_sha256"]:
        raise ContractError("manifest MIF geometry/payload binding mismatch")
    if mif_payload != expected:
        raise ContractError("MIF payload mismatch")
    verify_source_records(manifest.get("sources"))


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--emit", action="store_true", help="derive and write expected image plus manifest")
    mode.add_argument("--check", action="store_true", help="strictly check existing expected image and manifest")
    parser.add_argument("--elf", required=True, type=Path)
    parser.add_argument("--bin", required=True, type=Path)
    parser.add_argument("--hex", required=True, type=Path)
    parser.add_argument("--mif", required=True, type=Path)
    parser.add_argument("--expected", required=True, type=Path, help="independent expected byte-HEX image")
    parser.add_argument("--manifest", required=True, type=Path)
    parser.add_argument("--source", action="append", default=[], type=Path, help="source file to hash-bind; repeatable")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(sys.argv[1:] if argv is None else argv)
    try:
        expected, elf_meta, _symbols, bin_data, hex_data, mif_payload, mif_meta = common_inputs(args)
        if args.emit:
            expected_hex_write(args.expected, expected)
            sources = source_records(args.source)
            manifest = build_manifest(
                args,
                expected,
                elf_meta,
                bin_data,
                hex_data,
                mif_payload,
                mif_meta,
                sources,
            )
            write_manifest(args.manifest, manifest)
            # Re-read the manifest so --emit itself proves the hash binding.
            loaded = load_manifest(args.manifest)
            compare_manifest(
                loaded,
                args,
                expected,
                elf_meta,
                bin_data,
                hex_data,
                mif_payload,
                mif_meta,
            )
            print(
                "IMAGE_CONTRACT_PASS "
                f"mode=emit load_bytes={elf_meta['load_extent']} expected_bytes={len(expected)} "
                f"bin_sha256={sha256_bytes(bin_data)} expected_sha256={sha256_bytes(expected)} "
                f"manifest_sha256={loaded['manifest_sha256']}"
            )
            return 0

        manifest = load_manifest(args.manifest)
        compare_manifest(
            manifest,
            args,
            expected,
            elf_meta,
            bin_data,
            hex_data,
            mif_payload,
            mif_meta,
        )
        print(
            "IMAGE_CONTRACT_PASS "
            f"mode=check load_bytes={elf_meta['load_extent']} expected_bytes={len(expected)} "
            f"bin_sha256={sha256_bytes(bin_data)} expected_sha256={sha256_bytes(expected)} "
            f"manifest_sha256={manifest['manifest_sha256']}"
        )
        return 0
    except (ContractError, OSError, ValueError, struct.error) as exc:
        print(f"IMAGE_CONTRACT_FAIL {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
