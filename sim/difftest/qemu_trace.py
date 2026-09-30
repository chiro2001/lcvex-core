"""解析 LCVEX QEMU trace（纯文本或单一 gzip member）。

V1 trace 继续按历史 scalar 记录返回；V2 额外严格校验 FP_INIT、FP_COMMIT
和 fp_sync 的顺序、seq、raw V payload 与 FPCR/FPSR unchanged 语义。
"""

from __future__ import annotations

import gzip
import re


FP_FLAGS_MASK = 0x3
FP_MAX_VECTORS = 4


def _open_trace(path):
    """按 magic 选择 gzip/纯文本，兼容历史未压缩 trace。"""
    with open(path, "rb") as probe:
        compressed = probe.read(2) == b"\x1f\x8b"
    if compressed:
        return gzip.open(path, mode="rt", encoding="utf-8")
    return open(path, encoding="utf-8")


def _parse_fields(line):
    parts = line.split()
    record = {"tag": parts[0]}
    for item in parts[1:]:
        key, sep, value = item.partition("=")
        if not sep:
            # v1 disas="..." may contain spaces; historical consumers only
            # use the key/value fields and ignore the continuation tokens.
            continue
        record[key] = value
    return record


def _uint(record, key, bits=None, required=True):
    value = record.get(key)
    if value is None:
        if required:
            raise ValueError(f"trace 缺少字段 {key}")
        return 0
    try:
        number = int(value, 0)
    except ValueError as exc:
        raise ValueError(f"trace 字段 {key} 不是整数") from exc
    if number < 0 or (bits is not None and number >= (1 << bits)):
        raise ValueError(f"trace 字段 {key} 越界")
    return number


def _fp_state(record):
    state = {
        "fpcr": _uint(record, "fpcr", 32),
        "fpsr": _uint(record, "fpsr", 32),
        "v": [],
    }
    for index in range(32):
        state["v"].append((_uint(record, f"v{index}_lo", 64),
                            _uint(record, f"v{index}_hi", 64)))
    return state


def _fp_delta(record, previous):
    flags = _uint(record, "flags", 32)
    v_mask = _uint(record, "v_mask", 32)
    if flags & ~FP_FLAGS_MASK:
        raise ValueError("FP_COMMIT flags 含保留位")
    count = v_mask.bit_count()
    if count > FP_MAX_VECTORS:
        raise ValueError("FP_COMMIT v_mask popcount 超过 4")
    delta = {
        "flags": flags,
        "v_mask": v_mask,
        "fpcr": _uint(record, "fpcr", 32),
        "fpsr": _uint(record, "fpsr", 32),
        "vectors": [],
    }
    if not (flags & 1) and delta["fpcr"] != previous["fpcr"]:
        raise ValueError("FP_COMMIT 未声明 FPCR 改变")
    if not (flags & 2) and delta["fpsr"] != previous["fpsr"]:
        raise ValueError("FP_COMMIT 未声明 FPSR 改变")
    for index in range(32):
        if v_mask & (1 << index):
            delta["vectors"].append(
                (index, (_uint(record, f"v{index}_lo", 64),
                         _uint(record, f"v{index}_hi", 64))))
    actual_vector_keys = {
        key for key in record if re.fullmatch(r"v\d+_(?:lo|hi)", key)
    }
    expected_vector_keys = {
        f"v{index}_{half}"
        for index in range(32) if v_mask & (1 << index)
        for half in ("lo", "hi")
    }
    if actual_vector_keys != expected_vector_keys:
        raise ValueError("FP_COMMIT 含多余或缺失的 V delta 字段")
    return delta


def _apply_delta(state, delta):
    result = {"fpcr": delta["fpcr"], "fpsr": delta["fpsr"],
              "v": list(state["v"])}
    for index, value in delta["vectors"]:
        result["v"][index] = value
    return result


def _parse_v2(lines):
    records = []
    fp_state = None
    fp_init_seen = False
    scalar_init_seen = False
    pending_delta = None
    pending_sync = None
    commit_seq = 0
    for raw in lines:
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        record = _parse_fields(line)
        tag = record["tag"]
        if tag == "fp_init":
            if fp_init_seen or _uint(record, "seq", 64) != 0:
                raise ValueError("V2 FP_INIT 重复或 seq 非 0")
            fp_state = _fp_state(record)
            fp_init_seen = True
            record["fp_state"] = fp_state
        elif tag == "fp_sync":
            if not fp_init_seen:
                raise ValueError("fp_sync 早于 FP_INIT")
            pending_sync = (_uint(record, "seq", 64), _fp_state(record))
            if pending_sync[1] != fp_state:
                raise ValueError("fp_sync 与当前 FP shadow 不一致")
            record["fp_state"] = pending_sync[1]
        elif tag == "fp_commit":
            if not fp_init_seen or pending_delta is not None:
                raise ValueError("FP_COMMIT 时序非法")
            seq = _uint(record, "seq", 64)
            if seq != commit_seq:
                raise ValueError(f"FP_COMMIT seq={seq} != {commit_seq}")
            pending_delta = (seq, _fp_delta(record, fp_state))
            record["fp_delta"] = pending_delta[1]
        elif tag == "init":
            if scalar_init_seen or not fp_init_seen:
                raise ValueError("V2 init 时序非法")
            if _uint(record, "seq", 64) != 0:
                raise ValueError("V2 init seq 非 0")
            scalar_init_seen = True
        elif tag == "commit":
            if not scalar_init_seen or not fp_init_seen:
                raise ValueError("V2 commit 早于 init/FP_INIT")
            seq = _uint(record, "seq", 64)
            if seq != commit_seq:
                raise ValueError(f"commit seq={seq} != {commit_seq}")
            if pending_delta is None or pending_delta[0] != seq:
                raise ValueError("每条 V2 commit 必须有匹配 FP_COMMIT")
            before = fp_state
            fp_state = _apply_delta(fp_state, pending_delta[1])
            if pending_sync is not None and pending_sync[0] != seq:
                raise ValueError("fp_sync seq 与 commit 不一致")
            pending_delta = None
            pending_sync = None
            record["fp_before"] = before
            record["fp_after"] = fp_state
            commit_seq += 1
        else:
            raise ValueError(f"V2 trace 含未知记录：{tag}")
        records.append(record)
    if not fp_init_seen or not scalar_init_seen:
        raise ValueError("V2 trace 缺少 FP_INIT 或 init")
    if pending_delta is not None or pending_sync is not None:
        raise ValueError("V2 trace 末尾有未配对 FP frame")
    return records


def parse_trace(path):
    lines = []
    try:
        with _open_trace(path) as stream:
            lines.extend(stream)
    except EOFError:
        # 保留历史行为：调用方仍会按提交数下限拒绝截断 trace。
        pass
    header = next((line.strip() for line in lines
                   if line.strip().startswith("# lcvex-qemu-trace ")), None)
    if header == "# lcvex-qemu-trace v2 gzip":
        return _parse_v2(lines)
    records = []
    for line in lines:
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("fp_"):
            raise ValueError("V1 trace 不允许 FP frame；请使用 V2 parser")
        records.append(_parse_fields(line))
    return records
