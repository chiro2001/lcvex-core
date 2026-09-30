#!/usr/bin/env python3
"""Offline checker for the Catapult A10 B0+ regenerable Quartus skeleton."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SKELETON = ROOT / "skeleton_manifest.json"
QSF = ROOT / "quartus/catapult_a10.qsf"
SDC = ROOT / "quartus/catapult_a10.sdc"
TOP = ROOT / "rtl/lcvex_catapult_a10_top.sv"
GATE = ROOT / "rtl/lcvex_catapult_a10_reset_gate.sv"
BOOT_BIN = ROOT / "boot/build/linux-loader/linux_loader.bin"
BOOT_MIF = ROOT / "boot/build/linux-loader/linux_loader.mif"
REQUIRED_TOOLS = ("quartus_sh", "ip-generate", "qsys-generate")
MIF_RECORD = re.compile(r"^([0-9A-Fa-f]{4})\s*:\s*([0-9A-Fa-f]{16});$")


def digest(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def read_text(path: Path) -> str:
    return path.read_text(encoding="utf-8", errors="replace")


def anchor(body: str, pattern: str, errors: list[str], where: str) -> None:
    if re.search(re.escape(pattern), body):
        return
    errors.append(f"missing anchor in {where}: {pattern}")


def check_boot_image(errors: list[str]) -> dict[str, object]:
    """Validate the generated Linux loader image without adding it to Git."""

    result: dict[str, object] = {
        "mif": str(BOOT_MIF),
        "bin": str(BOOT_BIN),
        "width": 64,
        "depth": 8192,
    }
    if not BOOT_BIN.is_file() or not BOOT_MIF.is_file():
        errors.append("Linux loader BIN/MIF missing; run boot/build_linux_loader.sh")
        return result

    body = read_text(BOOT_MIF)
    for pattern in ("WIDTH=64;", "DEPTH=8192;", "CONTENT BEGIN", "END;"):
        anchor(body, pattern, errors, "BOOT_MIF")

    records: dict[int, bytes] = {}
    for line in body.splitlines():
        match = MIF_RECORD.fullmatch(line.strip())
        if match is None:
            continue
        address = int(match.group(1), 16)
        if address in records:
            errors.append(f"duplicate Linux loader MIF address {address:04X}")
            continue
        if address >= 8192:
            errors.append(f"Linux loader MIF address out of range {address:04X}")
            continue
        records[address] = int(match.group(2), 16).to_bytes(8, "little")

    if set(records) != set(range(8192)):
        errors.append(f"Linux loader MIF records must cover 8192 words (got {len(records)})")
    else:
        image = b"".join(records[address] for address in range(8192))
        binary = BOOT_BIN.read_bytes()
        if len(binary) > len(image):
            errors.append("Linux loader BIN exceeds 64 KiB MIF capacity")
        elif image[: len(binary)] != binary or any(image[len(binary) :]):
            errors.append("Linux loader MIF byte content/padding differs from linux_loader.bin")

    qsf_mif = (QSF.parent / "../boot/build/linux-loader/linux_loader.mif").resolve()
    if qsf_mif != BOOT_MIF.resolve():
        errors.append("QSF-relative Linux loader MIF path does not resolve to boot/build/linux-loader/linux_loader.mif")
    result.update(
        {
            "records": len(records),
            "bin_bytes": BOOT_BIN.stat().st_size,
            "bin_sha256": digest(BOOT_BIN),
            "mif_bytes": BOOT_MIF.stat().st_size,
            "mif_sha256": digest(BOOT_MIF),
        }
    )
    return result


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--require-quartus",
        action="store_true",
        help="fail with exit 127 when Quartus/Qsys tools are missing",
    )
    parser.add_argument(
        "--require-boot-image",
        action="store_true",
        help="require and byte-check generated Linux loader BIN/MIF",
    )
    parser.add_argument(
        "--report-dir",
        default=os.environ.get(
            "LCVEX_SKELETON_REPORT_DIR",
            str(ROOT.parent.parent / "build" / "agents" / "T-20260827-062"),
        ),
        help="directory for the JSON toolchain/recovery report",
    )
    args = parser.parse_args()

    errors: list[str] = []
    try:
        manifest = json.loads(SKELETON.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        print(f"SKELETON_CHECK_FAIL manifest={exc}")
        return 1

    if manifest.get("schema_version") != 1:
        errors.append("schema_version must be 1")
    if manifest.get("task_id") != "T-20260827-062":
        errors.append("task_id mismatch")
    if manifest.get("top_level_entity") != "lcvex_catapult_a10_top":
        errors.append("top_level_entity mismatch")

    by_path: dict[str, dict[str, object]] = {}
    for entry in manifest.get("files", []):
        path = entry.get("path")
        if not isinstance(path, str) or not path or path.startswith("/") or ".." in Path(path).parts:
            errors.append(f"unsafe skeleton path {path!r}")
            continue
        if path in by_path:
            errors.append(f"duplicate skeleton path {path}")
            continue
        by_path[path] = entry
        target = ROOT / path
        if not target.is_file():
            errors.append(f"missing skeleton file {path}")
            continue
        if entry.get("bytes") != target.stat().st_size:
            errors.append(f"skeleton byte count mismatch {path}")
        expected = str(entry.get("sha256", "")).lower()
        if not re.fullmatch(r"[0-9a-f]{64}", expected) or digest(target) != expected:
            errors.append(f"skeleton SHA-256 mismatch {path}")

    qsf = read_text(QSF)
    for pattern in manifest.get("anchors", {}).get("qsf", []):
        anchor(qsf, pattern, errors, "QSF")
    sdc = read_text(SDC)
    for pattern in manifest.get("anchors", {}).get("sdc", []):
        anchor(sdc, pattern, errors, "SDC")

    top = read_text(TOP)
    for pattern in (
        "module lcvex_catapult_a10_top",
        "sys_clk_25",
        '`define LCVEX_CATAPULT_BOOT_INIT_IMAGE "../boot/build/linux-loader/linux_loader.mif"',
        ".BOOT_HEX_FILE(`LCVEX_CATAPULT_BOOT_INIT_IMAGE)",
        "Qsys emif (",
        "lcvex_catapult_a10_reset_gate",
        "jtag_uart_only_jtag_uart jtag_uart_inst",
        "sfl_sys sfl_inst",
        ".epcq_avl_mem_write         (1'b0)",
        ".epcq_avl_mem_burstcount    (epcq_mem_burstcount)",
        ".epcq_avl_mem_read          (epcq_mem_read)",
        ".epcq_avl_mem_address       (epcq_mem_address)",
        ".epcq_avl_mem_byteenable    (epcq_mem_byteenable)",
        ".epcq_avl_mem_readdata      (epcq_mem_readdata)",
        ".epcq_avl_mem_readdatavalid (epcq_mem_readdatavalid)",
        ".epcq_mem_read           (epcq_mem_read)",
        ".epcq_mem_address        (epcq_mem_address)",
        ".epcq_mem_burstcount     (epcq_mem_burstcount)",
        ".epcq_mem_byteenable     (epcq_mem_byteenable)",
        ".epcq_mem_waitrequest    (epcq_mem_waitrequest)",
        ".epcq_mem_readdata       (epcq_mem_readdata)",
        ".epcq_mem_readdatavalid  (epcq_mem_readdatavalid)",
        "emif_bot_status_local_cal_success",
        "reset_in_reset",
    ):
        anchor(top, pattern, errors, "TOP")
    gate = read_text(GATE)
    for pattern in (
        "module lcvex_catapult_a10_reset_gate",
        "logic_clk",
        "emif_usr_clk",
        "cal_success",
        "cal_fail",
        "cal_ready",
        "cal_failed",
        "ddr_en",
        "logic_rst_n",
        "emif_rst_n",
    ):
        anchor(gate, pattern, errors, "GATE")

    boot_image: dict[str, object] | None = None
    if args.require_boot_image:
        anchor(
            qsf,
            "set_global_assignment -name VERILOG_MACRO SYNTHESIS",
            errors,
            "QSF",
        )
        anchor(
            qsf,
            'set_global_assignment -name MIF_FILE "../boot/build/linux-loader/linux_loader.mif"',
            errors,
            "QSF",
        )
        boot_image = check_boot_image(errors)

    missing: list[str] = []
    for tool in REQUIRED_TOOLS:
        if shutil.which(tool) is None:
            missing.append(tool)

    report_dir = Path(args.report_dir)
    report = {
        "task_id": "T-20260827-062",
        "offline_checks": "pass" if not errors else "fail",
        "quartus_toolchain": {
            "missing": missing,
            "recovery": [
                "install Quartus Prime Pro 21.4 Build 67 and expose quartus/bin and qsys/bin in PATH",
                "re-run fpga/catapult_a10/tools/regenerate_qsys.sh (exit 127 reports TOOL_MISSING until tools exist)",
                "then re-run python3 fpga/catapult_a10/tools/check_skeleton.py --require-quartus",
            ],
        },
        "boot_image": boot_image,
        "report_dir": str(report_dir),
    }
    try:
        report_dir.mkdir(parents=True, exist_ok=True)
        report_path = report_dir / "skeleton-toolchain-report.json"
        report_path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    except OSError as exc:
        errors.append(f"cannot write toolchain report: {exc}")

    if missing:
        print("TOOLCHAIN_MISSING " + ",".join(missing))
        for line in report["quartus_toolchain"]["recovery"]:
            print(f"  recovery: {line}")

    if errors:
        print("SKELETON_CHECK_FAIL")
        print("\n".join(f"- {item}" for item in errors))
        return 1
    if args.require_quartus and missing:
        print("SKELETON_CHECK_BLOCKED_QUARTUS_MISSING")
        return 127
    print(f"SKELETON_CHECK_PASS files={len(by_path)} toolchain_report={report_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
