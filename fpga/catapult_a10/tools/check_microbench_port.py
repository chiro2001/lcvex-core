#!/usr/bin/env python3
"""Static/provenance checks for the B25 BRAM microbench image."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import subprocess
from pathlib import Path


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def fail(message: str) -> None:
    raise SystemExit(f"MICROBENCH_PORT_FAIL reason={message}")


def tool_output(tool: str, *args: str) -> str:
    return subprocess.run(
        [tool, *args], check=True, text=True,
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
    ).stdout


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--elf", type=Path, required=True)
    parser.add_argument("--bin", dest="binary", type=Path, required=True)
    parser.add_argument("--hex", dest="hex_file", type=Path, required=True)
    parser.add_argument("--mif", type=Path, required=True)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--nm", default="aarch64-linux-gnu-nm")
    parser.add_argument("--objdump", default="aarch64-linux-gnu-objdump")
    args = parser.parse_args()

    repo = Path(__file__).resolve().parents[3]
    coremark = repo / "fpga/catapult_a10/coremark"
    upstream = coremark / "upstream"
    frozen_path = coremark / "upstream-manifest.json"
    if sha256(frozen_path) != "4c30429c9039b7d3875fc7be1fe5951f1200cf07d1be0ce4778c999e18940e84":
        fail("pinned upstream manifest changed")
    frozen = json.loads(frozen_path.read_text(encoding="utf-8"))
    actual_names = {path.name for path in upstream.iterdir() if path.is_file()}
    expected_names = set(frozen["files"])
    if actual_names != expected_names:
        fail(f"upstream file set mismatch actual={sorted(actual_names)}")
    for name, expected in frozen["files"].items():
        actual = sha256(upstream / name)
        if actual != expected:
            fail(f"upstream hash mismatch file={name} actual={actual}")
    if frozen.get("tag") != "v1.01" or frozen.get("commit") != "cfa9ab377835911f23d9b0831c7be302ed1f58de":
        fail("unexpected CoreMark source pin")
    license_text = (upstream / "LICENSE.md").read_text(encoding="utf-8")
    if "COREMARK® ACCEPTABLE USE AGREEMENT" not in license_text or len(license_text) < 9_000:
        fail("CoreMark Acceptable Use Agreement is incomplete")

    manifest = json.loads(args.manifest.read_text(encoding="utf-8"))
    artifact_paths = {
        "boot.elf": args.elf,
        "boot.bin": args.binary,
        "boot.hex": args.hex_file,
        "boot.mif": args.mif,
    }
    for name, path in artifact_paths.items():
        entry = manifest.get("artifacts", {}).get(name, {})
        if entry.get("sha256") != sha256(path) or entry.get("bytes") != path.stat().st_size:
            fail(f"artifact manifest mismatch file={name}")
    for name, expected in manifest.get("sources", {}).items():
        if sha256(repo / name) != expected:
            fail(f"source manifest mismatch file={name}")
    config = manifest.get("coremark", {})
    required_config = {
        "total_data_size": 2000,
        "contexts": 1,
        "seed1": 0,
        "seed2": 0,
        "seed3": 0x66,
        "short_iterations": 1,
        "clock_hz": 25_000_000,
        "minimum_valid_cycles": 250_000_000,
    }
    for key, expected in required_config.items():
        if config.get(key) != expected:
            fail(f"manifest configuration mismatch {key}")
    flags = manifest.get("compiler", {}).get("flags", "")
    for required in ("-O2", "-march=armv8.2-a", "-mgeneral-regs-only", "-ffreestanding", "-fno-builtin", "-fno-pie"):
        if required not in flags.split():
            fail(f"missing compiler flag {required}")

    binary = args.binary.read_bytes()
    hex_lines = args.hex_file.read_text(encoding="ascii").splitlines()
    try:
        hex_bytes = bytes(int(line, 16) for line in hex_lines)
    except ValueError as exc:
        fail(f"invalid byte HEX: {exc}")
    if hex_bytes != binary:
        fail("boot.hex is not byte-identical to boot.bin")
    mif_text = args.mif.read_text(encoding="ascii")
    if "WIDTH=64;" not in mif_text or "DEPTH=8192;" not in mif_text:
        fail("MIF geometry is not 8192x64")

    nm = tool_output(args.nm, "-n", str(args.elf))
    undefined = tool_output(args.nm, "-u", str(args.elf)).strip()
    if undefined:
        fail(f"ELF has undefined symbols: {undefined}")
    symbols: dict[str, int] = {}
    for line in nm.splitlines():
        match = re.fullmatch(r"([0-9a-fA-F]+)\s+\S\s+(\S+)", line)
        if match:
            symbols[match.group(2)] = int(match.group(1), 16)
    for name in (
        "_start", "lcvex_run_correctness", "lcvex_run_coremark_short",
        "lcvex_run_coremark_full", "coremark_main", "static_memblk",
        "__image_end", "__stack_limit", "__stack_top",
    ):
        if name not in symbols:
            fail(f"required ELF symbol missing: {name}")
    if symbols["_start"] != 0 or symbols["__image_end"] > 0xF000:
        fail("ELF image/BSS overlaps reserved stack")
    if symbols["__stack_limit"] != 0xF000 or symbols["__stack_top"] != 0x10000:
        fail("ELF stack contract changed")

    disassembly = tool_output(args.objdump, "-d", str(args.elf))
    if re.search(r"\bmrs\b[^\n]*(cntvct|cntpct)", disassembly, re.IGNORECASE):
        fail("architectural counter used instead of PLAT_STATUS cycle counter")
    mnemonics = set(re.findall(r"^[ \t]*[0-9a-f]+:[ \t]+[0-9a-f]{8}[ \t]+([.a-z0-9]+)", disassembly, re.MULTILINE))
    for mnemonic in (
        "asr", "ror", "mul", "udiv", "sdiv", "umulh", "ldrsb",
        "ldrsh", "strb", "strh",
    ):
        if mnemonic not in mnemonics:
            fail(f"directed microbench instruction missing: {mnemonic}")
    if any(mnemonic.startswith(("fadd", "fsub", "fmul", "fdiv", "fcvt")) for mnemonic in mnemonics):
        fail("floating-point instruction present in no-FP payload")
    for marker in (b"MBPASS 24 ", b"CMSELF PASS", b"CMRESULT VALID"):
        if marker not in args.elf.read_bytes():
            fail(f"ELF output marker missing: {marker!r}")

    build_text = (repo / "fpga/catapult_a10/boot/build.sh").read_text(encoding="utf-8")
    if re.search(r"\b(curl|wget|git[ \t]+clone)\b", build_text):
        fail("normal image build contains a network fetch")
    port_text = (coremark / "core_portme.c").read_text(encoding="utf-8")
    if "0x09003040UL" not in port_text or "25000000UL" not in port_text:
        fail("CoreMark port does not use the frozen 25 MHz counter ABI")

    print(
        "MICROBENCH_PORT_PASS "
        f"upstream_files={len(expected_names)} bin_bytes={len(binary)} "
        f"image_end=0x{symbols['__image_end']:x}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
