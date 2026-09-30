#!/usr/bin/env python3
"""Emit a deterministic provenance manifest for the B25 BRAM image."""

from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import subprocess
from pathlib import Path


def digest(path: Path) -> dict[str, object]:
    data = path.read_bytes()
    return {"bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--elf", type=Path, required=True)
    parser.add_argument("--bin", dest="binary", type=Path, required=True)
    parser.add_argument("--hex", dest="hex_file", type=Path, required=True)
    parser.add_argument("--mif", type=Path, required=True)
    parser.add_argument("--compiler", required=True)
    parser.add_argument("--cflags", required=True)
    args = parser.parse_args()

    repo = Path(__file__).resolve().parents[3]
    sources = [
        "fpga/catapult_a10/boot/boot.S",
        "fpga/catapult_a10/boot/boot.ld",
        "fpga/catapult_a10/boot/build.sh",
        "fpga/catapult_a10/boot/bin_to_mif.py",
        "fpga/catapult_a10/coremark/core_portme.h",
        "fpga/catapult_a10/coremark/core_portme.c",
        "fpga/catapult_a10/coremark/ee_printf.c",
        "fpga/catapult_a10/coremark/emit_build_manifest.py",
        "fpga/catapult_a10/coremark/lcvex_bench.c",
        "fpga/catapult_a10/coremark/upstream-manifest.json",
    ]
    upstream_manifest = json.loads((repo / sources[-1]).read_text(encoding="utf-8"))
    for name in sorted(upstream_manifest["files"]):
        sources.append(f"fpga/catapult_a10/coremark/upstream/{name}")

    compiler_path = shutil.which(args.compiler)
    if compiler_path is None:
        raise SystemExit(f"compiler not found: {args.compiler}")
    compiler_version = subprocess.run(
        [compiler_path, "--version"], check=True, text=True,
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
    ).stdout.splitlines()[0]

    manifest = {
        "schema_version": 1,
        "target": "LCVEX Catapult A10 B25 25MHz 64KiB BRAM",
        "compiler": {
            "path": str(Path(compiler_path).resolve()),
            "version": compiler_version,
            "flags": args.cflags.replace(str(repo), "$REPO"),
        },
        "coremark": {
            "repository": upstream_manifest["repository"],
            "tag": upstream_manifest["tag"],
            "commit": upstream_manifest["commit"],
            "total_data_size": 2000,
            "contexts": 1,
            "seed1": 0,
            "seed2": 0,
            "seed3": 0x66,
            "short_iterations": 1,
            "full_iterations": "automatic",
            "clock_hz": 25_000_000,
            "minimum_valid_cycles": 250_000_000,
        },
        "artifacts": {
            "boot.elf": digest(args.elf),
            "boot.bin": digest(args.binary),
            "boot.hex": digest(args.hex_file),
            "boot.mif": digest(args.mif),
        },
        "sources": {name: digest(repo / name)["sha256"] for name in sources},
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(f"MICROBENCH_MANIFEST_PASS output={args.output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
