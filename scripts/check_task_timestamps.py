#!/usr/bin/env python3
"""Check task/evidence timestamp monotonicity and future-time rules.

This is the repository-side checker for EXT-01-002 / AUD-09.

It enforces:
  1. Event times (sent_at/received_at/reported_at/run_*_at/merged_at/...)
     must not be later than now.
  2. Event times recorded in a committed JSON must not be later than the Git
     commit that carries that line (using git blame).
  3. review >= dispatch, run >= dispatch, and other simple monotonic chains.
  4. Old values inside `correction_record` (or keys beginning with `old_`) are
     preserved historical facts and are intentionally not checked as live
     event/ledger timestamps.

Ledger/backfill times (created_at/updated_at/recorded_at/...) are reported as
warnings when they are later than the carrying commit; historical archive files
may contain many such pre-AUD-09 records, so they are not fatal by default.

Usage:
  python3 scripts/check_task_timestamps.py [--scope live|all] [--exit-code] [--json]
"""

from __future__ import annotations

import argparse
import datetime as dt
import glob
import json
import re
import subprocess
import sys
from collections import defaultdict, deque
from pathlib import Path

try:
    from zoneinfo import ZoneInfo
    TZ = ZoneInfo("Asia/Shanghai")
except Exception:
    TZ = dt.timezone(dt.timedelta(hours=8))

REPO = Path(__file__).resolve().parents[1]

EVENT_KEYS = {
    "event_at",
    "sent_at",
    "received_at",
    "reported_at",
    "run_at",
    "started_at",
    "finished_at",
    "ended_at",
    "observed_at",
    "observed_hang_at",
    "killed_at",
    "oom_serv_req_at",
    "merged_at",
    "reviewed_at",
    "integrated_at",
    "finalized_at",
    "captured_at",
}

LEDGER_KEYS = {
    "created_at",
    "updated_at",
    "recorded_at",
    "archived_at",
    "documents_written_at",
}

ALL_TIMESTAMP_KEYS = EVENT_KEYS | LEDGER_KEYS


def now_local() -> dt.datetime:
    return dt.datetime.now(TZ)


def parse_timestamp(value: str) -> dt.datetime | None:
    if not isinstance(value, str):
        return None
    s = value.strip()
    if not s or "~" in s or ".." in s:
        # Range/approximate values are not machine-checkable.
        return None
    s = s.replace("Z", "+00:00")
    # Normalize +0800 / +08:00.
    m = re.match(
        r"^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})(?:\.\d+)?([+-]\d{2}:?\d{2})$",
        s,
    )
    if m:
        tz = m.group(2).replace(":", "")
        return dt.datetime.strptime(m.group(1) + tz, "%Y-%m-%dT%H:%M:%S%z")
    try:
        return dt.datetime.fromisoformat(s)
    except ValueError:
        return None


def is_timestamp_key(key: str) -> bool:
    return key in ALL_TIMESTAMP_KEYS or key.endswith(("_at", "_time"))


def field_kind(leaf: str) -> str:
    if leaf in EVENT_KEYS or (leaf.endswith("_at") and leaf not in LEDGER_KEYS):
        return "event"
    if leaf in LEDGER_KEYS:
        return "ledger"
    return "other"


def collect_timestamps(obj, path: str = "", out: list | None = None) -> list:
    """Yield (path, leaf, value) in document order."""
    if out is None:
        out = []
    if isinstance(obj, dict):
        for k, v in obj.items():
            new_path = f"{path}.{k}" if path else k
            collect_timestamps(v, new_path, out)
    elif isinstance(obj, list):
        for i, v in enumerate(obj):
            collect_timestamps(v, f"{path}[{i}]", out)
    elif isinstance(obj, str) and is_timestamp_key(path.rsplit(".", 1)[-1]):
        leaf = path.rsplit(".", 1)[-1]
        # Correction records intentionally preserve old/historical values.
        # Do not treat those as live event/ledger timestamps.
        if path.startswith("correction_record") or leaf.startswith("old_"):
            return out
        out.append((path, leaf, obj))
    return out


def build_line_map(text: str) -> dict[str, deque[int]]:
    lines = text.splitlines()
    mapping: dict[str, deque[int]] = defaultdict(deque)
    pat = re.compile(r'"([A-Za-z0-9_]+)"\s*:\s*"([^"]*)"')
    for lineno, line in enumerate(lines, 1):
        m = pat.search(line)
        if not m:
            continue
        key = m.group(1)
        if is_timestamp_key(key):
            mapping[key].append(lineno)
    return mapping


def git_commit_time(repo: Path, path: str, line: int | None = None) -> dt.datetime | None:
    """Return commit time of the line (or last file commit) if available."""
    if line is not None:
        cmd = ["git", "blame", "--line-porcelain", "-L", f"{line},{line}", "--", path]
    else:
        cmd = ["git", "log", "-1", "--format=%cI", "--", path]
    proc = subprocess.run(cmd, cwd=repo, capture_output=True, text=True)
    if proc.returncode != 0 or not proc.stdout.strip():
        return None
    first = proc.stdout.split("\n", 1)[0]
    sha = first.split()[0].lstrip("^")
    if sha == "0000000000000000000000000000000000000000" or len(sha) != 40:
        return None
    r = subprocess.run(
        ["git", "show", "-s", "--format=%cI", sha],
        cwd=repo,
        capture_output=True,
        text=True,
    )
    if r.returncode != 0 or not r.stdout.strip():
        return None
    return parse_timestamp(r.stdout.strip())


def load_task(path: Path) -> dict:
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def read_task_tasks(scope: str) -> list[Path]:
    paths = []
    if scope in ("live", "all"):
        paths += sorted(glob.glob(str(REPO / "docs/tasks/proposed/*.json")))
        paths += sorted(glob.glob(str(REPO / "docs/tasks/active/*.json")))
    if scope == "all":
        paths += sorted(glob.glob(str(REPO / "docs/tasks/archive/*.json")))
    return [Path(p) for p in paths]


def read_evidence(scope: str) -> list[Path]:
    """Return evidence in scope.

    For ``live`` only evidence belonging to proposed/active task IDs is
    checked; archived task evidence is only included in ``all``.  This keeps
    historical archive records out of the live residual count while preserving
    them for full audits.
    """
    all_paths = sorted(Path(p) for p in glob.glob(str(REPO / "docs/tasks/evidence/*.json")))
    if scope == "all":
        return all_paths
    live_ids: set[str] = set()
    for tp in read_task_tasks("live"):
        try:
            d = load_task(tp)
        except Exception:
            continue
        tid = d.get("id")
        if tid:
            live_ids.add(tid)
    result = []
    for p in all_paths:
        try:
            d = json.loads(p.read_text(encoding="utf-8"))
        except Exception:
            # Keep unreadable evidence in live so it is reported as a parse error.
            result.append(p)
            continue
        tid = d.get("task_id") or d.get("id") or p.stem
        if tid in live_ids:
            result.append(p)
    return result


def check_file(path: Path, all_tasks: dict[str, dict]) -> list[dict]:
    issues: list[dict] = []
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except Exception as exc:
        return [{
            "severity": "error",
            "file": str(path.relative_to(REPO)),
            "path": "$",
            "message": f"JSON parse error: {exc}",
        }]

    text = path.read_text(encoding="utf-8")
    line_map = build_line_map(text)
    timestamps = collect_timestamps(data)
    # Assign line numbers in document order. For repeated leaves, consume in order.
    line_iter = {k: iter(v) for k, v in line_map.items()}

    now = now_local()
    for path_key, leaf, value in timestamps:
        parsed = parse_timestamp(value)
        if parsed is None:
            continue
        kind = field_kind(leaf)
        line = next(line_iter[leaf], None) if leaf in line_iter else None
        commit_time = None
        if line is not None:
            commit_time = git_commit_time(REPO, str(path.relative_to(REPO)), line)
        context = {
            "file": str(path.relative_to(REPO)),
            "path": path_key,
            "value": value,
            "kind": kind,
        }

        if parsed > now:
            issues.append({
                **context,
                "severity": "error" if kind == "event" else "warning",
                "message": f"{kind} timestamp is in the future ({parsed.isoformat()} > now {now.isoformat()})",
            })

        if kind == "event" and commit_time is not None and parsed > commit_time:
            issues.append({
                **context,
                "severity": "error",
                "message": (
                    f"event timestamp later than carrying Git commit "
                    f"({parsed.isoformat()} > {commit_time.isoformat()})"
                ),
            })
        if kind == "ledger" and commit_time is not None and parsed > commit_time:
            issues.append({
                **context,
                "severity": "warning",
                "message": (
                    f"ledger/backfill timestamp later than carrying Git commit "
                    f"({parsed.isoformat()} > {commit_time.isoformat()}); "
                    f"pre-AUD-09 historical data may need correction record"
                ),
            })

    # Task-level monotonic checks.
    task_id = data.get("id") or data.get("task_id")
    dispatch = (data.get("dispatch") or {}).get("sent_at") if isinstance(data.get("dispatch"), dict) else None
    review = (data.get("integrator_review") or {}).get("received_at") if isinstance(data.get("integrator_review"), dict) else None
    merged = data.get("merged_at")
    created = data.get("created_at")
    updated = data.get("updated_at")
    reported = data.get("reported_at")
    received = data.get("received_at")
    sent = data.get("sent_at")

    def p(s):
        return parse_timestamp(s) if s else None

    d, rv, mg, cr, up, rp, rc, st = p(dispatch), p(review), p(merged), p(created), p(updated), p(reported), p(received), p(sent)

    def add_mono(sev, msg):
        if task_id:
            issues.append({"file": str(path.relative_to(REPO)), "path": "monotonic", "task_id": task_id, "severity": sev, "message": msg})

    if d and rv and rv < d:
        add_mono("error", f"integrator_review.received_at ({rv.isoformat()}) < dispatch.sent_at ({d.isoformat()})")
    if d and mg and mg < d:
        add_mono("error", f"merged_at ({mg.isoformat()}) < dispatch.sent_at ({d.isoformat()})")
    if cr and up and up < cr:
        add_mono("error", f"updated_at ({up.isoformat()}) < created_at ({cr.isoformat()})")
    if st and rc and rc < st:
        add_mono("error", f"received_at ({rc.isoformat()}) < sent_at ({st.isoformat()})")
    if rc and rp and rp < rc:
        add_mono("error", f"reported_at ({rp.isoformat()}) < received_at ({rc.isoformat()})")
    if st and rp and rp < st:
        add_mono("error", f"reported_at ({rp.isoformat()}) < sent_at ({st.isoformat()})")

    # Evidence per-run monotonic and cross-check against active/archive dispatch.
    if task_id and task_id in all_tasks:
        task_dispatch = p((all_tasks[task_id].get("dispatch") or {}).get("sent_at"))
        if task_dispatch:
            if rp and rp < task_dispatch:
                add_mono("error", f"evidence reported_at ({rp.isoformat()}) < task dispatch.sent_at ({task_dispatch.isoformat()})")
            if rc and rc < task_dispatch:
                add_mono("error", f"evidence received_at ({rc.isoformat()}) < task dispatch.sent_at ({task_dispatch.isoformat()})")
        runs = data.get("runs") or []
        if isinstance(runs, list):
            for idx, run in enumerate(runs):
                if not isinstance(run, dict):
                    continue
                rs = p(run.get("started_at") or run.get("started"))
                rf = p(run.get("finished_at") or run.get("finished") or run.get("ended_at"))
                if rs and rf and rf < rs:
                    add_mono("error", f"runs[{idx}].finished_at < started_at")
                if task_dispatch and rs and rs < task_dispatch:
                    add_mono("error", f"runs[{idx}].started_at ({rs.isoformat()}) < task dispatch.sent_at ({task_dispatch.isoformat()})")
                # Also check any *_at inside run against dispatch.
                for run_path, run_leaf, run_val in collect_timestamps(run, path=f"runs[{idx}]"):
                    rt = parse_timestamp(run_val)
                    if rt and task_dispatch and rt < task_dispatch and field_kind(run_leaf) == "event":
                        add_mono("error", f"{run_path} ({rt.isoformat()}) < task dispatch.sent_at ({task_dispatch.isoformat()})")

    return issues


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--scope", choices=["live", "all"], default="live")
    ap.add_argument("--exit-code", action="store_true", help="exit 1 if any error found")
    ap.add_argument("--json", action="store_true", help="print JSON array of issues")
    args = ap.parse_args()

    task_paths = read_task_tasks(args.scope)
    evidence_paths = read_evidence(args.scope)
    all_tasks: dict[str, dict] = {}
    for tp in task_paths:
        try:
            data = load_task(tp)
        except Exception:
            continue
        tid = data.get("id")
        if tid:
            all_tasks[tid] = data

    all_issues: list[dict] = []
    for path in task_paths + evidence_paths:
        all_issues.extend(check_file(path, all_tasks))

    if args.json:
        print(json.dumps(all_issues, ensure_ascii=False, indent=2))
    else:
        if not all_issues:
            print(f"OK: no timestamp issues found in scope={args.scope}")
            return 0
        errors = [i for i in all_issues if i.get("severity") == "error"]
        warnings = [i for i in all_issues if i.get("severity") == "warning"]
        print(f"timestamp check found {len(errors)} error(s), {len(warnings)} warning(s)")
        for i in all_issues:
            sev = i.get("severity", "?")
            loc = i.get("file", "")
            path = i.get("path", "")
            msg = i.get("message", "")
            print(f"[{sev}] {loc} {path}: {msg}")

    if args.exit_code and any(i.get("severity") == "error" for i in all_issues):
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
