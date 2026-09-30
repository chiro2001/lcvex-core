#!/usr/bin/env python3
"""流式比较两份 LCVEX commit JSONL trace，定位第一处分歧。

Trace 文件由 ``microbench_runner --trace FILE`` 生成，包含 header、commit
records 和 footer。比较只使用 commit 的架构字段；cycle 与 fetch 观测字段
被保留在上下文中但不参与等价判断。
"""

import argparse
from collections import deque
import hashlib
import io
import json
import os
import shutil
import subprocess
import sys

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))


def sha256_file(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


class TraceReader:
    """Read one JSONL trace without retaining its commit sequence."""

    def __init__(self, stream, label: str):
        self.stream = stream
        self.label = label
        self.header = self._read_header()
        self.footer = None
        self.records = 0
        self.eof = False

    def _read_header(self):
        line = self.stream.readline()
        if not line:
            raise ValueError(f"{self.label}: empty trace")
        try:
            item = json.loads(line)
        except json.JSONDecodeError as exc:
            raise ValueError(f"{self.label}: invalid header JSON: {exc}") from exc
        if item.get("kind") != "header":
            raise ValueError(f"{self.label}: first record is not a header")
        return item

    def next_record(self):
        if self.eof:
            return None
        for line in self.stream:
            if not line.strip():
                continue
            try:
                item = json.loads(line)
            except json.JSONDecodeError as exc:
                raise ValueError(f"{self.label}: invalid JSON at record "
                                 f"{self.records + 1}: {exc}") from exc
            kind = item.get("kind")
            if kind == "commit":
                self.records += 1
                return item
            if kind == "footer":
                self.footer = item
                self.eof = True
                return None
            raise ValueError(f"{self.label}: unexpected record kind {kind!r}")
        self.eof = True
        return None


def architecture_record(record):
    """Return fields that describe an architectural commit.

    ``seq`` is an observation index and ``cycle``/``fetch`` are timing/debug
    context. The remaining fields include PC, instruction, next PC and all
    normalized active effects emitted by the runner.
    """
    return {k: v for k, v in record.items()
            if k not in {"kind", "seq", "cycle", "fetch"}}


def pc_insn_key(record):
    return record.get("pc"), record.get("insn")


def _same_key(record_a, record_b):
    return (record_a is not None and record_b is not None and
            pc_insn_key(record_a) == pc_insn_key(record_b))


def classify_mismatch(off_record, on_record, before_off, before_on,
                      after_off, after_on):
    """Classify the first mismatch using bounded local context."""
    if off_record is None or on_record is None:
        return "termination-boundary", "one trace ended before the other"
    if pc_insn_key(off_record) == pc_insn_key(on_record):
        return "effect-mismatch", "same PC/insn with different commit effects"
    if before_off and _same_key(off_record, before_off[-1]):
        return "duplicate", "off trace repeated its previous PC/insn"
    if before_on and _same_key(on_record, before_on[-1]):
        return "duplicate", "on trace repeated its previous PC/insn"
    if any(_same_key(off_record, candidate) for candidate in after_on):
        return "skip", "on trace skipped or reordered the off trace record"
    if any(_same_key(on_record, candidate) for candidate in after_off):
        return "skip", "off trace skipped or reordered the on trace record"
    return "wrong-path", "PC/insn diverged without a bounded duplicate/skip match"


def _footer_signature(footer):
    if not footer:
        return None
    # cycles deliberately do not belong to architectural equality.
    return tuple(footer.get(k) for k in
                 ("status", "retired_insn", "commit_digest", "memory_digest"))


def compare_readers(off_reader: TraceReader, on_reader: TraceReader,
                    window: int = 4):
    before_off = deque(maxlen=window)
    before_on = deque(maxlen=window)
    compared = 0

    while True:
        off_record = off_reader.next_record()
        on_record = on_reader.next_record()
        off_index = off_reader.records
        on_index = on_reader.records
        if off_record is None or on_record is None:
            if off_record is None and on_record is None:
                if (_footer_signature(off_reader.footer) ==
                        _footer_signature(on_reader.footer)):
                    return {
                        "status": "equal",
                        "category": "equal",
                        "records_compared": compared,
                        "first_mismatch": None,
                        "windows": {"before": {"off": list(before_off),
                                                 "on": list(before_on)},
                                    "after": {"off": [], "on": []}},
                    }
                category = "termination-boundary"
                reason = "commit prefix equal but footer architectural summary differs"
            else:
                category = "termination-boundary"
                reason = "one trace ended before the other"

            after_off = []
            after_on = []
            if off_record is None:
                for _ in range(window):
                    item = on_reader.next_record()
                    if item is None:
                        break
                    after_on.append(item)
            if on_record is None:
                for _ in range(window):
                    item = off_reader.next_record()
                    if item is None:
                        break
                    after_off.append(item)
            return {
                "status": "mismatch",
                "category": category,
                "records_compared": compared,
                "first_mismatch": {
                    "off_index": off_index,
                    "on_index": on_index,
                    "off": off_record,
                    "on": on_record,
                    "reason": reason,
                },
                "windows": {"before": {"off": list(before_off),
                                         "on": list(before_on)},
                            "after": {"off": after_off, "on": after_on}},
            }

        if architecture_record(off_record) != architecture_record(on_record):
            after_off = []
            after_on = []
            for _ in range(window):
                item = off_reader.next_record()
                if item is None:
                    break
                after_off.append(item)
            for _ in range(window):
                item = on_reader.next_record()
                if item is None:
                    break
                after_on.append(item)
            category, reason = classify_mismatch(
                off_record, on_record, before_off, before_on,
                after_off, after_on)
            return {
                "status": "mismatch",
                "category": category,
                "records_compared": compared,
                "first_mismatch": {
                    "off_index": off_index,
                    "on_index": on_index,
                    "off": off_record,
                    "on": on_record,
                    "reason": reason,
                },
                "windows": {"before": {"off": list(before_off),
                                         "on": list(before_on)},
                            "after": {"off": after_off, "on": after_on}},
            }
        before_off.append(off_record)
        before_on.append(on_record)
        compared += 1


def parse_params(header):
    params = header.get("params", "")
    if isinstance(params, dict):
        return params
    if not params:
        return {}
    try:
        value = json.loads(params)
        return value if isinstance(value, dict) else {"_raw": params}
    except (TypeError, json.JSONDecodeError):
        return {"_raw": params}


def provenance(off_header, on_header):
    keys = ["schema", "name", "image_sha256", "source_sha256",
            "measurement_source_sha", "max_cycles"]
    equal = {key: off_header.get(key) == on_header.get(key) for key in keys}
    off_params = parse_params(off_header)
    on_params = parse_params(on_header)
    equal["params_except_fifo"] = (
        {k: v for k, v in off_params.items()
         if k not in {"FETCH_FIFO_ENABLE", "FIFO_VARIANT"}} ==
        {k: v for k, v in on_params.items()
         if k not in {"FETCH_FIFO_ENABLE", "FIFO_VARIANT"}})
    return {
        "off": {**{key: off_header.get(key) for key in keys},
                "params": off_params,
                "config": off_params.get("BASE_CONFIG")},
        "on": {**{key: on_header.get(key) for key in keys},
               "params": on_params,
               "config": on_params.get("BASE_CONFIG")},
        "equal": equal,
        "same_source_and_image": (equal["source_sha256"] and
                                   equal["image_sha256"] and
                                   equal["measurement_source_sha"]),
    }


def _insn_value(value):
    if isinstance(value, int):
        return value
    try:
        return int(str(value), 0)
    except (TypeError, ValueError):
        return None


def disassemble(image, pc, insn, base=0x44000000):
    """Return one objdump line when available, with a deterministic fallback."""
    insn_value = _insn_value(insn)
    pc_value = _insn_value(pc)
    fallback = (f".inst {insn}" if insn is not None else "unknown")
    if not image or pc_value is None or not os.path.isfile(image):
        return fallback
    tool = shutil.which("aarch64-linux-gnu-objdump") or shutil.which("objdump")
    if not tool:
        return fallback
    try:
        proc = subprocess.run(
            [tool, "-D", "-b", "binary", "-m", "aarch64",
             f"--adjust-vma=0x{base:x}", image],
            capture_output=True, text=True, check=False,
        )
    except OSError:
        return fallback
    wanted = f"{pc_value:x}:"
    for line in proc.stdout.splitlines():
        if line.strip().startswith(wanted):
            return line.strip()
    # Keep the raw encoding visible even if the selected objdump has a
    # different address width/format.
    return fallback if insn_value is None else f".inst 0x{insn_value:08x}"


def read_footer(path, label):
    """Read only the footer in a second streaming pass after early mismatch."""
    with open(path, "r", encoding="utf-8") as stream:
        for line in stream:
            if not line.strip():
                continue
            item = json.loads(line)
            if item.get("kind") == "footer":
                return item
    raise ValueError(f"{label}: missing footer")


def compare_files(off_path, on_path, window=4, base=0x44000000):
    with open(off_path, "r", encoding="utf-8") as off_stream, \
            open(on_path, "r", encoding="utf-8") as on_stream:
        off_reader = TraceReader(off_stream, "off")
        on_reader = TraceReader(on_stream, "on")
        result = compare_readers(off_reader, on_reader, window)
        first = result.get("first_mismatch")
        if first and first.get("off") and first.get("on"):
            image = off_reader.header.get("image") or on_reader.header.get("image")
            first["disassembly"] = {
                "off": disassemble(image, first["off"].get("pc"),
                                   first["off"].get("insn"), base),
                "on": disassemble(image, first["on"].get("pc"),
                                   first["on"].get("insn"), base),
            }
        result["headers"] = {"off": off_reader.header, "on": on_reader.header}
        result["provenance"] = provenance(off_reader.header, on_reader.header)
    result["footers"] = {"off": read_footer(off_path, "off"),
                          "on": read_footer(on_path, "on")}
    result["trace_sha256"] = {"off": sha256_file(off_path),
                               "on": sha256_file(on_path)}
    result["trace_paths"] = {"off": os.path.abspath(off_path),
                              "on": os.path.abspath(on_path)}
    return result


def _fixture_header():
    return json.dumps({
        "kind": "header", "schema": "lcvex-commit-trace-v1",
        "name": "fixture", "image_sha256": "image", "source_sha256": "source",
        "measurement_source_sha": "source-commit", "max_cycles": 10,
        "params": "{\"FETCH_FIFO_ENABLE\":\"0\"}",
    })


def _fixture_record(seq, pc, insn="0xd503201f", effects=None):
    return {
        "kind": "commit", "seq": seq, "cycle": seq * 3,
        "pc": f"0x{pc:016x}", "insn": insn,
        "next_pc": f"0x{pc + 4:016x}", "effects": effects or {},
        "fetch": {"epoch": 0, "occupancy": 0, "peak": 0,
                   "push": 0, "pop": 0, "flush": 0,
                   "stale_drain": 0, "stale_drop": 0},
    }


def _fixture_stream(records, footer=None):
    lines = [_fixture_header()]
    lines.extend(json.dumps(record, sort_keys=True) for record in records)
    lines.append(json.dumps(footer or {
        "kind": "footer", "status": "pass", "cycles": 99,
        "retired_insn": len(records), "commit_digest": "digest",
        "memory_digest": "memory",
    }))
    return io.StringIO("\n".join(lines) + "\n")


def self_test():
    r1 = _fixture_record(1, 0x44000000)
    r2 = _fixture_record(2, 0x44000004)
    r3 = _fixture_record(3, 0x44000008)

    cases = [
        ("equal", [r1, r2], [r1, r2], "equal"),
        ("duplicate", [r1, r2], [r1, r1, r2], "duplicate"),
        ("skip", [r1, r2, r3], [r1, r3], "skip"),
        ("effect", [r1, r2],
         [r1, _fixture_record(2, 0x44000004, effects={"gpr": {"rd": 1}})],
         "effect-mismatch"),
        ("wrong-path", [r1, r2], [r1, _fixture_record(2, 0x45000000)],
         "wrong-path"),
        ("termination", [r1], [r1, r2], "termination-boundary"),
    ]
    for name, off_records, on_records, expected in cases:
        off = TraceReader(_fixture_stream(off_records), f"{name}-off")
        on = TraceReader(_fixture_stream(on_records), f"{name}-on")
        result = compare_readers(off, on, window=2)
        if result["category"] != expected:
            raise AssertionError(f"{name}: expected {expected}, got {result}")
    print("commit trace comparator self-test: PASS (equal/duplicate/skip/effect/wrong-path/termination)")
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--off", help="FIFO-off JSONL trace")
    ap.add_argument("--on", help="FIFO-on JSONL trace")
    ap.add_argument("--out", default=None, help="write comparison JSON")
    ap.add_argument("--window", type=int, default=4,
                    help="records retained before/after first mismatch")
    ap.add_argument("--base", type=lambda value: int(value, 0),
                    default=0x44000000, help="raw image VMA for objdump")
    ap.add_argument("--self-test", action="store_true",
                    help="run in-memory comparator fixtures")
    args = ap.parse_args()

    if args.self_test:
        return self_test()
    if not args.off or not args.on:
        ap.error("--off and --on are required unless --self-test is used")
    if args.window < 0:
        ap.error("--window must be non-negative")
    try:
        result = compare_files(args.off, args.on, args.window, args.base)
    except (OSError, ValueError) as exc:
        result = {"status": "error", "category": "error", "error": str(exc),
                  "trace_paths": {"off": os.path.abspath(args.off),
                                  "on": os.path.abspath(args.on)}}
    text = json.dumps(result, indent=2, ensure_ascii=False)
    if args.out:
        out_path = args.out if os.path.isabs(args.out) else os.path.join(REPO, args.out)
        os.makedirs(os.path.dirname(os.path.abspath(out_path)), exist_ok=True)
        with open(out_path, "w", encoding="utf-8") as f:
            f.write(text + "\n")
    print(text)
    return 0 if result.get("status") == "equal" else (1 if result.get("status") == "mismatch" else 2)


if __name__ == "__main__":
    sys.exit(main())
