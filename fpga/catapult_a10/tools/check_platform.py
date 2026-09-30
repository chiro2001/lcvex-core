#!/usr/bin/env python3
"""Offline and strict-source checker for the Catapult A10 platform package.

The default invocation is intentionally offline: it checks the checked-in
payload, manifest, source.lock and SHA256SUMS without opening the sibling
reference repository.  ``--strict-source`` opts into read-only git checks for
the manifest's source repository and commit.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import subprocess
import sys
from pathlib import Path, PurePosixPath


ROOT = Path(__file__).resolve().parents[1]
MANIFEST = ROOT / "platform_manifest.json"
LOCK = ROOT / "source.lock"
SUMS = ROOT / "SHA256SUMS"
PAYLOAD_ROOTS = (
    ROOT / "quartus",
    ROOT / "qsys" / "ddr4_bot",
    ROOT / "flash" / "sfl",
    ROOT / "jtag_uart",
)
EXPECTED_FILE_COUNT = 50
HEX64 = re.compile(r"[0-9a-fA-F]{64}")
FULL_COMMIT = re.compile(r"[0-9a-fA-F]{40}")
FORBIDDEN = (
    r"\bvexriscv\b", r"\brv32\b", r"\bsv32\b", r"\bopensbi\b",
    r"\bclint\b", r"\bplic\b", r"\bc_alias\b", r"\baxi4\b", r"\bcache\b",
)


def digest(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def digest_bytes(body: bytes) -> str:
    return hashlib.sha256(body).hexdigest()


def read_text(path: Path) -> str:
    return path.read_text(encoding="utf-8", errors="replace")


def safe_relative_path(value: object) -> bool:
    """Return whether *value* is a canonical repository-relative POSIX path."""

    if not isinstance(value, str) or not value or "\x00" in value:
        return False
    if value.startswith(("/", "\\")) or re.match(r"^[A-Za-z]:", value):
        return False
    # Git paths in the lock/manifest are POSIX paths.  Reject backslashes so
    # that a Windows-style ``..\\outside`` cannot evade the traversal check.
    if "\\" in value:
        return False
    if value == "." or value.startswith("./") or "/./" in value:
        return False
    parts = PurePosixPath(value).parts
    return bool(parts) and ".." not in parts


def valid_nonnegative_int(value: object) -> bool:
    return isinstance(value, int) and not isinstance(value, bool) and value >= 0


def parse_manifest(errors: list[str]) -> tuple[dict[str, object], dict[str, dict[str, object]]]:
    try:
        manifest = json.loads(MANIFEST.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        errors.append(f"manifest={exc}")
        return {}, {}

    if not isinstance(manifest, dict):
        errors.append("manifest must be an object")
        return {}, {}

    entries = manifest.get("files", [])
    if not isinstance(entries, list) or not entries:
        errors.append("files must be a non-empty list")
        entries = []
    elif len(entries) != EXPECTED_FILE_COUNT:
        errors.append(
            f"manifest file count must be {EXPECTED_FILE_COUNT} (got {len(entries)})"
        )

    by_path: dict[str, dict[str, object]] = {}
    source_paths: dict[str, str] = {}
    for entry in entries:
        if not isinstance(entry, dict):
            errors.append("non-object file entry")
            continue

        target_path = entry.get("path")
        if not safe_relative_path(target_path):
            errors.append(f"unsafe path {target_path!r}")
            target = None
        else:
            assert isinstance(target_path, str)
            if target_path in by_path:
                errors.append(f"duplicate path {target_path}")
            else:
                by_path[target_path] = entry
            target = ROOT / target_path

        source_path = entry.get("source_path")
        if not safe_relative_path(source_path):
            errors.append(f"unsafe source path {source_path!r}")
        elif isinstance(source_path, str):
            previous_target = source_paths.get(source_path)
            if previous_target is not None:
                errors.append(
                    f"duplicate source path {source_path} ({previous_target}, {target_path})"
                )
            else:
                source_paths[source_path] = str(target_path)

        if target is None:
            continue
        if target.is_symlink():
            errors.append(f"payload must not be a symlink {target_path}")
        if not target.is_file():
            errors.append(f"missing payload {target_path}")
            continue

        expected_bytes = entry.get("bytes")
        if not valid_nonnegative_int(expected_bytes):
            errors.append(f"target byte count malformed {target_path}")
        elif target.stat().st_size != expected_bytes:
            errors.append(f"byte count mismatch {target_path}")

        expected = str(entry.get("sha256", "")).lower()
        if not HEX64.fullmatch(expected) or digest(target) != expected:
            errors.append(f"target SHA-256 mismatch {target_path}")

        source_sha = str(entry.get("source_sha256", ""))
        if not HEX64.fullmatch(source_sha):
            errors.append(f"source SHA-256 malformed {target_path}")
        source_bytes = entry.get("source_bytes")
        if not valid_nonnegative_int(source_bytes):
            errors.append(f"source byte count malformed {target_path}")
        if not isinstance(entry.get("role"), str) or not entry.get("role"):
            errors.append(f"provenance role missing {target_path}")

    return manifest, by_path


def check_payload_set(by_path: dict[str, dict[str, object]], errors: list[str]) -> None:
    actual_payload = {
        path.relative_to(ROOT).as_posix()
        for directory in PAYLOAD_ROOTS
        for path in directory.rglob("*")
        if path.is_file()
    }
    if actual_payload != set(by_path):
        errors.append("payload file set differs from manifest")


def check_sums(by_path: dict[str, dict[str, object]], errors: list[str]) -> dict[str, str]:
    if not SUMS.is_file():
        errors.append("missing SHA256SUMS")
        return {}

    sums: dict[str, str] = {}
    try:
        lines = SUMS.read_text(encoding="utf-8").splitlines()
    except OSError as exc:
        errors.append(f"cannot read SHA256SUMS: {exc}")
        return {}
    for line_number, line in enumerate(lines, 1):
        if not line or line.startswith("#"):
            continue
        fields = line.split(maxsplit=1)
        if len(fields) != 2 or not HEX64.fullmatch(fields[0]):
            errors.append(f"malformed SHA256SUMS line {line_number}")
            continue
        target_path = fields[1][1:] if fields[1].startswith("*") else fields[1]
        if not safe_relative_path(target_path):
            errors.append(f"unsafe SHA256SUMS path {target_path!r}")
            continue
        if target_path in sums:
            errors.append(f"duplicate SHA256SUMS path {target_path}")
            continue
        sums[target_path] = fields[0].lower()

    for target_path, entry in by_path.items():
        expected = str(entry.get("sha256", "")).lower()
        actual = sums.get(target_path)
        if actual is None:
            errors.append(f"SHA256SUMS missing {target_path}")
        elif actual != expected:
            errors.append(f"SHA256SUMS mismatch {target_path}")
    if set(sums) != set(by_path):
        errors.append("SHA256SUMS file set differs from manifest")
    return sums


def parse_lock(
    by_path: dict[str, dict[str, object]], errors: list[str]
) -> dict[str, tuple[str, int, str, str]]:
    if not LOCK.is_file():
        errors.append("missing source.lock")
        return {}

    locked: dict[str, tuple[str, int, str, str]] = {}
    source_paths: dict[str, str] = {}
    row_count = 0
    try:
        lines = LOCK.read_text(encoding="utf-8").splitlines()
    except OSError as exc:
        errors.append(f"cannot read source.lock: {exc}")
        return {}

    for line_number, line in enumerate(lines, 1):
        if not line or line.startswith("#"):
            continue
        row_count += 1
        fields = line.split("\t")
        if len(fields) != 5:
            errors.append(f"malformed source.lock line {line_number}")
            continue
        source_sha, source_bytes_text, source_path, target_path, role = fields
        if not HEX64.fullmatch(source_sha):
            errors.append(f"malformed source SHA-256 line {line_number}")
        if not source_bytes_text.isdecimal():
            errors.append(f"malformed source byte count line {line_number}")
            source_bytes = -1
        else:
            source_bytes = int(source_bytes_text)
        if not safe_relative_path(source_path):
            errors.append(f"unsafe source.lock source path {source_path!r}")
        if not safe_relative_path(target_path):
            errors.append(f"unsafe source.lock target path {target_path!r}")
        if not role:
            errors.append(f"missing source.lock role line {line_number}")
        if target_path in locked:
            errors.append(f"duplicate source.lock target path {target_path}")
            continue
        previous_target = source_paths.get(source_path)
        if previous_target is not None:
            errors.append(
                f"duplicate source.lock source path {source_path} "
                f"({previous_target}, {target_path})"
            )
            continue
        source_paths[source_path] = target_path
        locked[target_path] = (source_sha.lower(), source_bytes, source_path, role)

    if row_count != EXPECTED_FILE_COUNT:
        errors.append(
            f"source.lock row count must be {EXPECTED_FILE_COUNT} (got {row_count})"
        )

    for target_path, entry in by_path.items():
        item = locked.get(target_path)
        if item is None:
            errors.append(f"source.lock missing {target_path}")
            continue
        expected = (
            str(entry.get("source_sha256", "")).lower(),
            entry.get("source_bytes"),
            str(entry.get("source_path", "")),
            str(entry.get("role", "")),
        )
        if item != expected:
            errors.append(f"source.lock mismatch {target_path}")
    if set(locked) != set(by_path):
        errors.append("source.lock file set differs from manifest")
    return locked


def git_text(repo: Path, *args: str) -> tuple[int, str, str]:
    try:
        result = subprocess.run(
            ["git", "-C", str(repo), *args],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            errors="replace",
            check=False,
        )
    except OSError as exc:
        return 127, "", str(exc)
    return result.returncode, result.stdout.strip(), result.stderr.strip()


def git_blob(repo: Path, revision: str, source_path: str) -> tuple[int, bytes, str]:
    try:
        result = subprocess.run(
            ["git", "-C", str(repo), "cat-file", "blob", f"{revision}:{source_path}"],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
    except OSError as exc:
        return 127, b"", str(exc)
    return result.returncode, result.stdout, result.stderr.decode("utf-8", errors="replace").strip()


def check_strict_source(
    manifest: dict[str, object],
    by_path: dict[str, dict[str, object]],
    locked: dict[str, tuple[str, int, str, str]],
    repo_argument: str | None,
    commit_argument: str | None,
    errors: list[str],
) -> tuple[Path | None, str | None]:
    provenance = manifest.get("provenance")
    if not isinstance(provenance, dict):
        errors.append("manifest.provenance must be an object for --strict-source")
        return None, None

    manifest_commit = provenance.get("source_commit")
    if not isinstance(manifest_commit, str) or not FULL_COMMIT.fullmatch(manifest_commit):
        errors.append("manifest provenance source_commit must be a full 40-hex commit")
        return None, None
    expected_commit = manifest_commit.lower()
    try:
        lock_header_lines = LOCK.read_text(encoding="utf-8").splitlines()
    except OSError as exc:
        errors.append(f"cannot read source.lock header: {exc}")
        lock_header_lines = []
    header_pattern = re.compile(
        r"^#\s*source project\s+(?P<project>\S+)\s+@\s+(?P<commit>[0-9a-fA-F]{40})\s*$"
    )
    declared_headers = [
        match
        for line in lock_header_lines
        if (match := header_pattern.match(line)) is not None
    ]
    for header in declared_headers:
        if header.group("commit").lower() != expected_commit:
            errors.append("source.lock header commit differs from manifest provenance")
        source_project = provenance.get("source_project")
        if isinstance(source_project, str) and header.group("project") != source_project:
            errors.append("source.lock header project differs from manifest provenance")
    if len(declared_headers) > 1:
        errors.append("source.lock has multiple provenance headers")
    if commit_argument is not None:
        if not FULL_COMMIT.fullmatch(commit_argument):
            errors.append("--source-commit must be a full 40-hex commit")
        elif commit_argument.lower() != expected_commit:
            errors.append("--source-commit differs from manifest provenance")
        else:
            expected_commit = commit_argument.lower()

    repo_value = repo_argument or provenance.get("source_repo_path")
    if not isinstance(repo_value, str) or not repo_value:
        errors.append("--strict-source requires a source repository path")
        return None, expected_commit
    repo = Path(repo_value).expanduser()
    try:
        repo = repo.resolve(strict=True)
    except OSError as exc:
        errors.append(f"source repository unavailable {repo_value!r}: {exc}")
        return None, expected_commit
    if not repo.is_dir():
        errors.append(f"source repository is not a directory {repo}")
        return None, expected_commit

    rc, top_level, detail = git_text(repo, "rev-parse", "--show-toplevel")
    if rc != 0:
        errors.append(f"source repository is not a git worktree {repo}: {detail or rc}")
        return repo, expected_commit

    rc, status, detail = git_text(repo, "status", "--porcelain=v1", "--untracked-files=all")
    if rc != 0:
        errors.append(f"cannot inspect source repository status: {detail or rc}")
    elif status:
        errors.append(f"source repository is not clean: {top_level or repo}")

    rc, head, detail = git_text(repo, "rev-parse", "--verify", "HEAD^{commit}")
    if rc != 0:
        errors.append(f"cannot resolve source repository HEAD: {detail or rc}")
    elif head.lower() != expected_commit:
        errors.append(
            f"source repository HEAD mismatch expected {expected_commit} got {head}"
        )

    rc, resolved, detail = git_text(repo, "rev-parse", "--verify", f"{expected_commit}^{{commit}}")
    if rc != 0 or resolved.lower() != expected_commit:
        errors.append(f"source commit is not resolvable {expected_commit}: {detail or resolved or rc}")

    checked = 0
    for target_path, entry in by_path.items():
        source_path = entry.get("source_path")
        if not isinstance(source_path, str) or not safe_relative_path(source_path):
            continue
        if target_path not in locked:
            continue
        rc, body, detail = git_blob(repo, expected_commit, source_path)
        if rc != 0:
            errors.append(f"strict-source missing {source_path}: {detail or rc}")
            continue
        checked += 1
        expected_sha = str(entry.get("source_sha256", "")).lower()
        expected_bytes = entry.get("source_bytes")
        if digest_bytes(body) != expected_sha:
            errors.append(f"strict-source SHA-256 mismatch {source_path}")
        if not valid_nonnegative_int(expected_bytes) or len(body) != expected_bytes:
            errors.append(f"strict-source byte count mismatch {source_path}")

    if checked != EXPECTED_FILE_COUNT:
        errors.append(
            f"strict-source checked {checked}/{EXPECTED_FILE_COUNT} source blobs"
        )
    return repo, expected_commit


def check_platform_contract(manifest: dict[str, object], errors: list[str]) -> None:
    if manifest.get("schema_version") != 1:
        errors.append("schema_version must be 1")
    if manifest.get("task_id") != "T-20260827-052":
        errors.append("task_id mismatch")
    platform = manifest.get("platform", {})
    if not isinstance(platform, dict):
        errors.append("platform must be an object")
        platform = {}
    for key, expected in {
        "board": "Microsoft Catapult v3 / Mg Catapult",
        "family": "Arria 10",
        "device": "10AX115N4F40E3SG",
        "quartus": "Quartus Prime Pro 21.4 Build 67",
    }.items():
        if platform.get(key) != expected:
            errors.append(f"platform.{key} mismatch")
    if platform.get("clocks_hz") != {
        "board_input": 100000000,
        "logic_domain": 25000000,
        "ddr_reference": 266666667,
    }:
        errors.append("clock contract mismatch")
    if platform.get("ddr4") != {
        "dq_bits": 72,
        "dqs_bits": 9,
        "emif_user_data_bits": 512,
        "emif_user_clock_hz": 266666750,
    }:
        errors.append("DDR4 contract mismatch")
    flash = platform.get("flash", {})
    console = platform.get("console", {})
    if not isinstance(flash, dict):
        flash = {}
    if not isinstance(console, dict):
        console = {}
    if flash.get("device") != "EPCQL1024":
        errors.append("EPCQ device mismatch")
    if flash.get("configuration") != "Active Serial x4":
        errors.append("EPCQ configuration mismatch")
    if console.get("kind") != "Altera Avalon JTAG-UART":
        errors.append("JTAG-UART contract mismatch")


def check_anchors(by_path: dict[str, dict[str, object]], errors: list[str]) -> None:
    qsf = read_text(ROOT / "quartus/catapult_a10.qsf")
    for pattern in (
        r'FAMILY\s+"Arria 10"', r"DEVICE\s+10AX115N4F40E3SG",
        r"ACTIVE_SERIAL_CLOCK\s+FREQ_100MHZ",
        r"TOP_LEVEL_ENTITY\s+lcvex_catapult_a10_top",
        r'SYSTEMVERILOG_FILE\s+"\.\./rtl/lcvex_catapult_a10_top\.sv"',
        r'SYSTEMVERILOG_FILE\s+"\.\./rtl/lcvex_catapult_a10_reset_gate\.sv"',
        r'QSYS_FILE\s+"\.\./qsys/ddr4_bot/Qsys\.qsys"',
        r'IP_FILE\s+"\.\./qsys/ddr4_bot/ip/Qsys/Qsys_emif_bot\.ip"',
        r'MIF_FILE\s+"\.\./boot/build/linux-loader/linux_loader\.mif"',
        r'QIP_FILE\s+"\.\./flash/sfl/sfl_sys\.qip"',
        r"jtag_uart_std\.v",
        r"jtag_uart_std_altera_avalon_jtag_uart_1910_zesttkq\.v",
    ):
        if not re.search(pattern, qsf):
            errors.append(f"QSF anchor missing {pattern}")
    synthesis_macro = "set_global_assignment -name VERILOG_MACRO SYNTHESIS"
    active_macros = [
        line.strip()
        for line in qsf.splitlines()
        if line.strip() and not line.lstrip().startswith("#")
        and "VERILOG_MACRO" in line
    ]
    if active_macros != [synthesis_macro]:
        errors.append(
            "QSF must contain exactly one active SYNTHESIS macro and no other "
            f"VERILOG_MACRO assignment (got {active_macros})"
        )
    for pattern in (r"\.\./\.\./(core|sw|software)",
                    r"\bC_ALIAS\b", r"\bSignalTap\b"):
        if re.search(pattern, qsf, re.IGNORECASE):
            errors.append(f"forbidden QSF text {pattern}")
    for pattern in (
        r'SYSTEMVERILOG_FILE\s+"\.\./\.\./rtl/lcvex_catapult_soc_top\.sv"',
        r'SYSTEMVERILOG_FILE\s+"\.\./\.\./rtl/lcvex_core\.sv"',
        r'SYSTEMVERILOG_FILE\s+"\.\./\.\./rtl/lcvex_l2_wb\.sv"',
    ):
        if not re.search(pattern, qsf):
            errors.append(f"B5 QSF anchor missing {pattern}")

    # Every RTL source the board SoC simulation filelist compiles must also be
    # part of the Quartus project, otherwise synthesis fails on an undefined
    # module that the simulation happily elaborates.  The simulation-only
    # BRAM boot shim is the single documented exception.
    sim_only = {"lcvex_bram_boot_shim.sv"}
    filelist = read_text(ROOT / "tb/filelist_soc.f")
    for entry in filelist.splitlines():
        line = entry.strip()
        if not line or line.startswith("#") or not line.startswith("rtl/"):
            continue
        name = Path(line).name
        if name in sim_only:
            continue
        if not re.search(rf'SYSTEMVERILOG_FILE\s+"\.\./\.\./rtl/{re.escape(name)}"', qsf):
            errors.append(f"QSF is missing board RTL {line}")
    if 'SYSTEMVERILOG_FILE "../../rtl/lcvex_gic.sv"' not in qsf:
        errors.append("QSF anchor missing the board GIC source")

    sdc = read_text(ROOT / "quartus/catapult_a10.sdc")
    for pattern in (r"create_clock -period 10\.000",
                    r"create_generated_clock -name sys_clk_25 .*divide_by 4",
                    r"get_pins \{sys_clk_25\|q\}",
                    r"create_clock -period 3\.750",
                    r"set_false_path -from \[get_registers -nowarn \{emif\|emif_bot\|\*\}\]",
                    r"cal_success_sync_q\[0\]"):
        if not re.search(pattern, sdc, re.DOTALL):
            errors.append(f"SDC anchor missing {pattern}")

    qsys = read_text(ROOT / "qsys/ddr4_bot/Qsys.qsys")
    emif = read_text(ROOT / "qsys/ddr4_bot/ip/Qsys/Qsys_emif_bot.ip")
    epcq = read_text(ROOT / "flash/sfl/ip/sfl_sys/epcq.ip")
    for pattern in (r"<ipxact:value>10AX115N4F40E3SG</ipxact:value>",
                    r"<ipxact:value>2</ipxact:value>", r"266666750",
                    r"datawidth='512'", r"(?:<|&lt;)width(?:>|&gt;)72"):
        if not re.search(pattern, qsys):
            errors.append(f"Qsys anchor missing {pattern}")
    for pattern in (r"SYS_INFO_DEVICE_SPEEDGRADE", r"<ipxact:value>3</ipxact:value>",
                    r"PHY_DDR4_USER_REF_CLK_FREQ_MHZ", r"MEM_DDR4_DQ_WIDTH"):
        if not re.search(pattern, emif):
            errors.append(f"EMIF anchor missing {pattern}")
    for pattern in (r"FLASH_TYPE", r"EPCQL1024", r"IO_MODE", r"QUAD",
                    r"10AX115N4F40E3SG"):
        if not re.search(pattern, epcq):
            errors.append(f"EPCQ anchor missing {pattern}")
    uart = ROOT / "jtag_uart/jtag_uart_std_altera_avalon_jtag_uart_1910_zesttkq.v"
    if "module jtag_uart_only_jtag_uart_altera_avalon_jtag_uart_1910_zesttkq" not in read_text(uart):
        errors.append("JTAG-UART implementation anchor missing")
    if "fifo_AF <= (7'h40 - {rfifo_full,rfifo_used}) <= 63;" not in read_text(uart):
        errors.append("JTAG-UART RX interrupt must wake the Linux TTY reader on the first byte")

    # B0/B2 vendor inputs must stay free of the sibling RISC-V platform
    # dependencies.  B5 之后 quartus/ 中的 QSF 会合法引用 LCVEX AXI4/Cache
    # 源文件，因此只扫描厂商输入目录，不再扫描可再生成 QSF。
    vendor_paths = [
        target_path for target_path in sorted(by_path)
        if target_path.startswith("qsys/") or target_path.startswith("flash/")
        or target_path.startswith("jtag_uart/")
    ]
    for target_path in vendor_paths:
        try:
            body = (ROOT / target_path).read_text(encoding="utf-8", errors="strict")
        except UnicodeDecodeError:
            continue
        for pattern in FORBIDDEN:
            if re.search(pattern, body, re.IGNORECASE):
                errors.append(f"forbidden payload dependency {pattern} in {target_path}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--strict-source",
        action="store_true",
        help="also verify the locked source blobs against a clean git worktree",
    )
    parser.add_argument(
        "--source-repo",
        help="source git worktree for --strict-source (defaults to manifest provenance)",
    )
    parser.add_argument(
        "--source-commit",
        help="full source commit for --strict-source (defaults to manifest provenance)",
    )
    args = parser.parse_args()

    errors: list[str] = []
    if not args.strict_source and (args.source_repo or args.source_commit):
        errors.append("--source-repo/--source-commit require --strict-source")

    manifest, by_path = parse_manifest(errors)
    if manifest:
        check_platform_contract(manifest, errors)
    check_payload_set(by_path, errors)
    check_sums(by_path, errors)
    locked = parse_lock(by_path, errors)

    # B0/B2 vendor anchors and dependency checks remain part of the offline
    # contract.  They are safe to run even when a malformed manifest yielded
    # no entries.
    if manifest:
        check_anchors(by_path, errors)

    strict_repo: Path | None = None
    strict_commit: str | None = None
    if args.strict_source and manifest:
        strict_repo, strict_commit = check_strict_source(
            manifest, by_path, locked, args.source_repo, args.source_commit, errors
        )

    if errors:
        print("PLATFORM_CHECK_FAIL")
        print("\n".join(f"- {item}" for item in errors))
        return 1

    if args.strict_source:
        print(
            f"PLATFORM_CHECK_PASS files={len(by_path)} strict_source=PASS "
            f"repo={strict_repo} commit={strict_commit}"
        )
    else:
        print(f"PLATFORM_CHECK_PASS files={len(by_path)} strict_source=OFF")
    return 0


if __name__ == "__main__":
    sys.exit(main())
