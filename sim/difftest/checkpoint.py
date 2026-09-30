#!/usr/bin/env python3
"""LCVEX 差分 checkpoint 链校验与 QEMU 恢复辅助工具。

当前工具负责 checkpoint 链的 QEMU L1 校验（RAM/设备/架构/系统/定时器/GIC
sidecar）、输入环境 SHA256 manifest 和读取；Verilator DUT 的恢复入口由
协调器执行，不能只凭单个 sidecar 宣称 QEMU 与 DUT 已完成联合恢复。
"""

from __future__ import annotations

import argparse
import hashlib
import gzip
import json
import os
import shlex
import socket
import struct
import subprocess
import tempfile
import time
from dataclasses import dataclass
from pathlib import Path

MAGIC = b"LCVXCKP1"
VERSION = 1
# 56-byte header: the final two u64 are reserved for future page count/CRC.
HEADER = struct.Struct("<8sIIQQQQQ")
ARCH_HEADER = struct.Struct("<8sI4xQ")
ARCH_STATE = struct.Struct("<QQI31QQI")
SYS_STATE = struct.Struct("<8sII31Q25QIBB6x")
SYS_STATE_V2 = struct.Struct("<8sII31Q25QIBB6x3Q")
# v3：补齐已实现的 PMUSERENR_EL0、TCR2_EL1 与 exclusive monitor。
# exclusive_addr=0xffffffffffffffff 表示 monitor 无效。
SYS_STATE_V3 = struct.Struct("<8sII31Q25QIBB6x8Q")
# v4：新增 CONTEXTIDR_EL1 字段。
SYS_STATE_V4 = struct.Struct("<8sII31Q25QIBB6x9Q")
# LCVXFP01: magic/version/size/feature/vector/seq/fpcr/fpsr + 32x128-bit V.
FP_STATE = struct.Struct("<8sIIIIQII" + "QQ" * 32)
FP_MAGIC = b"LCVXFP01"
FP_VERSION = 1
FP_FEATURE_NEON = 1
FP_VECTOR_BYTES = 16
MMIO_STATE = struct.Struct("<8sII5IB7xQ")
PAGE = 4096
MANIFEST_META = "manifest.json"
MANIFEST_FORMAT = "LCVX-checkpoint-manifest-v2"
MANIFEST_STATUS_KEYS = ("status", "state", "lifecycle", "finalized",
                        "complete")
PUBLISHED_STATUS = {
    "status": "complete",
    "state": "complete",
    "lifecycle": "finalized",
    "finalized": True,
    "complete": True,
}


@dataclass(frozen=True)
class Entry:
    kind: str
    seq: int
    parent: int
    ram_bytes: int
    pages: int
    ram_path: Path
    dev_path: Path
    arch_path: Path | None = None
    sys_path: Path | None = None
    timer_path: Path | None = None
    gic_path: Path | None = None
    mmio_path: Path | None = None
    fp_path: Path | None = None


def _sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as f:
        while True:
            block = f.read(1 << 20)
            if not block:
                break
            digest.update(block)
    return digest.hexdigest()


def _file_record(path: Path) -> dict[str, object]:
    path = path.resolve()
    return {"path": str(path), "size": path.stat().st_size,
            "sha256": _sha256_file(path)}


def _write_json_atomic(path: Path, value: dict[str, object]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile("w", encoding="utf-8", dir=path.parent,
                                    prefix=f".{path.name}.",
                                    delete=False) as f:
        tmp = Path(f.name)
        json.dump(value, f, ensure_ascii=False, indent=2, sort_keys=True)
        f.write("\n")
    os.replace(tmp, path)


def _resolve_entry_path(chain: Path, value: str) -> Path:
    path = Path(value)
    return path if path.is_absolute() else chain / path


def _validate_file_record(record: dict[str, object], what: str) -> None:
    try:
        path = Path(str(record["path"]))
        expected_size = int(record["size"])
        expected_hash = str(record["sha256"])
    except (KeyError, TypeError, ValueError) as exc:
        raise ValueError(f"{what}: 文件摘要字段无效") from exc
    if not path.is_file():
        raise FileNotFoundError(f"{what}: 文件缺失：{path}")
    actual_size = path.stat().st_size
    if actual_size != expected_size:
        raise ValueError(f"{what}: 文件大小改变：{path} "
                         f"{actual_size} != {expected_size}")
    actual_hash = _sha256_file(path)
    if actual_hash != expected_hash:
        raise ValueError(f"{what}: SHA256 不匹配：{path} "
                         f"{actual_hash} != {expected_hash}")


def _read_fp_sidecar(path: Path, expected_seq: int | None = None) -> dict[str, object]:
    """Read exactly one gzip-compressed LCVXFP01 sidecar."""

    try:
        with gzip.open(path, "rb") as stream:
            raw = stream.read(FP_STATE.size)
            if len(raw) != FP_STATE.size or stream.read(1):
                raise ValueError(f"{path}: LCVXFP01 长度错误")
    except (OSError, EOFError, gzip.BadGzipFile) as exc:
        raise ValueError(f"{path}: LCVXFP01 gzip 无法读取") from exc
    values = FP_STATE.unpack(raw)
    magic, version, size, feature_bits, vector_bytes, seq, fpcr, fpsr = values[:8]
    if (magic != FP_MAGIC or version != FP_VERSION or size != FP_STATE.size or
            feature_bits != FP_FEATURE_NEON or vector_bytes != FP_VECTOR_BYTES):
        raise ValueError(f"{path}: LCVXFP01 header 不匹配")
    if expected_seq is not None and seq != expected_seq:
        raise ValueError(f"{path}: header seq={seq} != TSV seq={expected_seq}")
    return {
        "seq": seq,
        "feature_bits": feature_bits,
        "vector_bytes": vector_bytes,
        "fpcr": fpcr,
        "fpsr": fpsr,
        "v": [(values[i], values[i + 1]) for i in range(8, 72, 2)],
        "path": str(path),
    }


def _validate_fp_sidecar(path: Path, expected_seq: int) -> None:
    _read_fp_sidecar(path, expected_seq)


def _read_manifest_meta(chain: Path) -> dict[str, object] | None:
    path = chain / MANIFEST_META
    if not path.is_file():
        return None
    try:
        with path.open(encoding="utf-8") as f:
            meta = json.load(f)
    except (OSError, json.JSONDecodeError) as exc:
        raise ValueError(f"{path}: JSON manifest 无法读取") from exc
    if not isinstance(meta, dict) or meta.get("format") != MANIFEST_FORMAT:
        raise ValueError(f"{path}: manifest format 不匹配")
    return meta


def _manifest_has_lifecycle(meta: dict[str, object]) -> bool:
    """Return whether *meta* uses the new pending/finalized lifecycle.

    Manifests written before the lifecycle change intentionally have none of
    these keys.  They remain readable when their old integrity fields are
    complete, but they are never accepted as a provenance parent below.
    """

    return any(key in meta for key in MANIFEST_STATUS_KEYS)


def _manifest_is_published(meta: dict[str, object]) -> bool:
    if not _manifest_has_lifecycle(meta):
        # Legacy v2 manifests do not carry status.  The required TSV/artifact
        # hashes below are their publication marker.
        return (isinstance(meta.get("manifest_tsv_sha256"), str) and
                isinstance(meta.get("chain"), dict) and
                isinstance(meta.get("artifacts"), list))
    return all(meta.get(key) == value
               for key, value in PUBLISHED_STATUS.items())


def _require_published(chain: Path, meta: dict[str, object]) -> None:
    if not _manifest_is_published(meta):
        status = ", ".join(
            f"{key}={meta.get(key)!r}" for key in MANIFEST_STATUS_KEYS
            if key in meta
        ) or "legacy incomplete"
        raise ValueError(f"{chain / MANIFEST_META}: manifest 未发布（{status}）")


def _global_offset(meta: dict[str, object]) -> int:
    provenance = meta.get("provenance")
    if not isinstance(provenance, dict):
        raise ValueError("parent manifest 缺少 provenance，不能推导 global seq")
    kind = provenance.get("kind")
    if kind == "root":
        if provenance.get("global_seq_offset", 0) != 0:
            raise ValueError("root provenance 的 global_seq_offset 必须为 0")
        return 0
    if kind != "resume":
        raise ValueError(f"未知 provenance kind：{kind!r}")
    context = meta.get("context")
    if not isinstance(context, dict):
        raise ValueError("resume manifest 缺少 context")
    try:
        return int(context["global_seq_offset"])
    except (KeyError, TypeError, ValueError) as exc:
        raise ValueError("resume manifest 缺少有效 global_seq_offset") from exc


def _selected_row(rows: list[Entry], seq: int) -> Entry:
    selected = [row for row in rows if row.seq <= seq]
    if not selected or selected[-1].seq != seq:
        raise ValueError(f"链中找不到 seq={seq}")
    return selected[-1]


def _record_by_role(meta: dict[str, object]) -> dict[str, dict[str, object]]:
    inputs = meta.get("inputs", [])
    if not isinstance(inputs, list):
        return {}
    result: dict[str, dict[str, object]] = {}
    for record in inputs:
        if isinstance(record, dict) and isinstance(record.get("role"), str):
            result[str(record["role"])] = record
    qemu = meta.get("qemu")
    if isinstance(qemu, dict):
        result.setdefault("qemu", qemu)
        version = qemu.get("version_file")
        if isinstance(version, dict):
            result.setdefault("qemu_version", version)
    return result


def _validate_parent_binding(chain: Path, meta: dict[str, object],
                             parent_meta: dict[str, object]) -> None:
    """Check child inputs/context against the immutable parent summary."""

    parent_records = _record_by_role(parent_meta)
    child_records = _record_by_role(meta)
    # A child may add plugin binding when an old root did not record it, but
    # every role that the parent did record must be carried unchanged.
    for role, expected in parent_records.items():
        actual = child_records.get(role)
        if actual is None:
            raise ValueError(f"{chain / MANIFEST_META}: child 缺少 parent 输入 {role}")
        if actual.get("sha256") != expected.get("sha256") or \
                actual.get("size") != expected.get("size"):
            raise ValueError(f"{chain / MANIFEST_META}: 输入 {role} 与 parent 摘要不匹配")

    parent_context = parent_meta.get("context")
    child_context = meta.get("context")
    if not isinstance(parent_context, dict) or not isinstance(child_context, dict):
        return
    # Window length and checkpoint cadence are intentionally per-child.  The
    # remaining boot/machine knobs must stay byte-for-byte equivalent whenever
    # the parent recorded them.
    ignored = {
        "manifest_lifecycle", "provenance_kind",
        "max_insns", "ckpt_every", "parent_chain", "parent_seq",
        "parent_local_seq", "parent_manifest_sha256",
        "global_seq_offset", "local_window_start", "local_window_end",
        "artifact_local_first", "artifact_local_last",
        "artifact_global_first", "artifact_global_last",
        "artifact_range_semantics", "local_window_end_semantics",
    }
    for key, expected in parent_context.items():
        if key in ignored or key not in child_context:
            continue
        if child_context[key] != expected:
            raise ValueError(f"{chain / MANIFEST_META}: context[{key}] 与 parent 不匹配")


def _validate_provenance(chain: Path, meta: dict[str, object],
                         rows: list[Entry], seen: set[Path]) -> None:
    provenance = meta.get("provenance")
    if provenance is None:
        # Old v2 metadata can still be read.  init_resume_manifest refuses it
        # as a parent, so no global range can be fabricated from it.
        return
    if not isinstance(provenance, dict):
        raise ValueError(f"{chain / MANIFEST_META}: provenance 字段无效")
    kind = provenance.get("kind")
    if kind == "root":
        if provenance.get("global_seq_offset", 0) != 0:
            raise ValueError(f"{chain / MANIFEST_META}: root global offset 非 0")
        return
    if kind != "resume":
        raise ValueError(f"{chain / MANIFEST_META}: 未知 provenance kind={kind!r}")

    context = meta.get("context")
    if not isinstance(context, dict):
        raise ValueError(f"{chain / MANIFEST_META}: resume context 缺失")
    parent_value = provenance.get("parent_chain")
    parent_hash = provenance.get("parent_manifest_sha256")
    try:
        parent_local_seq = int(provenance.get("parent_local_seq",
                                               provenance["parent_seq"]))
        parent_global_seq = int(provenance["parent_seq"])
        global_offset = int(context["global_seq_offset"])
    except (KeyError, TypeError, ValueError) as exc:
        raise ValueError(f"{chain / MANIFEST_META}: provenance 序号字段无效") from exc
    if not isinstance(parent_value, str) or not isinstance(parent_hash, str):
        raise ValueError(f"{chain / MANIFEST_META}: parent provenance 字段缺失")
    parent_chain = Path(parent_value).resolve()
    if parent_chain in seen or parent_chain == chain.resolve():
        raise ValueError(f"{chain / MANIFEST_META}: parent provenance 出现环")
    parent_meta_path = parent_chain / MANIFEST_META
    if not parent_meta_path.is_file():
        raise ValueError(f"{chain / MANIFEST_META}: parent 缺少 manifest.json")
    actual_parent_hash = _sha256_file(parent_meta_path)
    if actual_parent_hash != parent_hash:
        raise ValueError(f"{chain / MANIFEST_META}: parent manifest SHA256 不匹配")
    parent_rows = _read_manifest_checked(parent_chain, seen | {chain.resolve()})
    parent_meta = _read_manifest_meta(parent_chain)
    if parent_meta is None:
        raise ValueError(f"{chain / MANIFEST_META}: parent 无 manifest provenance")
    parent_row = _selected_row(parent_rows, parent_local_seq)
    parent_offset = _global_offset(parent_meta)
    expected_global = parent_offset + parent_row.seq
    if parent_global_seq != expected_global:
        raise ValueError(f"{chain / MANIFEST_META}: parent global seq 不匹配")
    if global_offset != parent_global_seq + 1:
        raise ValueError(f"{chain / MANIFEST_META}: global_seq_offset 不匹配")
    if context.get("parent_chain") != str(parent_chain) or \
            context.get("parent_manifest_sha256") != parent_hash:
        raise ValueError(f"{chain / MANIFEST_META}: context parent 摘要不匹配")
    if int(context.get("parent_seq", parent_global_seq)) != parent_global_seq:
        raise ValueError(f"{chain / MANIFEST_META}: context parent_seq 不匹配")
    if int(context.get("parent_local_seq", parent_local_seq)) != parent_local_seq:
        raise ValueError(f"{chain / MANIFEST_META}: context parent_local_seq 不匹配")
    _validate_parent_binding(chain, meta, parent_meta)

    # A local checkpoint row is still an inclusive committed sequence.  The
    # context records the exact closed artifact range after finalization.
    try:
        local_first = int(context["artifact_local_first"])
        local_last = int(context["artifact_local_last"])
        global_first = int(context["artifact_global_first"])
        global_last = int(context["artifact_global_last"])
    except (KeyError, TypeError, ValueError) as exc:
        raise ValueError(f"{chain / MANIFEST_META}: artifact global/local 范围缺失") from exc
    if rows[0].seq != local_first or rows[-1].seq != local_last:
        raise ValueError(f"{chain / MANIFEST_META}: artifact local 范围与 TSV 不匹配")
    if (global_first, global_last) != (global_offset + local_first,
                                       global_offset + local_last):
        raise ValueError(f"{chain / MANIFEST_META}: artifact global 范围不匹配")


def _validate_manifest_meta(chain: Path, rows: list[Entry],
                            meta: dict[str, object] | None = None,
                            seen: set[Path] | None = None) -> None:
    if meta is None:
        meta = _read_manifest_meta(chain)
    if meta is None:
        # 兼容早期没有输入环境摘要的 7/8/9/10/11 列链；这些链可读取，
        # 但由于没有 manifest provenance，不能用于伪造新的 global 映射。
        return
    _require_published(chain, meta)
    if meta.get("page_size") != PAGE:
        raise ValueError(f"{chain / MANIFEST_META}: page_size 不匹配")
    inputs = meta.get("inputs", [])
    if not isinstance(inputs, list) or not inputs:
        raise ValueError(f"{chain / MANIFEST_META}: inputs 为空")
    for index, record in enumerate(inputs):
        if not isinstance(record, dict):
            raise ValueError(f"{chain / MANIFEST_META}: inputs[{index}] 无效")
        _validate_file_record(record, f"输入[{record.get('role', index)}]")
    qemu = meta.get("qemu")
    if not isinstance(qemu, dict):
        raise ValueError(f"{chain / MANIFEST_META}: qemu 摘要缺失")
    _validate_file_record(qemu, "QEMU 二进制")
    qemu_version = qemu.get("version_file")
    if not isinstance(qemu_version, dict):
        raise ValueError(f"{chain / MANIFEST_META}: QEMU VERSION 摘要缺失")
    _validate_file_record(qemu_version, "QEMU VERSION")

    strict_lifecycle = _manifest_has_lifecycle(meta)
    manifest = chain / "manifest.tsv"
    manifest_hash = meta.get("manifest_tsv_sha256")
    if strict_lifecycle and not isinstance(manifest_hash, str):
        raise ValueError(f"{chain / MANIFEST_META}: manifest TSV SHA256 缺失")
    if isinstance(manifest_hash, str):
        if not manifest.is_file() or _sha256_file(manifest) != manifest_hash:
            raise ValueError(f"{manifest}: manifest TSV SHA256 不匹配")
    artifacts = meta.get("artifacts", [])
    if not isinstance(artifacts, list) or (strict_lifecycle and not artifacts):
        raise ValueError(f"{chain / MANIFEST_META}: artifacts 缺失或为空")
    artifact_paths: set[str] = set()
    for index, record in enumerate(artifacts):
        if not isinstance(record, dict):
            raise ValueError(f"{chain / MANIFEST_META}: artifacts[{index}] 无效")
        _validate_file_record(record, f"checkpoint artifact[{index}]")
        artifact_paths.add(str(Path(str(record.get("path"))).resolve()))
    expected_paths = {
        str(path.resolve())
        for row in rows
        for path in (row.ram_path, row.dev_path, row.arch_path,
                     row.sys_path, row.timer_path, row.gic_path,
                     row.mmio_path, row.fp_path)
        if path is not None
    }
    if strict_lifecycle and not expected_paths.issubset(artifact_paths):
        missing = sorted(expected_paths - artifact_paths)
        raise ValueError(f"{chain / MANIFEST_META}: artifacts 记录缺失：{missing[0]}")
    chain_info = meta.get("chain")
    if strict_lifecycle and not isinstance(chain_info, dict):
        raise ValueError(f"{chain / MANIFEST_META}: chain 摘要缺失")
    if isinstance(chain_info, dict):
        try:
            entries = int(chain_info["entries"])
            first_seq = int(chain_info["first_seq"])
            last_seq = int(chain_info["last_seq"])
        except (KeyError, TypeError, ValueError) as exc:
            raise ValueError(f"{chain / MANIFEST_META}: chain 摘要无效") from exc
        if entries != len(rows) or first_seq != rows[0].seq or last_seq != rows[-1].seq:
            raise ValueError(f"{chain / MANIFEST_META}: chain 摘要与 TSV 不匹配")
    context = meta.get("context", {})
    p7_state = context.get("p7_state") if isinstance(context, dict) else None
    has_fp = any(row.fp_path is not None for row in rows)
    if p7_state == "LCVXFP01":
        if context.get("p7_cpu_profile") != "a76-v1" or \
                context.get("p7_vector_bytes") not in ("16", 16):
            raise ValueError(f"{chain / MANIFEST_META}: P7 context/profile 无效")
        for row in rows:
            if row.fp_path is None:
                raise ValueError(f"seq={row.seq}: P7 checkpoint 缺少 fp sidecar")
            _validate_fp_sidecar(row.fp_path, row.seq)
    elif has_fp:
        raise ValueError(
            f"{chain / MANIFEST_META}: 13 列 fp sidecar 必须声明 p7_state=LCVXFP01"
        )
    _validate_provenance(chain, meta, rows, seen or {chain.resolve()})


def _read_manifest_rows(chain: Path) -> list[Entry]:
    rows = []
    manifest = chain / "manifest.tsv"
    with manifest.open(encoding="utf-8") as f:
        for lineno, line in enumerate(f, 1):
            if not line.strip():
                continue
            fields = line.rstrip("\n").split("\t")
            # 7 列是旧格式；后续依次增加 arch、sys、timer、GIC、C++ MMIO、FP。
            if len(fields) not in (7, 8, 9, 10, 11, 12, 13):
                raise ValueError(f"manifest 第 {lineno} 行字段数错误")
            kind, seq, parent, ram_bytes, pages, ram, dev = fields[:7]
            arch = Path(fields[7]) if len(fields) == 8 and fields[7] else None
            if len(fields) >= 9:
                arch = Path(fields[7]) if fields[7] else None
                sys = Path(fields[8]) if fields[8] else None
            else:
                sys = None
            timer = Path(fields[9]) if len(fields) >= 10 and fields[9] else None
            gic = Path(fields[10]) if len(fields) >= 11 and fields[10] else None
            mmio = Path(fields[11]) if len(fields) >= 12 and fields[11] else None
            fp = Path(fields[12]) if len(fields) >= 13 and fields[12] else None
            rows.append(Entry(kind, int(seq), int(parent), int(ram_bytes),
                              int(pages), _resolve_entry_path(chain, ram),
                              _resolve_entry_path(chain, dev),
                              _resolve_entry_path(chain, fields[7])
                              if arch is not None else None,
                              _resolve_entry_path(chain, fields[8])
                              if sys is not None else None,
                              _resolve_entry_path(chain, fields[9])
                              if timer is not None else None,
                              _resolve_entry_path(chain, fields[10])
                              if gic is not None else None,
                              _resolve_entry_path(chain, fields[11])
                              if mmio is not None else None,
                              _resolve_entry_path(chain, fields[12])
                              if fp is not None else None))
    rows.sort(key=lambda e: e.seq)
    if not rows or rows[0].kind != "base":
        raise ValueError("checkpoint 链缺少 base")
    expected = rows[0].seq
    for i, row in enumerate(rows):
        if i == 0:
            if row.parent != (1 << 64) - 1:
                raise ValueError("base parent 必须为 UINT64_MAX")
        elif row.parent != expected:
            raise ValueError(f"seq={row.seq} parent={row.parent} != {expected}")
        expected = row.seq
        if row.ram_bytes == 0 or row.ram_bytes % PAGE:
            raise ValueError(f"seq={row.seq} RAM 大小不是 4 KiB 整数倍")
        if not row.ram_path.is_file() or not row.dev_path.is_file():
            raise FileNotFoundError(f"seq={row.seq} checkpoint 文件缺失")
        if row.arch_path is not None and not row.arch_path.is_file():
            raise FileNotFoundError(f"seq={row.seq} 架构摘要缺失")
        if row.sys_path is not None and not row.sys_path.is_file():
            raise FileNotFoundError(f"seq={row.seq} 系统状态摘要缺失")
        if row.timer_path is not None and not row.timer_path.is_file():
            raise FileNotFoundError(f"seq={row.seq} 定时器状态摘要缺失")
        if row.gic_path is not None and not row.gic_path.is_file():
            raise FileNotFoundError(f"seq={row.seq} GIC 状态摘要缺失")
        if row.mmio_path is not None and not row.mmio_path.is_file():
            raise FileNotFoundError(f"seq={row.seq} C++ MMIO 状态摘要缺失")
        if row.fp_path is not None and not row.fp_path.is_file():
            raise FileNotFoundError(f"seq={row.seq} FP 状态摘要缺失")
    if any(row.fp_path is not None for row in rows) and \
            _read_manifest_meta(chain) is None:
        raise ValueError("13 列 FP checkpoint 必须有 finalized manifest.json")
    return rows


def _read_manifest_checked(chain: Path, seen: set[Path]) -> list[Entry]:
    meta = _read_manifest_meta(chain)
    if meta is not None:
        _require_published(chain, meta)
    rows = _read_manifest_rows(chain)
    _validate_manifest_meta(chain, rows, meta, seen)
    return rows


def read_manifest(chain: Path) -> list[Entry]:
    """读取已发布链；pending/incomplete manifest 永不作为恢复输入。"""

    return _read_manifest_checked(chain.resolve(), set())


def _input_record(role: str, path: Path) -> dict[str, object]:
    if not path.is_file():
        raise FileNotFoundError(f"{role}: 文件缺失：{path}")
    record = _file_record(path)
    record["role"] = role
    return record


def init_manifest(chain: Path, qemu: Path, qemu_version: Path,
                  inputs: list[tuple[str, Path]],
                  context: dict[str, str]) -> dict[str, object]:
    if not inputs:
        raise ValueError("至少需要一个 Image/DTB 输入")
    if (chain / MANIFEST_META).exists() or (chain / "manifest.tsv").exists():
        raise FileExistsError(f"checkpoint 链目录非空：{chain}")
    if not qemu.is_file():
        raise FileNotFoundError(f"QEMU 二进制缺失：{qemu}")
    if not qemu_version.is_file():
        raise FileNotFoundError(f"QEMU VERSION 缺失：{qemu_version}")
    chain.mkdir(parents=True, exist_ok=True)
    qemu_record = _file_record(qemu)
    qemu_record["version_file"] = _file_record(qemu_version)
    meta: dict[str, object] = {
        "format": MANIFEST_FORMAT,
        "hash": "sha256",
        "page_size": PAGE,
        "inputs": [_input_record(role, path) for role, path in inputs],
        "qemu": qemu_record,
        "context": dict(sorted(context.items())),
        "artifacts": [],
    }
    # resume runner 通过这些 context 键请求严格的 pending→complete 生命周期。
    # 旧 run_lockstep_step 调用不带 provenance，继续保持历史 manifest 兼容。
    if context.get("manifest_lifecycle") == "strict":
        meta.update({"status": "pending", "state": "pending",
                     "lifecycle": "staging", "finalized": False,
                     "complete": False})
    provenance_kind = context.get("provenance_kind")
    if provenance_kind == "root":
        meta["provenance"] = {"kind": "root", "global_seq_offset": 0}
    elif provenance_kind == "resume":
        required = ("parent_chain", "parent_manifest_sha256", "parent_seq",
                    "parent_local_seq")
        if any(key not in context for key in required):
            raise ValueError("resume manifest 缺少 parent provenance context")
        meta["provenance"] = {
            "kind": "resume",
            "parent_chain": context["parent_chain"],
            "parent_manifest_sha256": context["parent_manifest_sha256"],
            "parent_seq": int(context["parent_seq"]),
            "parent_local_seq": int(context["parent_local_seq"]),
        }
    _write_json_atomic(chain / MANIFEST_META, meta)
    return {"format": MANIFEST_FORMAT, "chain": str(chain.resolve()),
            "inputs": len(inputs), "qemu_sha256": qemu_record["sha256"]}


def finalize_manifest(chain: Path) -> dict[str, object]:
    rows = _read_manifest_rows(chain)
    meta = _read_manifest_meta(chain)
    if meta is None:
        raise FileNotFoundError(f"{chain / MANIFEST_META}: 请先 init-manifest")
    paths: dict[str, Path] = {}
    for row in rows:
        for path in (row.ram_path, row.dev_path, row.arch_path,
                     row.sys_path, row.timer_path, row.gic_path, row.mmio_path,
                     row.fp_path):
            if path is not None:
                paths[str(path.resolve())] = path
    artifacts = [_file_record(path) for path in sorted(paths.values(),
                                                       key=lambda p: str(p))]
    # Build the complete state separately.  Provenance validation may walk the
    # parent chain and reject this candidate (for example, a plugin hash that
    # differs from the strict parent); such a failure must leave the on-disk
    # pending manifest untouched.
    candidate = dict(meta)
    candidate["artifacts"] = artifacts
    manifest = chain / "manifest.tsv"
    if not manifest.is_file():
        raise FileNotFoundError(f"{manifest}: checkpoint 链缺失")
    candidate["manifest_tsv_sha256"] = _sha256_file(manifest)
    candidate["chain"] = {"entries": len(rows), "first_seq": rows[0].seq,
                           "last_seq": rows[-1].seq}
    if _manifest_has_lifecycle(candidate):
        context_value = candidate.get("context")
        if isinstance(context_value, dict):
            context = dict(context_value)
            candidate["context"] = context
        else:
            context = candidate.setdefault("context", {})
        if isinstance(context, dict) and "global_seq_offset" in context:
            context.setdefault("artifact_local_first", rows[0].seq)
            context.setdefault("artifact_local_last", rows[-1].seq)
            offset = int(context["global_seq_offset"])
            context.setdefault("artifact_global_first", offset + rows[0].seq)
            context.setdefault("artifact_global_last", offset + rows[-1].seq)
            context.setdefault("artifact_range_semantics", "inclusive")
        candidate.update(PUBLISHED_STATUS)
    # Validate the exact candidate before publication.  This is the same full
    # metadata/provenance checker used by read_manifest, but the current file
    # remains pending while parent/input/artifact checks run.
    _validate_manifest_meta(chain, rows, candidate)
    _write_json_atomic(chain / MANIFEST_META, candidate)
    return {"format": MANIFEST_FORMAT, "entries": len(rows),
            "last_seq": rows[-1].seq, "artifacts": len(artifacts),
            "manifest": str((chain / MANIFEST_META).resolve())}


def verify_runtime_inputs(chain: Path, qemu: Path, qemu_version: Path,
                          inputs: list[tuple[str, Path]],
                          context: dict[str, str] | None = None) -> dict[str, object]:
    """校验 resume 当前实际输入与 parent manifest 的摘要/上下文。"""
    rows = read_manifest(chain)
    meta = _read_manifest_meta(chain)
    if meta is None:
        raise ValueError(f"{chain / MANIFEST_META}: 缺少输入 manifest，不能安全续跑")
    expected = _record_by_role(meta)
    actual_records: dict[str, dict[str, object]] = {
        "qemu": _file_record(qemu),
        "qemu_version": _file_record(qemu_version),
    }
    for role, path in inputs:
        actual_records[role] = _file_record(path)
    for role, actual in actual_records.items():
        record = expected.get(role)
        if record is None:
            raise ValueError(f"{chain / MANIFEST_META}: parent 缺少输入 role={role}")
        if actual.get("size") != record.get("size") or \
                actual.get("sha256") != record.get("sha256"):
            raise ValueError(f"{chain / MANIFEST_META}: 当前输入与 parent 不匹配：{role}")
    if context is not None:
        expected_context = meta.get("context", {})
        if isinstance(expected_context, dict):
            for key, value in context.items():
                if key in expected_context and str(expected_context[key]) != str(value):
                    raise ValueError(f"{chain / MANIFEST_META}: context 不匹配：{key}")
    return {"chain": str(chain.resolve()), "entries": len(rows),
            "last_seq": rows[-1].seq, "inputs": sorted(actual_records)}


def read_ram_records(path: Path, expect: Entry, ram: bytearray) -> int:
    count = 0
    with gzip.open(path, "rb") as f:
        header = f.read(HEADER.size)
        if len(header) != HEADER.size:
            raise ValueError(f"{path}: header 不完整")
        (magic, version, page_size, seq, parent, ram_bytes,
         _reserved0, _reserved1) = HEADER.unpack(header)
        if magic != MAGIC or version != VERSION or page_size != PAGE:
            raise ValueError(f"{path}: magic/version/page_size 不匹配")
        if (seq, parent, ram_bytes) != (expect.seq, expect.parent,
                                         expect.ram_bytes):
            raise ValueError(f"{path}: header 与 manifest 不匹配")
        while True:
            raw_page = f.read(8)
            if not raw_page:
                break
            if len(raw_page) != 8:
                raise ValueError(f"{path}: page 记录截断")
            page = struct.unpack("<Q", raw_page)[0]
            data = f.read(PAGE)
            if len(data) != PAGE or page * PAGE + PAGE > len(ram):
                raise ValueError(f"{path}: page 越界或数据截断: {page}")
            off = page * PAGE
            ram[off:off + PAGE] = data
            count += 1
    if count != expect.pages:
        raise ValueError(f"{path}: pages={count}，manifest={expect.pages}")
    return count


def restore_ram(chain: Path, seq: int, output: Path) -> dict[str, int | str]:
    rows = read_manifest(chain)
    selected = [r for r in rows if r.seq <= seq]
    if not selected or selected[-1].seq != seq:
        raise ValueError(f"链中找不到 seq={seq}")
    ram = bytearray(selected[0].ram_bytes)
    pages = 0
    for row in selected:
        pages += read_ram_records(row.ram_path, row, ram)
    output.parent.mkdir(parents=True, exist_ok=True)
    tmp = output.with_name(output.name + ".tmp")
    with tmp.open("wb") as f:
        f.write(ram)
    os.replace(tmp, output)
    return {"seq": seq, "ram_bytes": len(ram), "pages_applied": pages,
            "output": str(output)}


def read_arch_state(chain: Path, seq: int) -> dict[str, object]:
    rows = read_manifest(chain)
    selected = [r for r in rows if r.seq <= seq]
    if not selected or selected[-1].seq != seq:
        raise ValueError(f"链中找不到 seq={seq}")
    path = selected[-1].arch_path
    if path is None:
        raise ValueError(f"seq={seq} 没有架构摘要（旧格式链）")
    with gzip.open(path, "rb") as f:
        header = f.read(ARCH_HEADER.size)
        if len(header) != ARCH_HEADER.size:
            raise ValueError(f"{path}: 架构摘要 header 不完整")
        magic, version, header_seq = ARCH_HEADER.unpack(header)
        if magic != b"LCVXARC1" or version != VERSION or header_seq != seq:
            raise ValueError(f"{path}: 架构摘要 header 不匹配")
        raw = f.read(ARCH_STATE.size)
        if len(raw) != ARCH_STATE.size:
            raise ValueError(f"{path}: 架构摘要数据不完整")
        tail = f.read(1)
        if tail:
            raise ValueError(f"{path}: 架构摘要包含多余数据")
    values = ARCH_STATE.unpack(raw)
    return {"seq": seq, "pc": values[0], "next_pc": values[1],
            "insn": values[2], "x": list(values[3:34]),
            "sp": values[34], "nzcv": values[35], "path": str(path)}


def read_sys_state(chain: Path, seq: int) -> dict[str, object]:
    rows = read_manifest(chain)
    selected = [r for r in rows if r.seq <= seq]
    if not selected or selected[-1].seq != seq:
        raise ValueError(f"链中找不到 seq={seq}")
    path = selected[-1].sys_path
    if path is None:
        raise ValueError(f"seq={seq} 没有系统状态摘要")
    with gzip.open(path, "rb") as f:
        raw = f.read(SYS_STATE_V4.size)
        if f.read(1):
            raise ValueError(f"{path}: 系统状态摘要长度错误")
    if len(raw) == SYS_STATE_V4.size:
        values = SYS_STATE_V4.unpack(raw)
        version = 4
    elif len(raw) == SYS_STATE_V3.size:
        values = SYS_STATE_V3.unpack(raw)
        version = 3
    elif len(raw) == SYS_STATE_V2.size:
        values = SYS_STATE_V2.unpack(raw)
        version = 2
    else:
        raw = raw[:SYS_STATE.size]
        if len(raw) != SYS_STATE.size:
            raise ValueError(f"{path}: 系统状态摘要长度错误")
        values = SYS_STATE.unpack(raw)
        version = 1
    if (values[0], values[1], values[2]) not in (
            (b"LCVXSYS1", 1, SYS_STATE.size),
            (b"LCVXSYS2", 2, SYS_STATE_V2.size),
            (b"LCVXSYS3", 3, SYS_STATE_V3.size),
            (b"LCVXSYS4", 4, SYS_STATE_V4.size)):
        raise ValueError(f"{path}: 系统状态 header 不匹配")
    # 31 GPR 后的 25 个 QWORD 与 QEMU sidecar 定义顺序一致。
    x = values[3:34]
    q = values[34:59]
    return {"seq": seq, "x": list(x), "pc": q[0], "next_pc": q[1],
            "sp_el0": q[2], "sp_el1": q[3], "pstate": q[4],
            "daif": q[5], "elr_el1": q[6], "spsr_el1": q[7],
            "vbar_el1": q[8], "sctlr_el1": q[9], "tcr_el1": q[10],
            "ttbr0_el1": q[11], "ttbr1_el1": q[12], "mair_el1": q[13],
            "esr_el1": q[14], "far_el1": q[15], "par_el1": q[16],
            "cpacr_el1": q[17], "mdscr_el1": q[18], "cntkctl_el1": q[19],
            "tpidr_el0": q[20], "tpidrro_el0": q[21], "tpidr_el1": q[22],
            "pir_el1": q[23], "pire0_el1": q[24], "nzcv": values[59],
            "el": values[60], "sp_sel": values[61], "path": str(path),
            "zcr_el1": values[62] if version >= 2 else 0,
            "smcr_el1": values[63] if version >= 2 else 0,
            "csselr_el1": values[64] if version >= 2 else 0,
            "pmuserenr_el0": values[65] if version >= 3 else 0,
            "tcr2_el1": values[66] if version >= 3 else 0,
            "exclusive_addr": values[67] if version >= 3 else (1 << 64) - 1,
            "exclusive_val": values[68] if version >= 3 else 0,
            "exclusive_high": values[69] if version >= 3 else 0,
            "contextidr_el1": values[70] if version >= 4 else 0}


TIMER_STATE = struct.Struct("<8sII8Q")


def read_timer_state(chain: Path, seq: int) -> dict[str, object]:
    rows = read_manifest(chain)
    selected = [r for r in rows if r.seq <= seq]
    if not selected or selected[-1].seq != seq:
        raise ValueError(f"链中找不到 seq={seq}")
    path = selected[-1].timer_path
    if path is None:
        raise ValueError(f"seq={seq} 没有定时器状态摘要（旧格式链）")
    with gzip.open(path, "rb") as f:
        raw = f.read(TIMER_STATE.size)
        if len(raw) != TIMER_STATE.size or f.read(1):
            raise ValueError(f"{path}: 定时器状态摘要长度错误")
    values = TIMER_STATE.unpack(raw)
    if values[0] != b"LCVXTMR1" or values[1] != VERSION or \
            values[2] != TIMER_STATE.size:
        raise ValueError(f"{path}: 定时器状态 header 不匹配")
    q = values[3:]
    return {"seq": seq, "cntpct": q[0], "cntfrq": q[1],
            "cntvoff_el2": q[2], "cntpoff_el2": q[3],
            "cntp_cval": q[4], "cntp_ctl": q[5],
            "cntv_cval": q[6], "cntv_ctl": q[7], "path": str(path)}


GIC_STATE = struct.Struct("<8sIIIIIIHHHBB2x576s96s16sH")


def read_gic_state(chain: Path, seq: int) -> dict[str, object]:
    rows = read_manifest(chain)
    selected = [r for r in rows if r.seq <= seq]
    if not selected or selected[-1].seq != seq:
        raise ValueError(f"链中找不到 seq={seq}")
    path = selected[-1].gic_path
    if path is None:
        raise ValueError(f"seq={seq} 没有 GIC 状态摘要（旧格式链）")
    with gzip.open(path, "rb") as f:
        raw = f.read(GIC_STATE.size)
        if len(raw) != GIC_STATE.size or f.read(1):
            raise ValueError(f"{path}: GIC 状态摘要长度错误")
    values = GIC_STATE.unpack(raw)
    if values[0] != b"LCVXGIC1" or values[1] != VERSION or \
            values[2] != GIC_STATE.size or values[3] < 96:
        raise ValueError(f"{path}: GIC 状态 header 不匹配")
    return {"seq": seq, "num_irq": values[3], "ctlr": values[5],
            "cpu_ctlr": values[6], "priority_mask": values[7],
            "running_priority": values[8], "current_pending": values[9],
            "bpr": values[10], "abpr": values[11], "path": str(path)}


def read_mmio_state(chain: Path, seq: int) -> dict[str, object]:
    rows = read_manifest(chain)
    selected = [r for r in rows if r.seq <= seq]
    if not selected or selected[-1].seq != seq:
        raise ValueError(f"链中找不到 seq={seq}")
    path = selected[-1].mmio_path
    if path is None:
        raise ValueError(f"seq={seq} 没有 C++ MMIO 状态摘要（旧格式链）")
    with gzip.open(path, "rb") as f:
        raw = f.read(MMIO_STATE.size)
        if len(raw) != MMIO_STATE.size or f.read(1):
            raise ValueError(f"{path}: C++ MMIO 状态摘要长度错误")
    values = MMIO_STATE.unpack(raw)
    if values[0] != b"LCVXMMIO" or values[1] != VERSION or \
            values[2] != MMIO_STATE.size:
        raise ValueError(f"{path}: C++ MMIO 状态 header 不匹配")
    return {"seq": seq, "pl031_tick_offset": values[3],
            "pl031_mr": values[4], "pl031_lr": values[5],
            "pl031_im": values[6], "pl031_is": values[7],
            "pl031_alarm_armed": values[8], "now_ns": values[9],
            "path": str(path)}


def read_fp_state(chain: Path, seq: int) -> dict[str, object]:
    rows = read_manifest(chain)
    selected = [row for row in rows if row.seq <= seq]
    if not selected or selected[-1].seq != seq:
        raise ValueError(f"链中找不到 seq={seq}")
    path = selected[-1].fp_path
    if path is None:
        raise ValueError(f"seq={seq} 没有 FP 状态摘要（P7 restore 必须提供）")
    return _read_fp_sidecar(path, seq)


def qmp_request(sock_path: Path, request: dict) -> dict:
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
        s.settimeout(3)
        s.connect(str(sock_path))
        f = s.makefile("rwb", buffering=0)
        f.readline()  # greeting

        def command(obj: dict) -> dict:
            f.write((json.dumps(obj, separators=(",", ":")) + "\n").encode())
            while True:
                line = f.readline()
                if not line:
                    raise RuntimeError("QMP 提前关闭连接")
                reply = json.loads(line)
                if "event" in reply:
                    continue
                if "error" in reply:
                    raise RuntimeError(f"QMP 错误: {reply['error']}")
                return reply

        command({"execute": "qmp_capabilities"})
        return command(request)


def load_devices(chain: Path, seq: int, qmp: Path,
                 experimental: bool = False) -> dict[str, object]:
    if not experimental:
        raise RuntimeError(
            "当前 QEMU 11.1 非 Xen 配置尚无专用 load wrapper；"
            "请先完成 QEMU fork L1-load，禁止直接调用 xen-load-devices-state")
    rows = read_manifest(chain)
    selected = [r for r in rows if r.seq <= seq]
    if not selected or selected[-1].seq != seq:
        raise ValueError(f"链中找不到 seq={seq}")
    # QEMU 的 xen-load-devices-state 只接受 raw QEMUFile；压缩文件在链目录
    # 同级临时文件展开，完成后立即删除，不把它留在 /tmp。
    with tempfile.NamedTemporaryFile(prefix=".restore-dev-", dir=chain,
                                     delete=False) as tmp:
        raw_path = Path(tmp.name)
    try:
        with gzip.open(selected[-1].dev_path, "rb") as src, raw_path.open("wb") as dst:
            while True:
                block = src.read(1 << 20)
                if not block:
                    break
                dst.write(block)
        result = qmp_request(
            qmp, {"execute": "xen-load-devices-state",
                  "arguments": {"filename": str(raw_path)}})
        return {"seq": seq, "qmp": result}
    finally:
        raw_path.unlink(missing_ok=True)


def restore_qemu(chain: Path, seq: int, qemu: Path, image: Path,
                 ram_output: Path, qmp: Path, keep_running: bool) -> dict[str, object]:
    """启动与保存端匹配的 QEMU，加载 device state 后立即暂停。"""
    rows = read_manifest(chain)
    selected = [r for r in rows if r.seq <= seq]
    if not selected or selected[-1].seq != seq:
        raise ValueError(f"链中找不到 seq={seq}")
    meta = _read_manifest_meta(chain)
    if meta is not None:
        qemu_record = meta.get("qemu")
        if not isinstance(qemu_record, dict):
            raise ValueError(f"{chain / MANIFEST_META}: qemu 摘要缺失")
        _validate_file_record({**qemu_record, "path": str(qemu.resolve())},
                              "恢复 QEMU")
        image_records = [item for item in meta.get("inputs", [])
                         if isinstance(item, dict) and item.get("role") == "image"]
        if image_records:
            expected = image_records[0]
            actual = _file_record(image)
            if actual["sha256"] != expected.get("sha256") or \
                    actual["size"] != expected.get("size"):
                raise ValueError(f"恢复 Image SHA256 与 checkpoint 不匹配：{image}")
    restore_ram(chain, seq, ram_output)
    with tempfile.NamedTemporaryFile(prefix=".restore-dev-", dir=chain,
                                     delete=False) as tmp:
        raw_path = Path(tmp.name)
    log_path = chain / f"restore-qemu-{seq}.log"
    try:
        with gzip.open(selected[-1].dev_path, "rb") as src, raw_path.open("wb") as dst:
            while True:
                block = src.read(1 << 20)
                if not block:
                    break
                dst.write(block)
        # 与 run_lockstep_step.sh 的 P6 virt/TCG 参数保持一致。QEMU 的
        # incoming exec 在完成后会自动继续，所以 socket 出现即发送 stop。
        incoming = "exec:cat " + shlex.quote(str(raw_path))
        cmd = [str(qemu), "-machine", "virt", "-cpu",
               "max,has_el3=false,has_el2=false", "-accel",
               "tcg,thread=single,tb-size=64", "-icount",
               "shift=0,align=off,sleep=off", "-display", "none",
               "-incoming", incoming, "-object",
               f"memory-backend-file,id=lcvexram,size={ram_output.stat().st_size},"
               f"mem-path={ram_output},share=on", "-machine",
               "memory-backend=lcvexram", "-qmp",
               f"unix:{qmp},server=on,wait=off", "-device",
               f"loader,file={image},addr=0x44000000,cpu-num=0,force-raw=on"]
        with log_path.open("wb") as log:
            proc = subprocess.Popen(cmd, stdout=log, stderr=log)
        for _ in range(300):
            if qmp.exists():
                break
            if proc.poll() is not None:
                raise RuntimeError(f"QEMU 提前退出，日志见 {log_path}")
            time.sleep(0.01)
        if not qmp.exists():
            raise RuntimeError(f"QMP socket 超时，日志见 {log_path}")
        # 这条 stop 必须尽早发送，避免恢复点继续执行而改变摘要。
        qmp_request(qmp, {"execute": "stop"})
        regs = qmp_request(
            qmp, {"execute": "human-monitor-command",
                  "arguments": {"command-line": "info registers"}})
        result = {"seq": seq, "pid": proc.pid, "registers": regs,
                  "ram": str(ram_output), "log": str(log_path)}
        if keep_running:
            return result
        proc.terminate()
        try:
            proc.wait(timeout=3)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait(timeout=3)
        return result
    finally:
        raw_path.unlink(missing_ok=True)
        if not keep_running:
            ram_output.unlink(missing_ok=True)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    sub = ap.add_subparsers(dest="cmd", required=True)
    p_ram = sub.add_parser("restore-ram")
    p_ram.add_argument("--chain", type=Path, required=True)
    p_ram.add_argument("--seq", type=int, required=True)
    p_ram.add_argument("--output", type=Path, required=True)
    p_init = sub.add_parser("init-manifest")
    p_init.add_argument("--chain", type=Path, required=True)
    p_init.add_argument("--qemu", type=Path, required=True)
    p_init.add_argument("--qemu-version", type=Path, required=True)
    p_init.add_argument("--input", action="append", default=[],
                        metavar="ROLE=PATH",
                        help="输入文件，ROLE 建议为 image 或 dtb，可重复")
    p_init.add_argument("--context", action="append", default=[],
                        metavar="KEY=VALUE")
    p_finalize = sub.add_parser("finalize-manifest")
    p_finalize.add_argument("--chain", type=Path, required=True)
    p_runtime = sub.add_parser("verify-runtime")
    p_runtime.add_argument("--chain", type=Path, required=True)
    p_runtime.add_argument("--qemu", type=Path, required=True)
    p_runtime.add_argument("--qemu-version", type=Path, required=True)
    p_runtime.add_argument("--input", action="append", default=[], metavar="ROLE=PATH")
    p_runtime.add_argument("--context", action="append", default=[], metavar="KEY=VALUE")
    p_dev = sub.add_parser("load-devices")
    p_dev.add_argument("--chain", type=Path, required=True)
    p_dev.add_argument("--seq", type=int, required=True)
    p_dev.add_argument("--qmp", type=Path, required=True)
    p_dev.add_argument("--experimental", action="store_true",
                       help="显式允许调用 QMP Xen 接口（当前已知可能失败）")
    p_arch = sub.add_parser("read-arch")
    p_arch.add_argument("--chain", type=Path, required=True)
    p_arch.add_argument("--seq", type=int, required=True)
    p_sys = sub.add_parser("read-sys")
    p_sys.add_argument("--chain", type=Path, required=True)
    p_sys.add_argument("--seq", type=int, required=True)
    p_timer = sub.add_parser("read-timer")
    p_timer.add_argument("--chain", type=Path, required=True)
    p_timer.add_argument("--seq", type=int, required=True)
    p_gic = sub.add_parser("read-gic")
    p_gic.add_argument("--chain", type=Path, required=True)
    p_gic.add_argument("--seq", type=int, required=True)
    p_mmio = sub.add_parser("read-mmio")
    p_mmio.add_argument("--chain", type=Path, required=True)
    p_mmio.add_argument("--seq", type=int, required=True)
    p_fp = sub.add_parser("read-fp")
    p_fp.add_argument("--chain", type=Path, required=True)
    p_fp.add_argument("--seq", type=int, required=True)
    p_qemu = sub.add_parser("restore-qemu")
    p_qemu.add_argument("--chain", type=Path, required=True)
    p_qemu.add_argument("--seq", type=int, required=True)
    p_qemu.add_argument("--qemu", type=Path, required=True)
    p_qemu.add_argument("--image", type=Path, required=True)
    p_qemu.add_argument("--ram-output", type=Path, required=True)
    p_qemu.add_argument("--qmp", type=Path, required=True)
    p_qemu.add_argument("--keep-running", action="store_true")
    args = ap.parse_args()
    if args.cmd == "init-manifest":
        inputs = []
        for item in args.input:
            role, sep, value = item.partition("=")
            if not sep or not role or not value:
                raise ValueError(f"--input 格式错误：{item}（应为 ROLE=PATH）")
            inputs.append((role, Path(value)))
        context = {}
        for item in args.context:
            key, sep, value = item.partition("=")
            if not sep or not key:
                raise ValueError(f"--context 格式错误：{item}（应为 KEY=VALUE）")
            context[key] = value
        result = init_manifest(args.chain, args.qemu, args.qemu_version,
                               inputs, context)
    elif args.cmd == "finalize-manifest":
        result = finalize_manifest(args.chain)
    elif args.cmd == "verify-runtime":
        inputs = []
        for item in args.input:
            role, sep, value = item.partition("=")
            if not sep or not role or not value:
                raise ValueError(f"--input 格式错误：{item}")
            inputs.append((role, Path(value)))
        context = {}
        for item in args.context:
            key, sep, value = item.partition("=")
            if not sep or not key:
                raise ValueError(f"--context 格式错误：{item}")
            context[key] = value
        result = verify_runtime_inputs(args.chain, args.qemu, args.qemu_version,
                                       inputs, context)
    elif args.cmd == "restore-ram":
        result = restore_ram(args.chain, args.seq, args.output)
    elif args.cmd == "read-arch":
        result = read_arch_state(args.chain, args.seq)
    elif args.cmd == "read-sys":
        result = read_sys_state(args.chain, args.seq)
    elif args.cmd == "read-timer":
        result = read_timer_state(args.chain, args.seq)
    elif args.cmd == "read-gic":
        result = read_gic_state(args.chain, args.seq)
    elif args.cmd == "read-mmio":
        result = read_mmio_state(args.chain, args.seq)
    elif args.cmd == "read-fp":
        result = read_fp_state(args.chain, args.seq)
    elif args.cmd == "load-devices":
        result = load_devices(args.chain, args.seq, args.qmp, args.experimental)
    else:
        result = restore_qemu(args.chain, args.seq, args.qemu, args.image,
                              args.ram_output, args.qmp, args.keep_running)
    print(json.dumps(result, ensure_ascii=False, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
