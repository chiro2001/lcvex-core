#!/usr/bin/env python3
"""LCVEX 压缩 trace 的版本化 manifest 与完整性校验工具。

manifest 绑定 trace 压缩 artifact、运行输入（Image/DTB/QEMU/plugin 等）以及
切片的全局提交区间。trace 只按流处理，不会把完整压缩文件解压到内存；所有
manifest 输出采用临时文件后原子替换。
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import tempfile
import zlib
from pathlib import Path
from typing import Any, Iterable, Iterator


FORMAT = "LCVX-trace-manifest-v1"
SCHEMA_VERSION = 1
GZIP_MAGIC = b"\x1f\x8b"
CHUNK = 1 << 20
REQUIRED_INPUT_ROLES = frozenset({"image", "dtb", "qemu", "plugin", "qemu_version"})


class TraceManifestError(ValueError):
    """trace 或 manifest 不符合格式/完整性约定。"""


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    try:
        with path.open("rb") as stream:
            for block in iter(lambda: stream.read(CHUNK), b""):
                digest.update(block)
    except OSError as exc:
        raise TraceManifestError(f"无法读取文件：{path}: {exc}") from exc
    return digest.hexdigest()


def is_gzip(path: Path) -> bool:
    try:
        with path.open("rb") as stream:
            return stream.read(2) == GZIP_MAGIC
    except OSError as exc:
        raise TraceManifestError(f"无法读取 trace：{path}: {exc}") from exc


def _decode_line(raw: bytes, path: Path) -> str:
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise TraceManifestError(f"trace 含非法 UTF-8：{path}") from exc
    if text.endswith("\r"):
        text = text[:-1]
    return text


def _iter_gzip_lines(path: Path) -> Iterator[str]:
    """严格流式读取单一 gzip member，并拒绝 CRC/截断/尾数据。"""
    decompressor = zlib.decompressobj(16 + zlib.MAX_WBITS)
    pending = bytearray()
    try:
        with path.open("rb") as raw:
            while True:
                chunk = raw.read(CHUNK)
                if not chunk:
                    break
                if decompressor.eof:
                    raise TraceManifestError("gzip trace 含未声明的尾数据或多余 member")
                try:
                    decoded = decompressor.decompress(chunk)
                except zlib.error as exc:
                    raise TraceManifestError(f"gzip trace CRC/压缩流损坏：{path}") from exc
                pending.extend(decoded)
                if decompressor.unused_data:
                    raise TraceManifestError("gzip trace 含尾数据或多个 member")
                while True:
                    marker = pending.find(b"\n")
                    if marker < 0:
                        break
                    raw_line = bytes(pending[:marker])
                    del pending[: marker + 1]
                    yield _decode_line(raw_line, path)
            if not decompressor.eof:
                raise TraceManifestError(f"gzip trace 截断：{path}")
            try:
                pending.extend(decompressor.flush())
            except zlib.error as exc:
                raise TraceManifestError(f"gzip trace CRC/压缩流损坏：{path}") from exc
            if pending:
                yield _decode_line(bytes(pending), path)
    except TraceManifestError:
        raise
    except (OSError, EOFError, zlib.error) as exc:
        raise TraceManifestError(f"gzip trace 无法读取：{path}: {exc}") from exc


def _iter_plain_lines(path: Path) -> Iterator[str]:
    try:
        with path.open("rb") as stream:
            pending = bytearray()
            while True:
                chunk = stream.read(CHUNK)
                if not chunk:
                    break
                pending.extend(chunk)
                while True:
                    marker = pending.find(b"\n")
                    if marker < 0:
                        break
                    raw_line = bytes(pending[:marker])
                    del pending[: marker + 1]
                    yield _decode_line(raw_line, path)
            if pending:
                yield _decode_line(bytes(pending), path)
    except TraceManifestError:
        raise
    except OSError as exc:
        raise TraceManifestError(f"trace 无法读取：{path}: {exc}") from exc


def iter_trace(path: Path) -> Iterator[tuple[str, str]]:
    """返回 ``(comment/init/commit/other, line)``，并严格消费输入流。"""
    if not path.is_file():
        raise TraceManifestError(f"trace 文件不存在：{path}")
    lines = _iter_gzip_lines(path) if is_gzip(path) else _iter_plain_lines(path)
    for text in lines:
        if text.startswith("#"):
            yield "comment", text
        elif text.startswith("init "):
            yield "init", text
        elif text.startswith("commit "):
            yield "commit", text
        elif text.startswith("fp_init "):
            yield "fp_init", text
        elif text.startswith("fp_sync "):
            yield "fp_sync", text
        elif text.startswith("fp_commit "):
            yield "fp_commit", text
        elif text.strip():
            yield "other", text


def canonical_line(line: str) -> bytes:
    """用于内容摘要的稳定换行表示。"""
    return (line.rstrip("\r") + "\n").encode("utf-8")


def _field(line: str, key: str) -> str | None:
    match = re.search(rf"(?:^|\s){re.escape(key)}=([^\s]+)", line)
    return match.group(1) if match else None


def _hash_lines(lines: Iterable[str]) -> str:
    digest = hashlib.sha256()
    for line in lines:
        digest.update(canonical_line(line))
    return digest.hexdigest()


def _summary_core(path: Path) -> tuple[dict[str, Any], list[str]]:
    commits = 0
    first_pc: str | None = None
    last_pc: str | None = None
    first_insn: str | None = None
    last_insn: str | None = None
    commit_digest = hashlib.sha256()
    header_digest = hashlib.sha256()
    init_digest = hashlib.sha256()
    headers: list[str] = []
    init_seen = False
    commit_seen = False
    fp_init_seen = False
    fp_pending = False
    fp_sync_pending = False
    v2 = False
    trace_seq_start: int | None = None
    for kind, line in iter_trace(path):
        if kind == "comment":
            if not init_seen and not commit_seen:
                header_digest.update(canonical_line(line))
                if len(headers) < 8:
                    headers.append(line)
                if line == "# lcvex-qemu-trace v2 gzip":
                    v2 = True
            continue
        if kind in {"fp_init", "fp_sync", "fp_commit"}:
            if not v2:
                raise TraceManifestError("非 V2 trace 不允许 FP frame")
            seq_text = _field(line, "seq")
            if seq_text is None:
                raise TraceManifestError("FP frame 缺少 seq")
            try:
                frame_seq = int(seq_text, 0)
            except ValueError as exc:
                raise TraceManifestError("FP frame seq 无效") from exc
            if kind == "fp_init":
                if fp_init_seen or init_seen or commit_seen or frame_seq != 0:
                    raise TraceManifestError("FP_INIT 位置/次数非法")
                fp_init_seen = True
            elif kind == "fp_sync":
                if not fp_init_seen or fp_pending:
                    raise TraceManifestError("fp_sync 时序非法")
                if trace_seq_start is None:
                    trace_seq_start = frame_seq
                if frame_seq != trace_seq_start + commits:
                    raise TraceManifestError("fp_sync seq 非当前 commit seq")
                fp_sync_pending = True
            else:
                if not fp_init_seen or fp_pending:
                    raise TraceManifestError("FP_COMMIT seq/时序非法")
                if trace_seq_start is None:
                    trace_seq_start = frame_seq
                if frame_seq != trace_seq_start + commits:
                    raise TraceManifestError("FP_COMMIT seq/时序非法")
                flags = _field(line, "flags")
                mask = _field(line, "v_mask")
                if flags is None or mask is None:
                    raise TraceManifestError("FP_COMMIT 缺少 flags/v_mask")
                try:
                    if int(flags, 0) & ~0x3 or int(mask, 0).bit_count() > 4:
                        raise TraceManifestError("FP_COMMIT flags/popcount 非法")
                except ValueError as exc:
                    raise TraceManifestError("FP_COMMIT flags/v_mask 无效") from exc
                fp_pending = True
            continue
        if kind == "init":
            if init_seen:
                raise TraceManifestError("trace 含多个 init 行")
            if commit_seen:
                raise TraceManifestError("init 必须位于所有 commit 之前")
            init_seen = True
            init_digest.update(canonical_line(line))
            continue
        if kind == "other":
            raise TraceManifestError(f"trace 含未知非空行：{line[:120]}")
        if not init_seen:
            raise TraceManifestError("trace 缺少位于首个 commit 之前的 init 行")
        pc = _field(line, "pc")
        insn = _field(line, "insn")
        if pc is None or insn is None:
            raise TraceManifestError(f"commit 缺少 pc/insn：{line[:120]}")
        if v2:
            seq_text = _field(line, "seq")
            if seq_text is None:
                raise TraceManifestError("V2 commit 缺少 seq")
            try:
                commit_seq = int(seq_text, 0)
            except ValueError as exc:
                raise TraceManifestError("V2 commit seq 无效") from exc
            if trace_seq_start is None:
                trace_seq_start = commit_seq
            if commit_seq != trace_seq_start + commits or not fp_pending:
                raise TraceManifestError("V2 commit 与 FP_COMMIT 不匹配")
            fp_pending = False
            if fp_sync_pending:
                fp_sync_pending = False
        commit_seen = True
        commit_digest.update(canonical_line(line))
        if commits == 0:
            first_pc, first_insn = pc, insn
        last_pc, last_insn = pc, insn
        commits += 1
    if not init_seen:
        raise TraceManifestError("trace 缺少 init 记录")
    if commits == 0:
        raise TraceManifestError("trace 没有 commit 记录")
    if v2 and (not fp_init_seen or fp_pending or fp_sync_pending):
        raise TraceManifestError("V2 trace FP frame 不完整")
    summary = {
        "commits": commits,
        "seq_start": 0,
        "seq_end": commits,
        "first_pc": first_pc,
        "last_pc": last_pc,
        "first_insn": first_insn,
        "last_insn": last_insn,
        "headers": headers,
        "header_sha256": header_digest.hexdigest(),
        "init": True,
        "init_sha256": init_digest.hexdigest(),
        "commit_sha256": commit_digest.hexdigest(),
        "trace_format": "v2" if v2 else "v1",
    }
    return summary, headers


def summarize_trace(path: Path, seq_start: int = 0) -> dict[str, Any]:
    if seq_start < 0:
        raise TraceManifestError("seq_start 不能为负数")
    summary, _ = _summary_core(path)
    summary["seq_start"] = seq_start
    summary["seq_end"] = seq_start + int(summary["commits"])
    return summary


def selected_commit_digest(path: Path, start: int, end: int,
                           source_seq_start: int = 0) -> tuple[str, int]:
    """计算 parent 中全局区间的 canonical commit 摘要和条数。"""
    if start < source_seq_start or end < start:
        raise TraceManifestError("选段范围无效")
    digest = hashlib.sha256()
    count = 0
    source_summary = summarize_trace(path, source_seq_start)
    source_end = int(source_summary["seq_end"])
    if end > source_end:
        raise TraceManifestError("选段范围超出 source trace")
    for kind, line in iter_trace(path):
        if kind != "commit":
            continue
        global_seq = source_seq_start + count
        if start <= global_seq < end:
            digest.update(canonical_line(line))
        count += 1
    if count != int(source_summary["commits"]):
        raise TraceManifestError("source trace 在两次读取间发生变化")
    expected = end - start
    if count < expected or expected <= 0:
        raise TraceManifestError("选段为空或越界")
    return digest.hexdigest(), expected


def _manifest_ref(path: Path, base_dir: Path) -> str:
    return os.path.relpath(path.resolve(), base_dir.resolve())


def _resolve_ref(manifest: Path, value: object, what: str) -> Path:
    if not isinstance(value, str) or not value:
        raise TraceManifestError(f"manifest {what} 路径无效")
    path = Path(value)
    if not path.is_absolute():
        path = manifest.parent / path
    return path.resolve()


def manifest_trace_path(manifest: Path, data: dict[str, Any] | None = None) -> Path:
    manifest = manifest.resolve()
    if data is None:
        data = load_manifest(manifest)
    trace = data.get("trace")
    if not isinstance(trace, dict):
        raise TraceManifestError("manifest 缺少 trace 对象")
    return _resolve_ref(manifest, trace.get("path"), "trace")


def _file_record(path: Path, base_dir: Path | None = None) -> dict[str, Any]:
    path = path.resolve()
    if not path.is_file():
        raise TraceManifestError(f"文件不存在：{path}")
    value = str(path) if base_dir is None else _manifest_ref(path, base_dir)
    return {"path": value, "bytes": path.stat().st_size, "sha256": sha256_file(path)}


def _validate_record(manifest: Path, record: object, what: str) -> Path:
    if not isinstance(record, dict):
        raise TraceManifestError(f"{what} 摘要无效")
    try:
        path = _resolve_ref(manifest, record["path"], f"{what}.path")
        expected_bytes = int(record["bytes"])
        expected_hash = str(record["sha256"])
    except (KeyError, TypeError, ValueError) as exc:
        raise TraceManifestError(f"{what} 摘要字段无效") from exc
    if expected_bytes < 0 or not re.fullmatch(r"[0-9a-f]{64}", expected_hash):
        raise TraceManifestError(f"{what} 摘要格式无效")
    if not path.is_file():
        raise TraceManifestError(f"{what} 文件不存在：{path}")
    actual_bytes = path.stat().st_size
    actual_hash = sha256_file(path)
    if actual_bytes != expected_bytes or actual_hash != expected_hash:
        raise TraceManifestError(f"{what} 文件大小或 SHA256 不一致")
    return path


def load_manifest(path: Path) -> dict[str, Any]:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise TraceManifestError(f"manifest 无法读取：{path}: {exc}") from exc
    if not isinstance(data, dict) or data.get("format") != FORMAT:
        raise TraceManifestError(f"manifest format 不匹配：{path}")
    if data.get("schema_version") != SCHEMA_VERSION:
        raise TraceManifestError(f"manifest schema_version 不支持：{path}")
    return data


def _validate_inputs(path: Path, data: dict[str, Any]) -> dict[str, Path]:
    inputs = data.get("inputs")
    if not isinstance(inputs, list) or not inputs:
        raise TraceManifestError("manifest inputs 为空")
    result: dict[str, Path] = {}
    for index, record in enumerate(inputs):
        if not isinstance(record, dict) or not isinstance(record.get("role"), str):
            raise TraceManifestError(f"inputs[{index}] 缺少 role")
        role = record["role"]
        if role in result:
            raise TraceManifestError(f"inputs 含重复 role：{role}")
        result[role] = _validate_record(path, record, f"输入[{role}]")
    missing = sorted(REQUIRED_INPUT_ROLES - result.keys())
    if missing:
        raise TraceManifestError("manifest 缺少运行输入：" + ",".join(missing))
    return result


def _validate_compression(trace_path: Path, data: dict[str, Any]) -> None:
    compression = data.get("compression")
    if not isinstance(compression, dict):
        raise TraceManifestError("manifest compression 字段无效")
    codec = compression.get("codec")
    expected = "gzip" if is_gzip(trace_path) else "none"
    if codec != expected or compression.get("strict_single_member") is not True:
        raise TraceManifestError("compression 元数据与 trace 实际格式不一致")
    if codec == "gzip" and compression.get("members") != 1:
        raise TraceManifestError("gzip manifest 必须声明单一 member")
    if codec == "none" and compression.get("members") != 0:
        raise TraceManifestError("明文 trace 的 gzip member 数必须为 0")


def _validate_summary(trace_path: Path, data: dict[str, Any]) -> dict[str, Any]:
    expected = data.get("summary")
    if not isinstance(expected, dict):
        raise TraceManifestError("manifest 缺少 summary")
    try:
        seq_start = int(expected["seq_start"])
        seq_end = int(expected["seq_end"])
    except (KeyError, TypeError, ValueError) as exc:
        raise TraceManifestError("summary.seq_start/seq_end 无效") from exc
    if seq_start < 0 or seq_end <= seq_start:
        raise TraceManifestError("summary 必须是非空半开区间")
    actual = summarize_trace(trace_path, seq_start)
    keys = ("commits", "seq_start", "seq_end", "first_pc", "last_pc",
            "first_insn", "last_insn", "headers", "header_sha256", "init",
            "init_sha256", "commit_sha256")
    for key in keys:
        if actual.get(key) != expected.get(key):
            raise TraceManifestError(f"summary.{key} 与 trace 不一致")
    if seq_end - seq_start != int(actual["commits"]):
        raise TraceManifestError("summary 区间长度与 commits 不一致")
    return actual


def verify_manifest(path: Path, _seen: set[Path] | None = None) -> dict[str, Any]:
    path = path.resolve()
    seen = set() if _seen is None else _seen
    if path in seen:
        raise TraceManifestError(f"manifest parent 引用形成循环：{path}")
    seen.add(path)
    data = load_manifest(path)
    trace_path = manifest_trace_path(path, data)
    trace_record = data.get("trace")
    _validate_record(path, trace_record, "trace")
    if trace_path == path:
        raise TraceManifestError("manifest 不能同时作为 trace")
    _validate_compression(trace_path, data)
    summary = _validate_summary(trace_path, data)
    _validate_inputs(path, data)
    artifacts = data.get("artifacts")
    if not isinstance(artifacts, list) or len(artifacts) != 1:
        raise TraceManifestError("manifest artifacts 必须唯一记录 trace")
    artifact = artifacts[0]
    if not isinstance(artifact, dict) or artifact.get("role") != "trace":
        raise TraceManifestError("manifest artifacts 缺少 trace role")
    _validate_record(path, artifact, "artifact[trace]")
    if artifact != {**trace_record, "role": "trace"}:
        raise TraceManifestError("artifact[trace] 与 trace 摘要不一致")

    parent = data.get("parent")
    if parent is not None:
        if not isinstance(parent, dict):
            raise TraceManifestError("parent 必须是对象")
        parent_manifest = _resolve_ref(path, parent.get("manifest"), "parent manifest")
        parent_data = verify_manifest(parent_manifest, seen)
        parent_summary = parent_data["summary"]
        start, end = int(summary["seq_start"]), int(summary["seq_end"])
        pstart, pend = int(parent_summary["seq_start"]), int(parent_summary["seq_end"])
        if start < pstart or end > pend:
            raise TraceManifestError("切片范围超出 parent trace")
        if parent.get("sha256") != sha256_file(parent_manifest):
            raise TraceManifestError("parent manifest SHA256 不一致")
        if parent.get("trace_sha256") != parent_data["trace"]["sha256"]:
            raise TraceManifestError("parent trace SHA256 不一致")
        if parent.get("range") != {"start": start, "end": end}:
            raise TraceManifestError("parent range 与 summary 不一致")
        if parent.get("segment_sha256") != selected_commit_digest(
                manifest_trace_path(parent_manifest, parent_data), start, end, pstart)[0]:
            raise TraceManifestError("parent segment SHA256 不一致")
        if summary["commit_sha256"] != parent["segment_sha256"]:
            raise TraceManifestError("child commit 内容不是 parent 对应区间")
        if summary["init_sha256"] != parent_summary["init_sha256"] or \
                summary["header_sha256"] != parent_summary["header_sha256"]:
            raise TraceManifestError("child init/header 与 parent 不一致")
        # child 输入必须与 parent 的 role/hash 完全一致；路径可因 artifact 目录
        # 移动而重新相对定位，因此按 role/摘要比较而不是比较 path 字符串。
        child_inputs = {r["role"]: r for r in data["inputs"]}
        parent_inputs = {r["role"]: r for r in parent_data["inputs"]}
        for role, record in parent_inputs.items():
            if role not in child_inputs:
                raise TraceManifestError(f"child 缺少 parent 输入：{role}")
            if (child_inputs[role].get("bytes"), child_inputs[role].get("sha256")) != \
                    (record.get("bytes"), record.get("sha256")):
                raise TraceManifestError(f"child 输入摘要改变：{role}")
    else:
        if "segment_sha256" in data:
            raise TraceManifestError("root manifest 不应含 parent segment")
    return data


def _write_json_checked(path: Path, data: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, raw_tmp = tempfile.mkstemp(prefix=f".{path.name}.", suffix=".tmp", dir=path.parent)
    tmp = Path(raw_tmp)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            json.dump(data, stream, ensure_ascii=False, indent=2, sort_keys=True)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        verify_manifest(tmp)
        os.replace(tmp, path)
    except Exception:
        try:
            tmp.unlink()
        except FileNotFoundError:
            pass
        raise


def _parse_inputs(values: Iterable[str]) -> list[tuple[str, Path]]:
    result: list[tuple[str, Path]] = []
    roles: set[str] = set()
    for item in values:
        role, sep, value = item.partition("=")
        if not sep or not role or not value or role in roles:
            raise TraceManifestError(f"--input 格式/role 无效：{item}（应为唯一 ROLE=PATH）")
        roles.add(role)
        result.append((role, Path(value).resolve()))
    return result


def _record_inputs(inputs: list[tuple[str, Path]], base_dir: Path) -> list[dict[str, Any]]:
    records = []
    for role, path in inputs:
        record = _file_record(path, base_dir)
        record["role"] = role
        records.append(record)
    return sorted(records, key=lambda item: str(item["role"]))


def _inherit_inputs(parent_manifest: Path, parent_data: dict[str, Any], out_dir: Path) -> list[dict[str, Any]]:
    records: list[dict[str, Any]] = []
    for record in parent_data["inputs"]:
        source = _resolve_ref(parent_manifest, record["path"], f"输入[{record['role']}]")
        rebased = _file_record(source, out_dir)
        rebased["role"] = record["role"]
        if rebased["bytes"] != record["bytes"] or rebased["sha256"] != record["sha256"]:
            raise TraceManifestError(f"parent 输入摘要改变：{record['role']}")
        records.append(rebased)
    return sorted(records, key=lambda item: str(item["role"]))


def create_manifest(args: argparse.Namespace) -> dict[str, Any]:
    trace = Path(args.trace).resolve()
    out = Path(args.out).resolve()
    if trace == out:
        raise TraceManifestError("manifest 输出不能覆盖 trace")
    if args.parent and Path(args.parent).resolve() == out:
        raise TraceManifestError("parent manifest 不能与输出 manifest 相同")
    parent_path: Path | None = None
    parent_data: dict[str, Any] | None = None
    if args.parent:
        parent_path = Path(args.parent).resolve()
        parent_data = verify_manifest(parent_path)
        if trace == manifest_trace_path(parent_path, parent_data):
            raise TraceManifestError("child manifest 的 trace 不能覆盖 parent trace")
        if args.start is None or args.end is None:
            raise TraceManifestError("指定 parent 时必须提供全局 --start 与 --end")
        seq_start = int(args.start)
        seq_end = int(args.end)
        pstart, pend = int(parent_data["summary"]["seq_start"]), int(parent_data["summary"]["seq_end"])
        if seq_start < pstart or seq_end > pend:
            raise TraceManifestError("切片范围超出 parent trace")
    else:
        if args.start is not None or args.end is not None:
            raise TraceManifestError("无 parent 时请使用 --seq-start 声明 trace 全局起点")
        seq_start = int(args.seq_start)
        seq_end = None
    if seq_start < 0 or (seq_end is not None and (seq_end <= seq_start)):
        raise TraceManifestError("manifest seq 范围无效")
    summary = summarize_trace(trace, seq_start)
    if seq_end is not None and int(summary["seq_end"]) != seq_end:
        raise TraceManifestError("manifest range 与 trace commit 数不一致")
    if parent_data is not None:
        segment_sha, count = selected_commit_digest(
            manifest_trace_path(parent_path, parent_data), seq_start, seq_end,
            int(parent_data["summary"]["seq_start"]))
        if count != int(summary["commits"]) or segment_sha != summary["commit_sha256"]:
            raise TraceManifestError("trace 内容不是 parent 对应区间")
        inputs = _inherit_inputs(parent_path, parent_data, out.parent)
    else:
        inputs = _record_inputs(_parse_inputs(args.input), out.parent)
    roles = {record["role"] for record in inputs}
    missing = sorted(REQUIRED_INPUT_ROLES - roles)
    if missing:
        raise TraceManifestError("manifest 缺少运行输入：" + ",".join(missing))
    codec = "gzip" if is_gzip(trace) else "none"
    data: dict[str, Any] = {
        "format": FORMAT,
        "schema_version": SCHEMA_VERSION,
        "trace": _file_record(trace, out.parent),
        "artifacts": [],
        "compression": {"codec": codec, "members": 1 if codec == "gzip" else 0,
                         "strict_single_member": True},
        "summary": summary,
        "inputs": inputs,
        "generator": {
            "qemu_commit": str(args.qemu_commit),
            "plugin_version": str(args.plugin_version),
            "command": str(args.command_line or ""),
        },
    }
    data["artifacts"] = [{**data["trace"], "role": "trace"}]
    if parent_data is not None:
        data["parent"] = {
            "manifest": _manifest_ref(parent_path, out.parent),
            "sha256": sha256_file(parent_path),
            "trace_sha256": parent_data["trace"]["sha256"],
            "range": {"start": seq_start, "end": seq_end},
            "segment_sha256": summary["commit_sha256"],
        }
    _write_json_checked(out, data)
    return data


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    create = sub.add_parser("create", help="创建并校验 manifest")
    create.add_argument("--trace", required=True, type=Path)
    create.add_argument("--out", required=True, type=Path)
    create.add_argument("--parent", type=Path)
    create.add_argument("--start", type=int, default=None,
                        help="child 的全局起点（半开区间）")
    create.add_argument("--end", type=int, default=None,
                        help="child 的全局终点（不含）")
    create.add_argument("--seq-start", type=int, default=0,
                        help="root/tail trace 的全局起点")
    create.add_argument("--input", action="append", default=[], metavar="ROLE=PATH")
    create.add_argument("--qemu-commit", default="unknown")
    create.add_argument("--plugin-version", default="unknown")
    create.add_argument("--command-line", default="")
    verify = sub.add_parser("verify", help="校验 manifest 与所有绑定 artifact")
    verify.add_argument("--manifest", required=True, type=Path)
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        if args.command == "create":
            data = create_manifest(args)
            print(json.dumps({"manifest": str(Path(args.out).resolve()),
                              "commits": data["summary"]["commits"],
                              "seq": [data["summary"]["seq_start"], data["summary"]["seq_end"]],
                              "sha256": data["trace"]["sha256"]}, ensure_ascii=False))
        else:
            data = verify_manifest(Path(args.manifest).resolve())
            print(json.dumps({"manifest": str(Path(args.manifest).resolve()),
                              "commits": data["summary"]["commits"],
                              "seq": [data["summary"]["seq_start"], data["summary"]["seq_end"]],
                              "result": "pass"}, ensure_ascii=False))
        return 0
    except TraceManifestError as exc:
        print(f"ERROR: {exc}", file=__import__("sys").stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
