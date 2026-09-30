#!/usr/bin/env python3
"""Check the Catapult Quartus SYNTHESIS build-contract selection.

This is intentionally independent from check_platform.py: it adds the
branch/file-list audit while check_platform.py enforces the exact single
SYNTHESIS macro policy.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
QSF = ROOT / "quartus/catapult_a10.qsf"
MANIFEST = ROOT / "platform_manifest.json"
SUMS = ROOT / "SHA256SUMS"
LOCK = ROOT / "source.lock"


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def active_lines(text: str) -> list[str]:
    return [line.strip() for line in text.splitlines() if line.strip() and not line.lstrip().startswith("#")]


def check(reference_qsf: Path | None = None) -> tuple[dict[str, object], list[str]]:
    errors: list[str] = []
    qsf_text = QSF.read_text(encoding="utf-8")
    active_qsf = active_lines(qsf_text)
    macro_lines = [line for line in active_qsf if re.fullmatch(r"set_global_assignment -name VERILOG_MACRO SYNTHESIS", line)]
    all_macro_lines = [line for line in active_qsf if "VERILOG_MACRO" in line]
    if len(macro_lines) != 1:
        errors.append(f"expected exactly one active SYNTHESIS macro, got {len(macro_lines)}")
    if all_macro_lines != macro_lines:
        errors.append(f"unexpected active macro assignments: {all_macro_lines}")

    reference_macro_count: int | None = None
    if reference_qsf is not None:
        if not reference_qsf.is_file():
            errors.append(f"reference QSF missing: {reference_qsf}")
        else:
            reference = active_lines(reference_qsf.read_text(encoding="utf-8"))
            reference_macro_count = sum(line == "set_global_assignment -name VERILOG_MACRO SYNTHESIS" for line in reference)
            if reference_macro_count != 1:
                errors.append(f"reference SYNTHESIS macro count is {reference_macro_count}")

    expected_qsf = 'set_global_assignment -name MIF_FILE "../boot/build/boot.mif"'
    if expected_qsf not in active_qsf:
        errors.append("QSF MIF assignment missing")
    if active_qsf.count('set_global_assignment -name SYSTEMVERILOG_FILE "../../rtl/lcvex_bram_boot.sv"') != 1:
        errors.append("QSF lcvex_bram_boot.sv assignment is not unique")
    if any("lcvex_bram_boot_altsyncram.sv" in line for line in active_qsf):
        errors.append("standalone lcvex_bram_boot_altsyncram.sv must not be in QSF")
    if active_qsf.count('set_global_assignment -name SYSTEMVERILOG_FILE "../../rtl/lcvex_cache_data_ram.sv"') != 1:
        errors.append("QSF lcvex_cache_data_ram.sv assignment is not unique")

    bram = (Path(__file__).parents[2] / "../rtl/lcvex_bram_boot.sv").resolve().read_text(encoding="utf-8")
    cache = (Path(__file__).parents[2] / "../rtl/lcvex_cache_data_ram.sv").resolve().read_text(encoding="utf-8")
    top = (ROOT / "rtl/lcvex_catapult_a10_top.sv").read_text(encoding="utf-8")
    scalar = (Path(__file__).parents[2] / "../rtl/lcvex_fp_scalar.sv").resolve().read_text(encoding="utf-8")

    if not re.search(r"`ifdef SYNTHESIS\s+lcvex_bram_boot_altsyncram", bram):
        errors.append("BRAM SYNTHESIS branch does not select lcvex_bram_boot_altsyncram")
    if not re.search(r"`ifndef SYNTHESIS\s+module lcvex_bram_boot_behav", bram):
        errors.append("BRAM behavioral fallback is not guarded by ifndef SYNTHESIS")
    if bram.count("module lcvex_bram_boot_altsyncram") != 1:
        errors.append("main BRAM contains unexpected duplicate altsyncram module")
    if "altera_syncram" not in bram or not re.search(r"\.init_file\s*\(INIT_FILE\)", bram):
        errors.append("BRAM synthesis branch lacks explicit altera_syncram/init_file")
    cache_ifdef = cache.find("`ifdef SYNTHESIS")
    cache_else = cache.find("`else", cache_ifdef)
    cache_synth = cache[cache_ifdef:cache_else] if cache_ifdef >= 0 and cache_else >= 0 else ""
    cache_behav = cache[cache_else:] if cache_else >= 0 else ""
    if not cache_synth:
        errors.append("cache SYNTHESIS branch anchor missing")
    if "altera_syncram" not in cache_synth or not re.search(r'ram_block_type\s*\("M20K"\)', cache_synth):
        errors.append("cache synthesis branch lacks M20K altera_syncram")
    if "logic [DATA_BITS-1:0] mem" not in cache_behav:
        errors.append("cache behavioral branch anchor missing")
    if "`define LCVEX_CATAPULT_BOOT_INIT_IMAGE \"../boot/build/boot.mif\"" not in top:
        errors.append("A10 synthesis boot MIF define missing")
    if "`define LCVEX_CATAPULT_BOOT_INIT_IMAGE \"fpga/catapult_a10/boot/build/boot.hex\"" not in top:
        errors.append("A10 simulation boot HEX define missing")
    if not re.search(r"`ifndef SYNTHESIS\s+.*?assert property", scalar, re.DOTALL):
        errors.append("FP synthesis assertion exclusion anchor missing")

    try:
        manifest = json.loads(MANIFEST.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        errors.append(f"manifest read failed: {exc}")
        manifest = {}
    entries = manifest.get("files", [])
    if len(entries) != 50:
        errors.append(f"platform manifest count is {len(entries)}, expected 50")
    manifest_paths: set[str] = set()
    qsf_entry: dict[str, object] | None = None
    for entry in entries:
        path = entry.get("path")
        if not isinstance(path, str):
            errors.append("manifest entry path is not a string")
            continue
        manifest_paths.add(path)
        target = ROOT / path
        if not target.is_file():
            errors.append(f"manifest target missing: {path}")
            continue
        if entry.get("bytes") != target.stat().st_size or entry.get("sha256") != sha256(target):
            errors.append(f"manifest target hash/bytes mismatch: {path}")
        if path == "quartus/catapult_a10.qsf":
            qsf_entry = entry
    if qsf_entry is None:
        errors.append("manifest lacks quartus/catapult_a10.qsf")

    sums: dict[str, str] = {}
    for line in SUMS.read_text(encoding="utf-8").splitlines():
        if line and not line.startswith("#"):
            digest, path = line.split(maxsplit=1)
            sums[path.lstrip("*")] = digest.lower()
    if set(sums) != manifest_paths:
        errors.append("SHA256SUMS file set differs from platform manifest")
    for path in manifest_paths:
        if sums.get(path) != next((e.get("sha256") for e in entries if e.get("path") == path), None):
            errors.append(f"SHA256SUMS mismatch: {path}")

    lock_targets: set[str] = set()
    for line in LOCK.read_text(encoding="utf-8").splitlines():
        if line and not line.startswith("#"):
            fields = line.split("\t")
            if len(fields) == 5:
                lock_targets.add(fields[3])
    if lock_targets != manifest_paths:
        errors.append("source.lock target set differs from platform manifest")

    result = {
        "macro_lines": macro_lines,
        "reference_macro_count": reference_macro_count,
        "qsf_mif_assignment": expected_qsf in active_qsf,
        "qsf_bram_assignment_count": active_qsf.count('set_global_assignment -name SYSTEMVERILOG_FILE "../../rtl/lcvex_bram_boot.sv"'),
        "qsf_standalone_altsyncram_assignment_count": sum("lcvex_bram_boot_altsyncram.sv" in line for line in active_qsf),
        "bram_behav_guarded": bool(re.search(r"`ifndef SYNTHESIS\s+module lcvex_bram_boot_behav", bram)),
        "bram_altsyncram_module_count": bram.count("module lcvex_bram_boot_altsyncram"),
        "cache_m20k_altera_syncram": "altera_syncram" in cache and 'ram_block_type                     ("M20K")' in cache,
        "simulation_boot_hex": 'fpga/catapult_a10/boot/build/boot.hex' in top,
        "synthesis_boot_mif": '../boot/build/boot.mif' in top,
        "platform_manifest_count": len(entries),
        "platform_manifest_qsf": qsf_entry,
        "source_lock_target_count": len(lock_targets),
    }
    return result, errors


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--reference-qsf",
        type=Path,
        default=None,
        help="optional external reference QSF; exact single SYNTHESIS macro is checked only when supplied",
    )
    args = parser.parse_args()
    result, errors = check(args.reference_qsf)
    result["status"] = "FAIL" if errors else "PASS"
    print(json.dumps(result, indent=2, sort_keys=True))
    if errors:
        print("SYNTHESIS_SELECTOR_CHECK_FAIL", file=sys.stderr)
        for error in errors:
            print(f"- {error}", file=sys.stderr)
        return 1
    print("SYNTHESIS_SELECTOR_CHECK_PASS", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
