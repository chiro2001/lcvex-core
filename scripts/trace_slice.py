#!/usr/bin/env python3
"""流式切片 LCVEX QEMU trace，并生成可验证的 parent manifest。

切片区间使用全局半开序号 ``[start,end)``。协调器仍从完整镜像启动，使用
``--skip start`` 快进 DUT，再消费切片中的局部提交；切片的 init/header 必须
与 parent 相同，因而不会把切片误当作独立启动状态。
"""

from __future__ import annotations

import argparse
import gzip
import hashlib
import os
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from trace_manifest import (  # noqa: E402
    TraceManifestError,
    canonical_line,
    create_manifest,
    iter_trace,
    manifest_trace_path,
    summarize_trace,
    verify_manifest,
)


def _write_line(stream, line: str) -> None:
    stream.write(line + "\n")


def slice_trace(src: Path, out: Path, start: int, end: int,
                source_seq_start: int = 0,
                source_seq_end: int | None = None) -> dict[str, int | str]:
    """从 source 的全局区间流式生成切片，成功后才原子替换输出。"""
    src = src.resolve()
    out = out.resolve()
    if src == out:
        raise TraceManifestError("--in 与 --out 不能是同一路径")
    if start < 0 or end < -1 or (end >= 0 and end <= start):
        raise TraceManifestError("切片范围无效：需满足 0 <= start < end，end=-1 表示到结尾")
    if source_seq_start < 0:
        raise TraceManifestError("source_seq_start 不能为负数")
    source_summary = summarize_trace(src, source_seq_start)
    actual_source_end = int(source_summary["seq_end"])
    if source_seq_end is not None and source_seq_end != actual_source_end:
        raise TraceManifestError("source manifest 的 seq_end 与 trace 不一致")
    effective_end = actual_source_end if end < 0 else end
    if start < source_seq_start or effective_end > actual_source_end:
        raise TraceManifestError(
            f"切片范围 [{start}, {effective_end}) 超出 source "
            f"[{source_seq_start}, {actual_source_end})"
        )
    local_start = start - source_seq_start
    local_end = effective_end - source_seq_start
    if local_end <= local_start:
        raise TraceManifestError("切片不能为空")

    out.parent.mkdir(parents=True, exist_ok=True)
    fd, raw_tmp = tempfile.mkstemp(prefix=f".{out.name}.", suffix=".tmp", dir=out.parent)
    os.close(fd)
    tmp = Path(raw_tmp)
    written = 0
    source_commits = 0
    init_done = False
    digest = hashlib.sha256()
    source_digest = hashlib.sha256()
    try:
        # 临时文件不使用 .gz 后缀，故显式选择 writer。
        if out.suffix == ".gz":
            stream = gzip.open(tmp, "wt", encoding="utf-8", newline="\n")
        else:
            stream = tmp.open("w", encoding="utf-8", newline="\n")
        with stream as fout:
            for kind, line in iter_trace(src):
                if kind == "comment":
                    # 只复制 init 之前的 header；parent slice 末尾的 footer
                    # 不应变成 child 的起始 header。
                    if not init_done:
                        _write_line(fout, line)
                    continue
                if kind == "init":
                    if init_done:
                        raise TraceManifestError("source trace 含多个 init")
                    _write_line(fout, line)
                    init_done = True
                    continue
                if kind != "commit":
                    raise TraceManifestError(f"trace 含未知非空行：{line[:120]}")
                if not init_done:
                    raise TraceManifestError("source trace 缺少 init")
                selected = local_start <= source_commits < local_end
                if selected:
                    _write_line(fout, line)
                    digest.update(canonical_line(line))
                    written += 1
                source_digest.update(canonical_line(line))
                source_commits += 1
            if source_commits != int(source_summary["commits"]):
                raise TraceManifestError("source trace 在切片期间发生变化")
            if source_digest.hexdigest() != source_summary["commit_sha256"]:
                raise TraceManifestError("source trace 内容在切片期间发生变化")
            if written != local_end - local_start:
                raise TraceManifestError("切片提交数与请求范围不一致")
            _write_line(
                fout,
                "# slice format=LCVX-trace-slice-v1 global_start=%d global_end=%d "
                "written=%d segment_sha256=%s"
                % (start, effective_end, written, digest.hexdigest()),
            )
            fout.flush()
            os.fsync(fout.fileno())
        os.replace(tmp, out)
    except TraceManifestError:
        try:
            tmp.unlink()
        except FileNotFoundError:
            pass
        raise
    except (OSError, EOFError, gzip.BadGzipFile) as exc:
        try:
            tmp.unlink()
        except FileNotFoundError:
            pass
        raise TraceManifestError(f"trace 切片失败：{src}: {exc}") from exc
    return {"source_commits": int(source_summary["commits"]), "start": start,
            "end": effective_end, "written": written,
            "segment_sha256": digest.hexdigest(),
            "source_seq_start": source_seq_start}


def _parse_args() -> argparse.Namespace:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--in", dest="src", required=True, help="完整 trace（gzip/明文）")
    ap.add_argument("--out", required=True, help="切片输出（.gz 自动压缩）")
    ap.add_argument("--start", type=int, default=0, help="全局起始 seq（含）")
    ap.add_argument("--end", type=int, default=-1, help="全局结束 seq（不含；-1 到结尾）")
    ap.add_argument("--source-manifest", type=Path,
                    help="source trace manifest；提供后按其全局 seq 校验")
    ap.add_argument("--manifest", type=Path,
                    help="为输出切片写 child manifest")
    ap.add_argument("--qemu-commit", default="unknown")
    ap.add_argument("--plugin-version", default="unknown")
    ap.add_argument("--command-line", default="")
    return ap.parse_args()


def main() -> int:
    args = _parse_args()
    try:
        src = Path(args.src).resolve()
        out = Path(args.out).resolve()
        source_start = 0
        source_end = None
        parent = None
        if args.source_manifest:
            parent = Path(args.source_manifest).resolve()
            parent_data = verify_manifest(parent)
            if manifest_trace_path(parent, parent_data) != src:
                raise TraceManifestError("source-manifest 未绑定当前输入 trace")
            source_start = int(parent_data["summary"]["seq_start"])
            source_end = int(parent_data["summary"]["seq_end"])
        result = slice_trace(src, out, args.start, args.end,
                             source_start, source_end)
        if args.manifest:
            manifest = Path(args.manifest).resolve()
            if manifest in (src, out):
                raise TraceManifestError("manifest 不能覆盖输入或输出 trace")
            if parent is None:
                raise TraceManifestError("创建 slice manifest 必须提供 --source-manifest")
            ns = argparse.Namespace(
                trace=out, out=manifest, parent=parent,
                start=int(result["start"]), end=int(result["end"]), seq_start=0,
                input=[], qemu_commit=args.qemu_commit,
                plugin_version=args.plugin_version, command_line=args.command_line,
            )
            create_manifest(ns)
        print("slice written %d commits [%d, %d)" %
              (int(result["written"]), int(result["start"]), int(result["end"])))
        return 0
    except TraceManifestError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
