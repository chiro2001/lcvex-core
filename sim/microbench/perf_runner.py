#!/usr/bin/env python3
"""LCVEX perf JSON runner.

封装现有 Verilator microbench_runner，运行单个 perf/baremetal 镜像并输出
可重复的 JSON 报告：

    {
      "name": "...",
      "git_sha": "...",
      "source_sha256": "...",
      "image_sha256": "...",
      "cycles": ...,
      "wall_sec": ...,
      "rss_kb": ...,
      "rss": ...,
      "status": "pass|fail|timeout|error",
      "params": ...,
      ...
    }

用法示例：
    python3 sim/microbench/perf_runner.py \
        --runner build/microbench_runner/microbench_runner \
        --image build/microbench/perf_smoke.bin --name smoke --param iters=1000
"""

import argparse
import hashlib
import json
import os
import resource
import subprocess
import sys
import time

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
COMMIT_DIGEST_SCHEMA = "lcvex-commit-digest-v2-active-payload"
EVENT_PROBE_SCHEMA = "lcvex-f1a-d2-event-v2-stale-context"
EVENT_PROBE_WINDOW_LIMIT = 128


def sha256_file(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def git_sha() -> str:
    try:
        out = subprocess.run(
            ["git", "-C", REPO, "rev-parse", "HEAD"],
            capture_output=True, text=True, check=True,
        )
        return out.stdout.strip()
    except Exception:
        return "unknown"


def toolchain_version() -> str:
    for cc in ("aarch64-linux-gnu-gcc", "gcc"):
        try:
            out = subprocess.run([cc, "--version"], capture_output=True,
                                 text=True, check=True)
            return out.stdout.splitlines()[0].strip()
        except Exception:
            continue
    return "unknown"


def source_sha(name: str) -> str:
    """Hash the reproducible inputs of a single perf image.

    The list includes the workload C file plus the shared build/runtime sources
    that determine the generated baremetal binary.
    """
    base = name[2:] if name.startswith("t_") else name
    base = base[:-2] if base.endswith(".c") else base
    rels = [
        f"baremetal/perf/t_{base}.c",
        "baremetal/perf/perf_common.h",
        "baremetal/tests.h",
        "baremetal/microbench_main.c",
        "baremetal/startup_mb.s",
        "baremetal/link.ld",
        "scripts/build-microbench.sh",
        "Makefile",
        "sim/microbench/commit_digest.h",
        "sim/microbench/microbench_runner.cc",
        "sim/microbench/perf_runner.py",
    ]
    h = hashlib.sha256()
    for rel in sorted(rels):
        path = os.path.join(REPO, rel)
        if os.path.isfile(path):
            h.update(rel.encode("utf-8"))
            h.update(b"\0")
            with open(path, "rb") as f:
                h.update(f.read())
            h.update(b"\0")
    return h.hexdigest()


def parse_runner_output(text: str, name: str):
    """Return (status, cycles, rc) from the existing runner's human output."""
    status, cycles, rc = "error", None, None
    for line in text.splitlines():
        line = line.strip()
        # PASS: name (123 cycles)
        if line.startswith("PASS:"):
            status = "pass"
            if "(" in line and "cycles" in line:
                try:
                    cycles = int(line.split("(")[1].split()[0])
                except Exception:
                    cycles = None
            rc = 0
        # FAIL: name (rc=4, 123 cycles)  OR  FAIL: name (timeout ... cycles)
        elif line.startswith("FAIL:"):
            status = "fail"
            if "timeout" in line:
                status = "timeout"
            if "cycles" in line:
                try:
                    cycles = int(line.split("cycles")[0].split()[-1].rstrip("(),"))
                except Exception:
                    cycles = None
            if "rc=" in line:
                try:
                    rc = int(line.split("rc=")[1].split(",")[0])
                except Exception:
                    rc = None
    return status, cycles, rc


def probe_self_test() -> int:
    """Check the opt-in probe contract without starting a simulator."""
    sample = {
        "schema": EVENT_PROBE_SCHEMA,
        "event_window_limit": EVENT_PROBE_WINDOW_LIMIT,
        "event_window_truncated": False,
        "tracking_truncated": False,
        "aggregate": {
            "kill": 3,
            "kill_with_stale_context": 1,
            "kill_without_stale_context": 2,
            "kill_partition_valid": True,
            "imem_reissue_after_stale_kill": 1,
            "unresolved_stale_context_windows": 0,
        },
        "event_window": [{"kind": "frontend_kill", "cycle": 7}],
    }
    encoded = json.dumps(sample, separators=(",", ":"), ensure_ascii=False)
    decoded = json.loads(encoded)
    assert decoded["schema"] == EVENT_PROBE_SCHEMA
    assert decoded["event_window_limit"] == EVENT_PROBE_WINDOW_LIMIT
    assert len(decoded["event_window"]) <= EVENT_PROBE_WINDOW_LIMIT
    aggregate = decoded["aggregate"]
    assert aggregate["kill"] == (
        aggregate["kill_with_stale_context"] +
        aggregate["kill_without_stale_context"]
    )
    assert aggregate["kill_partition_valid"] is True
    assert aggregate["kill_without_stale_context"] > 0
    assert aggregate["imem_reissue_after_stale_kill"] <= aggregate[
        "kill_with_stale_context"]
    assert aggregate["unresolved_stale_context_windows"] == 0

    # A kill with no outstanding fetch response is deliberately outside the
    # stale-context window.  It must not create tracking, unresolved state, or
    # a post-kill IMEM reissue on its own.
    no_stale_context = {
        "aggregate": {
            "kill": 4,
            "kill_with_stale_context": 0,
            "kill_without_stale_context": 4,
            "kill_partition_valid": True,
            "imem_reissue_after_stale_kill": 0,
            "unresolved_stale_context_windows": 0,
        }
    }
    no_stale_aggregate = no_stale_context["aggregate"]
    assert no_stale_aggregate["kill"] == (
        no_stale_aggregate["kill_with_stale_context"] +
        no_stale_aggregate["kill_without_stale_context"]
    )
    assert no_stale_aggregate["kill_with_stale_context"] == 0
    assert no_stale_aggregate["imem_reissue_after_stale_kill"] == 0
    assert no_stale_aggregate["unresolved_stale_context_windows"] == 0

    # Every bounded store has an explicit truncation bit.  The aggregate
    # `truncated` bit is the OR of event-window and stale-window tracking caps.
    decoded["event_window"] = list(range(EVENT_PROBE_WINDOW_LIMIT))
    decoded["event_window_truncated"] = True
    decoded["truncated"] = True
    assert len(decoded["event_window"]) == EVENT_PROBE_WINDOW_LIMIT
    assert decoded["event_window_truncated"] is True
    decoded["tracking_truncated"] = True
    assert decoded["tracking_truncated"] is True
    assert decoded["truncated"] is True
    # A default (no --probe) report must not acquire a probe field.
    legacy = {"cycles": 1, "status": "pass"}
    assert "probe" not in legacy
    print("PASS: F1a event probe schema/record limit/default-off self-test")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--image", required=False, help="perf baremetal .bin")
    ap.add_argument("--name", default=None, help="workload name (default from image)")
    ap.add_argument("--runner", default="build/microbench_runner/microbench_runner",
                    help="Verilator microbench runner executable")
    ap.add_argument("--max-cycles", type=int, default=5000000)
    ap.add_argument("--params", default="", help="free-form params string")
    ap.add_argument("--param", action="append", default=[], metavar="KEY=VALUE",
                    help="repeatable structured param; builds params object")
    ap.add_argument("--git-sha", default=None, help="override git SHA")
    ap.add_argument("--measurement-source-sha", default=None,
                    help="source commit used for the off/on measurement")
    ap.add_argument("--source-sha", default=None, help="override source SHA256")
    ap.add_argument("--trace", default=None,
                    help="opt-in JSONL commit trace output path")
    ap.add_argument("--probe", default=None,
                    help="opt-in bounded F1a event probe output path")
    ap.add_argument("--probe-self-test", action="store_true",
                    help=argparse.SUPPRESS)
    ap.add_argument("--out", default=None, help="write JSON report to this file")
    ap.add_argument("--pretty", action="store_true", default=True)
    ap.add_argument("--json", action="store_true", help=argparse.SUPPRESS)
    args = ap.parse_args()

    if args.probe_self_test:
        return probe_self_test()
    if not args.image:
        ap.error("--image is required unless --probe-self-test is used")

    name = args.name or os.path.basename(args.image)
    if name.startswith("perf_"):
        name = name[len("perf_"):]
    if name.endswith(".bin"):
        name = name[:-4]

    runner = args.runner
    if not os.path.isabs(runner):
        runner = os.path.join(REPO, runner)

    image = args.image
    if not os.path.isabs(image):
        image = os.path.join(REPO, image)

    trace = args.trace
    if trace and not os.path.isabs(trace):
        trace = os.path.join(REPO, trace)

    probe = args.probe
    if probe and not os.path.isabs(probe):
        probe = os.path.join(REPO, probe)

    if not os.path.isfile(image):
        print(json.dumps({
            "name": name, "status": "error",
            "error": f"image not found: {image}",
        }, indent=2), file=sys.stderr)
        return 2

    params = args.params
    if args.param:
        pd = {}
        for item in args.param:
            if "=" in item:
                k, v = item.split("=", 1)
                pd[k] = v
            else:
                pd[item] = True
        params = pd

    # Freeze provenance before invoking the runner. The matrix driver passes
    # the clean measurement commit explicitly; direct legacy callers continue
    # to resolve HEAD as before.
    measurement_source_sha = (args.measurement_source_sha or args.git_sha or
                               git_sha())
    git = measurement_source_sha
    source_hash = args.source_sha or source_sha(name)
    if isinstance(params, dict):
        runner_params = json.dumps(params, sort_keys=True,
                                   separators=(",", ":"))
    else:
        runner_params = params

    # Ask the runner for its structured JSON (includes F0 counters when built
    # from the current microbench_runner.cc).
    cmd = [runner, "--image", image, "--name", name,
           "--max-cycles", str(args.max_cycles), "--json",
           "--git-sha", measurement_source_sha,
           "--source-sha", source_hash]
    if runner_params:
        cmd.extend(["--params", runner_params])
    if trace:
        os.makedirs(os.path.dirname(os.path.abspath(trace)), exist_ok=True)
        cmd.extend(["--trace", trace])
    if probe:
        os.makedirs(os.path.dirname(os.path.abspath(probe)), exist_ok=True)
        cmd.extend(["--probe", probe])
    start = time.monotonic()
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True)
    except FileNotFoundError:
        print(json.dumps({
            "name": name, "status": "error",
            "error": f"runner not found: {runner}",
            "command": cmd,
        }, indent=2), file=sys.stderr)
        return 2
    wall_sec = time.monotonic() - start

    ru = resource.getrusage(resource.RUSAGE_CHILDREN)
    rss_kb = int(ru.ru_maxrss) if ru.ru_maxrss else 0

    output = proc.stdout or ""
    status, cycles, rc = parse_runner_output(output, name)
    # The current runner emits a JSON object; use it directly when available.
    runner_json = None
    try:
        runner_json = json.loads(output)
    except Exception:
        runner_json = None

    image_hash = sha256_file(image)

    if runner_json is not None:
        report = dict(runner_json)
        digest_schema = runner_json.get("commit_digest_schema")
        digest_valid = runner_json.get("commit_digest_valid", False)
        report["name"] = name
        report["sha"] = git
        report["git_sha"] = git
        report["measurement_source_sha"] = measurement_source_sha
        report["source_hash"] = source_hash
        report["source_sha256"] = source_hash
        report["image_hash"] = image_hash
        report["image_sha256"] = image_hash
        report["toolchain"] = toolchain_version()
        report["wall_sec"] = round(wall_sec, 6)
        report["rss_kb"] = rss_kb
        report["rss"] = round(rss_kb / 1024.0, 3)
        report["status"] = runner_json.get("status", status)
        report["params"] = params
        report["runner"] = runner
        report["command"] = cmd
        report["max_cycles"] = args.max_cycles
        report["returncode"] = proc.returncode
        report["rc"] = runner_json.get("returncode", rc)
        report["commit_digest_schema"] = digest_schema
        report["commit_digest_valid"] = digest_valid
        if digest_schema != COMMIT_DIGEST_SCHEMA or digest_valid is not True:
            report["status"] = "error"
            report["returncode"] = 2
            report["rc"] = 2
            report["error"] = (
                "invalid commit digest contract: expected schema "
                f"{COMMIT_DIGEST_SCHEMA!r} and valid=true, got "
                f"schema={digest_schema!r}, valid={digest_valid!r}"
            )
        report["runner_stdout"] = output
        report["runner_stderr"] = proc.stderr
        if trace:
            report["trace_path"] = trace
        if probe:
            report["probe_path"] = probe
        # Keep the full structured metrics emitted by the runner (retired_insn,
        # ipc, stall_cycles, requests, responses, cache).
    else:
        # Older binaries without the v2 structured digest contract are not
        # comparable to a v2 result.  Keep the report explicit rather than
        # silently treating a legacy v1 summary as a v2 pair.
        status = "error"
        error = "runner did not emit the v2 structured digest contract"
        report = {
            "name": name,
            "sha": git,
            "git_sha": git,
            "measurement_source_sha": measurement_source_sha,
            "source_hash": source_hash,
            "source_sha256": source_hash,
            "image_hash": image_hash,
            "image_sha256": image_hash,
            "toolchain": toolchain_version(),
            "cycles": cycles,
            "wall_sec": round(wall_sec, 6),
            "rss_kb": rss_kb,
            "rss": round(rss_kb / 1024.0, 3),
            "status": status,
            "error": error,
            "params": params,
            "runner": runner,
            "command": cmd,
            "max_cycles": args.max_cycles,
            "returncode": 2,
            "rc": 2,
            "commit_digest_schema": None,
            "commit_digest_valid": False,
            "runner_stdout": output,
            "runner_stderr": proc.stderr,
        }
        if trace:
            report["trace_path"] = trace
        if probe:
            report["probe_path"] = probe

    text = json.dumps(report, indent=2, ensure_ascii=False)
    if args.out:
        os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
        with open(args.out, "w", encoding="utf-8") as f:
            f.write(text + "\n")
    print(text)

    status = report.get("status", status)
    return 0 if status == "pass" else (1 if status in ("fail", "timeout") else 2)


if __name__ == "__main__":
    sys.exit(main())
