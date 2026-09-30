#!/usr/bin/env python3
"""Export the exact B25 physical waiver inventory from TimeQuest artifacts.

This tool is intentionally a report parser, not a Quartus interface.  It
consumes the machine-readable ``t007_summary.tsv`` produced by T-007, two raw
``report_ucp`` reports (fast/slow), and four raw ``report_timing`` reports
(fast/slow recovery/removal).  Counts, path-group cardinalities, witness
hierarchies, and worst-case slack are derived from those files.  The exporter
does not accept an observed value on the command line and refuses to emit an
inventory when provenance, report rows, or the T-010 contract disagree.

Example::

    python3 fpga/catapult_a10/tools/export_physical_waiver_inventory.py \
      --policy fpga/catapult_a10/physical_waivers.json \
      --summary build/agents/T-007/runtime/remote_final5/t007_summary.tsv \
      --ucp-fast build/agents/T-007/runtime/remote_final5/t007_fast_unconstrained_paths.rpt \
      --ucp-slow build/agents/T-007/runtime/remote_final5/t007_slow_unconstrained_paths.rpt \
      --fast-recovery build/agents/T-007/runtime/remote_final5/t007_fast_emif_reset_to_adapter_recovery.rpt \
      --fast-removal build/agents/T-007/runtime/remote_final5/t007_fast_emif_reset_to_adapter_removal.rpt \
      --slow-recovery build/agents/T-007/runtime/remote_final5/t007_slow_emif_reset_to_adapter_recovery.rpt \
      --slow-removal build/agents/T-007/runtime/remote_final5/t007_slow_emif_reset_to_adapter_removal.rpt \
      --output build/agents/T-20260909-012/ucp_inventory.json

Only Python's standard library is used.  No QDB, Quartus, network, or DUT
access occurs.
"""

from __future__ import annotations

import argparse
import fnmatch
import json
import math
import re
import sys
from collections import Counter
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable, Sequence


FROZEN_SOURCE_TASK = "T-20260909-007"
FROZEN_SOURCE_SHA = "702bd8ee5295efe8a2ad9e094d6c12471a1d3089"
ACCEPTED_SUMMARY_TASKS = {FROZEN_SOURCE_TASK, "T-20260909-011"}
EXPORTER_NAME = "quartus_sta_structured_inventory_v1"
SUMMARY_COLUMNS = "kind|model|label|value1|value2|value3|value4"
SUMMARY_KINDS = {
    "collection",
    "done",
    "fanin",
    "fanin_edge",
    "generated_sdc",
    "info",
    "netlist",
    "node",
    "path",
    "path_detail",
    "path_iter",
    "paths",
    "port_fanin",
    "port_fanout",
    "report",
    "reset_report",
    "reset_target_inventory",
    "fanout_edge",
    "fanout_edges",
}
SUMMARY_HEADER_KEYS = {
    "task",
    "label",
    "fitted_source_sha",
    "report_only",
    "synthesis_rerun",
    "fitter_rerun",
    "assembler",
    "columns",
}
SUMMARY_LABEL = "B25-UNCONSTRAINED-CLOCK-AUDIT"
HEX40 = re.compile(r"^[0-9a-fA-F]{40}$")
NUMBER_BODY = r"[+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?"
NUMBER = re.compile(r"^" + NUMBER_BODY + r"$")


class ExportError(RuntimeError):
    """A deterministic fail-closed input or contract error."""


def _unique_json_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"duplicate JSON key {key!r}")
        result[key] = value
    return result


def _read_text(path: Path, label: str) -> str:
    try:
        if not path.is_file():
            raise ExportError(f"{label} is not a regular file: {path}")
        return path.read_text(encoding="utf-8")
    except UnicodeDecodeError as exc:
        raise ExportError(f"{label} is not valid UTF-8: {path}: {exc}") from exc
    except OSError as exc:
        raise ExportError(f"cannot read {label} {path}: {exc}") from exc


def _read_json(path: Path, label: str) -> dict[str, Any]:
    try:
        value = json.loads(_read_text(path, label), object_pairs_hook=_unique_json_object)
    except (json.JSONDecodeError, ValueError) as exc:
        raise ExportError(f"{label} is malformed JSON: {exc}") from exc
    if not isinstance(value, dict):
        raise ExportError(f"{label} must contain a JSON object")
    return value


def _exact_keys(value: Any, expected: set[str], where: str) -> None:
    if not isinstance(value, dict):
        raise ExportError(f"{where} must be an object")
    actual = set(value)
    missing = sorted(expected - actual)
    extra = sorted(actual - expected)
    if missing or extra:
        detail: list[str] = []
        if missing:
            detail.append("missing=" + ",".join(missing))
        if extra:
            detail.append("extra=" + ",".join(extra))
        raise ExportError(f"{where} has unexpected keys ({'; '.join(detail)})")


def _number(value: str, where: str) -> float:
    if not NUMBER.fullmatch(value.strip()):
        raise ExportError(f"{where} is not a finite number: {value!r}")
    result = float(value)
    if not math.isfinite(result):
        raise ExportError(f"{where} is not finite: {value!r}")
    return result


def _integer(value: str, where: str) -> int:
    if not re.fullmatch(r"\d+", value.strip()):
        raise ExportError(f"{where} is not a non-negative integer: {value!r}")
    return int(value)


def _policy_contract(policy: dict[str, Any]) -> dict[str, Any]:
    """Validate the immutable T-010 policy and return its useful sections."""

    _exact_keys(
        policy,
        {
            "schema_version",
            "policy_id",
            "contract_source",
            "inventory_schema",
            "ucp",
            "jtag_hierarchy",
            "reset_control",
            "forbidden",
        },
        "policy",
    )
    if policy.get("schema_version") != 1 or policy.get("policy_id") != "B25-PHYSICAL-UCP-WAIVER":
        raise ExportError("policy identity is not the T-010 B25 contract")

    source = policy.get("contract_source")
    _exact_keys(source, {"task_id", "source_sha", "evidence"}, "policy.contract_source")
    if source.get("task_id") != FROZEN_SOURCE_TASK or source.get("source_sha") != FROZEN_SOURCE_SHA:
        raise ExportError("policy contract source is not the frozen T-007 physical source")
    if not isinstance(source.get("evidence"), str) or Path(source["evidence"]).is_absolute():
        raise ExportError("policy contract evidence must be a relative path")

    schema = policy.get("inventory_schema")
    _exact_keys(schema, {"kind", "required_top_level", "exceptions_exact"}, "policy.inventory_schema")
    expected_top = [
        "schema_version",
        "inventory_kind",
        "provenance",
        "ucp",
        "recovery_removal",
        "clock_constraints",
        "exceptions",
    ]
    if schema.get("kind") != "lcvex-physical-ucp-recovery-removal-v1":
        raise ExportError("policy inventory kind is not the T-010 inventory")
    if schema.get("required_top_level") != expected_top or schema.get("exceptions_exact") != []:
        raise ExportError("policy inventory schema is not the exact T-010 schema")

    ucp = policy.get("ucp")
    _exact_keys(ucp, {"summary", "clocks", "ports"}, "policy.ucp")
    summary = ucp.get("summary")
    expected_summary_keys = {
        "clock_count",
        "input_port_count",
        "input_path_count",
        "output_port_count",
        "output_path_count",
    }
    _exact_keys(summary, expected_summary_keys, "policy.ucp.summary")
    if not all(isinstance(value, int) and not isinstance(value, bool) and value >= 0 for value in summary.values()):
        raise ExportError("policy UCP summary contains a non-negative integer violation")

    clocks = ucp.get("clocks")
    if not isinstance(clocks, list) or not clocks:
        raise ExportError("policy.ucp.clocks must be a non-empty list")
    clock_names: set[str] = set()
    for index, clock in enumerate(clocks):
        _exact_keys(clock, {"name", "status", "kind"}, f"policy.ucp.clocks[{index}]")
        if not isinstance(clock.get("name"), str) or not clock["name"] or clock["name"] in clock_names:
            raise ExportError("policy UCP clocks contain an empty or duplicate name")
        clock_names.add(clock["name"])
        if clock.get("status") != "unconstrained" or not isinstance(clock.get("kind"), str):
            raise ExportError("policy UCP clock classification is not an unconstrained contract")

    ports = ucp.get("ports")
    if not isinstance(ports, list) or not ports:
        raise ExportError("policy.ucp.ports must be a non-empty list")
    port_names: set[str] = set()
    for index, port in enumerate(ports):
        _exact_keys(
            port,
            {"name", "direction", "path_count", "path_groups"},
            f"policy.ucp.ports[{index}]",
        )
        name = port.get("name")
        if not isinstance(name, str) or not name or name in port_names:
            raise ExportError("policy UCP ports contain an empty or duplicate name")
        port_names.add(name)
        if port.get("direction") not in {"input", "output"}:
            raise ExportError(f"policy UCP port {name!r} has an invalid direction")
        if not isinstance(port.get("path_count"), int) or port["path_count"] < 0:
            raise ExportError(f"policy UCP port {name!r} has an invalid path count")
        groups = port.get("path_groups")
        if not isinstance(groups, dict) or not groups:
            raise ExportError(f"policy UCP port {name!r} has no path-group contract")
        for group_name, group in groups.items():
            if not isinstance(group_name, str) or not group:
                raise ExportError(f"policy UCP port {name!r} has an invalid path-group name")
            if not isinstance(group, int) or isinstance(group, bool) or group < 0:
                raise ExportError(f"policy path group {group_name!r} has an invalid count")

    hierarchy = policy.get("jtag_hierarchy")
    _exact_keys(
        hierarchy,
        {"allowed_classes", "forbid_arbitrary_tck_period", "forbid_jtag_create_clock"},
        "policy.jtag_hierarchy",
    )
    if hierarchy.get("forbid_arbitrary_tck_period") is not True or hierarchy.get("forbid_jtag_create_clock") is not True:
        raise ExportError("policy JTAG clock guards are weakened")
    classes = hierarchy.get("allowed_classes")
    if not isinstance(classes, list) or not classes:
        raise ExportError("policy.jtag_hierarchy.allowed_classes must be a non-empty list")
    class_names: set[str] = set()
    for index, item in enumerate(classes):
        _exact_keys(item, {"class", "pattern", "required"}, f"policy.jtag_hierarchy.allowed_classes[{index}]")
        if not isinstance(item.get("class"), str) or not item["class"] or item["class"] in class_names:
            raise ExportError("policy hierarchy classes contain an empty or duplicate name")
        class_names.add(item["class"])
        if not isinstance(item.get("pattern"), str) or not item["pattern"]:
            raise ExportError(f"policy hierarchy class {item['class']!r} has no pattern")
        if not isinstance(item.get("required"), bool):
            raise ExportError(f"policy hierarchy class {item['class']!r} has invalid required flag")

    reset = policy.get("reset_control")
    _exact_keys(
        reset,
        {"name", "kind", "corners", "checks", "forbid_false_path_fields"},
        "policy.reset_control",
    )
    if not isinstance(reset.get("name"), str) or not reset["name"] or not isinstance(reset.get("kind"), str):
        raise ExportError("policy reset control identity is invalid")
    if reset.get("corners") != ["fast", "slow"]:
        raise ExportError("policy reset corners are not exactly fast and slow")
    checks = reset.get("checks")
    _exact_keys(checks, {"recovery", "removal"}, "policy.reset_control.checks")
    for check_name in ("recovery", "removal"):
        check = checks[check_name]
        _exact_keys(
            check,
            {"path_count", "violated", "baseline_worst_slack_ns", "require_worst_slack_positive"},
            f"policy.reset_control.checks.{check_name}",
        )
        if (
            not isinstance(check.get("path_count"), int)
            or check["path_count"] <= 0
            or not isinstance(check.get("violated"), int)
            or check["violated"] < 0
            or not isinstance(check.get("baseline_worst_slack_ns"), (int, float))
            or not math.isfinite(float(check["baseline_worst_slack_ns"]))
            or check.get("require_worst_slack_positive") is not True
        ):
            raise ExportError(f"policy reset {check_name} contract is invalid")
    if reset.get("forbid_false_path_fields") is not True:
        raise ExportError("policy reset false-path guard is weakened")

    forbidden = policy.get("forbidden")
    _exact_keys(forbidden, {"reset_false_path_fields", "jtag_clock_period_fields"}, "policy.forbidden")
    if not forbidden.get("reset_false_path_fields") or not forbidden.get("jtag_clock_period_fields"):
        raise ExportError("policy forbidden-field guards are empty")
    return policy


@dataclass(frozen=True)
class SummaryRecord:
    kind: str
    model: str
    label: str
    fields: tuple[str, ...]
    line: int


@dataclass(frozen=True)
class SummaryData:
    headers: dict[str, str]
    records: tuple[SummaryRecord, ...]
    source_task: str
    source_sha: str


def _parse_summary(path: Path) -> SummaryData:
    text = _read_text(path, "T-007 summary")
    headers: dict[str, str] = {}
    records: list[SummaryRecord] = []
    for line_number, raw_line in enumerate(text.splitlines(), 1):
        line = raw_line.strip("\ufeff")
        if not line.strip():
            continue
        if line.startswith("#"):
            body = line[1:].strip()
            if not body:
                raise ExportError(f"T-007 summary line {line_number} has an empty comment")
            for item in body.split(";"):
                item = item.strip()
                if not item or "=" not in item:
                    raise ExportError(f"T-007 summary line {line_number} has malformed header item")
                key, value = (part.strip() for part in item.split("=", 1))
                if not key or key in headers:
                    raise ExportError(f"T-007 summary line {line_number} has duplicate header key {key!r}")
                headers[key] = value
            continue

        fields = tuple(line.split("|"))
        if len(fields) < 4:
            raise ExportError(f"T-007 summary line {line_number} has fewer than four fields")
        kind, model, label = fields[:3]
        if kind not in SUMMARY_KINDS:
            raise ExportError(f"T-007 summary line {line_number} has unknown kind {kind!r}")
        if kind == "done":
            if not model or label:
                raise ExportError(f"T-007 summary line {line_number} has malformed done record")
        elif not model or not label:
            raise ExportError(f"T-007 summary line {line_number} has empty model/label")
        records.append(SummaryRecord(kind, model, label, fields, line_number))

    if set(headers) != SUMMARY_HEADER_KEYS:
        missing = sorted(SUMMARY_HEADER_KEYS - set(headers))
        extra = sorted(set(headers) - SUMMARY_HEADER_KEYS)
        detail = []
        if missing:
            detail.append("missing=" + ",".join(missing))
        if extra:
            detail.append("extra=" + ",".join(extra))
        raise ExportError("T-007 summary headers are not exact (" + "; ".join(detail) + ")")
    if headers["task"] not in ACCEPTED_SUMMARY_TASKS:
        raise ExportError(
            f"T-007 summary task {headers['task']!r} is not a recognized T-007/T-011 producer"
        )
    expected = {
        "label": SUMMARY_LABEL,
        "fitted_source_sha": FROZEN_SOURCE_SHA,
        "report_only": "true",
        "synthesis_rerun": "false",
        "fitter_rerun": "false",
        "assembler": "false",
        "columns": SUMMARY_COLUMNS,
    }
    for key, value in expected.items():
        if headers.get(key) != value:
            raise ExportError(f"T-007 summary header {key!r} is {headers.get(key)!r}, expected {value!r}")
    if not HEX40.fullmatch(headers["fitted_source_sha"]):
        raise ExportError("T-007 summary fitted_source_sha is not a 40-digit SHA")
    # The run task may be T-007 itself or the T-011 report-only rerun, but the
    # inventory provenance must always point at the frozen physical source
    # contract (T-007), never at the overlay run that produced the reports.
    return SummaryData(headers, tuple(records), FROZEN_SOURCE_TASK, headers["fitted_source_sha"])


def _record_map(records: Iterable[SummaryRecord], kind: str, model: str, label: str) -> list[SummaryRecord]:
    return [record for record in records if record.kind == kind and record.model == model and record.label == label]


def _one_record(summary: SummaryData, kind: str, model: str, label: str) -> SummaryRecord:
    rows = _record_map(summary.records, kind, model, label)
    if len(rows) != 1:
        raise ExportError(f"T-007 summary requires exactly one {kind}/{model}/{label} record (got {len(rows)})")
    return rows[0]


def _basename(value: str) -> str:
    # pathlib on Linux handles the slash-separated Windows paths used by the
    # remote harness.  Backslash is accepted as well for hand-copied reports.
    return value.replace("\\", "/").rstrip("/").split("/")[-1]


def _summary_report_path(summary: SummaryData, model: str, label: str) -> str:
    record = _one_record(summary, "report", model, label)
    fields = record.fields
    if len(fields) != 7 or fields[3] != "ok" or not fields[4] or fields[5] or fields[6]:
        raise ExportError(f"malformed report record at T-007 summary line {record.line}")
    return _basename(fields[4])


def _validate_summary_records(
    summary: SummaryData,
    paths: dict[str, Path],
    reset_expected: dict[str, int],
) -> dict[tuple[str, str], list[dict[str, Any]]]:
    """Validate the T-007 TSV and return its machine-readable timing rows."""

    models = ("fast", "slow")
    timing_rows: dict[tuple[str, str], list[dict[str, Any]]] = {}
    required_reports = {
        "clocks",
        "unconstrained_paths",
        "exceptions",
        "emif_reset_to_adapter_recovery",
        "emif_reset_to_adapter_removal",
    }
    auxiliary_reports = {
        f"reserved_{port}_paths_{mode}"
        for port in ("tdi", "tms", "tdo")
        for mode in ("max", "min")
    }
    for model in models:
        actual_report_labels = {
            record.label
            for record in summary.records
            if record.kind == "report" and record.model == model
        }
        if actual_report_labels != required_reports | auxiliary_reports:
            raise ExportError(
                f"T-007 summary {model} report inventory differs from the exact required set"
            )
        for label in required_reports | auxiliary_reports:
            actual = _summary_report_path(summary, model, label)
            if label == "clocks":
                expected_name = f"t007_{model}_clocks.rpt"
            elif label == "unconstrained_paths":
                expected_name = paths[f"ucp_{model}"].name
            elif label == "exceptions":
                # The exceptions report is a required sibling audit artifact;
                # only its presence/status is contractual, not its filename.
                continue
            elif label in auxiliary_reports:
                expected_name = f"t007_{model}_{label}.rpt"
            else:
                expected_name = paths[f"{model}_{'recovery' if label.endswith('recovery') else 'removal'}"].name
            if expected_name is not None and actual != expected_name:
                raise ExportError(
                    f"T-007 summary {model}/{label} points to {actual!r}, expected {expected_name!r}"
                )

        reset_rows = [
            record
            for record in summary.records
            if record.kind == "reset_report" and record.model == model and record.label == "emif_reset"
        ]
        if len(reset_rows) != 2:
            raise ExportError(f"T-007 summary {model} requires two emif_reset reset_report rows")
        seen_reset_kinds: set[str] = set()
        for reset_row in reset_rows:
            fields = reset_row.fields
            if len(fields) != 7 or fields[3] not in {"recovery", "removal"} or fields[4] != "no_clock" or not fields[5] or fields[6]:
                raise ExportError(f"malformed reset_report record at summary line {reset_row.line}")
            if fields[3] in seen_reset_kinds:
                raise ExportError(f"T-007 summary repeats reset_report kind {fields[3]!r} for {model}")
            seen_reset_kinds.add(fields[3])
            expected_name = f"t007_{model}_emif_reset_{fields[3]}.rpt"
            if _basename(fields[5]) != expected_name:
                raise ExportError(f"T-007 summary reset_report path mismatch at line {reset_row.line}")
        if seen_reset_kinds != {"recovery", "removal"}:
            raise ExportError(f"T-007 summary {model} reset_report kinds are incomplete")
        target_inventory = _one_record(summary, "reset_target_inventory", model, "emif_reset")
        if len(target_inventory.fields) != 7 or target_inventory.fields[3] != "1" or target_inventory.fields[5] != "0":
            raise ExportError(f"malformed reset_target_inventory at summary line {target_inventory.line}")

        for timing_kind in ("recovery", "removal"):
            label = f"emif_reset_to_adapter_{timing_kind}"
            report_count = reset_expected[f"{model}_{timing_kind}"]
            paths_record = _one_record(summary, "paths", model, label)
            if len(paths_record.fields) != 7:
                raise ExportError(f"malformed paths record at summary line {paths_record.line}")
            fields = paths_record.fields
            if fields[3] != "ok" or fields[4] != timing_kind or fields[6] != "":
                raise ExportError(f"malformed paths record at summary line {paths_record.line}")
            if _integer(fields[5], f"summary line {paths_record.line} path count") != report_count:
                raise ExportError(f"T-007 summary path count differs from raw {model} {timing_kind} report")

            detail_rows: list[dict[str, Any]] = []
            path_rows: list[SummaryRecord] = []
            for record in summary.records:
                if record.model != model or record.label != label:
                    continue
                if record.kind == "path":
                    path_rows.append(record)
                elif record.kind == "path_detail":
                    if len(record.fields) != 7:
                        raise ExportError(f"malformed path_detail at summary line {record.line}")
                    fields = record.fields
                    if fields[6] != timing_kind:
                        raise ExportError(f"summary path_detail kind mismatch at line {record.line}")
                    index = _integer(fields[3], f"summary line {record.line} path index")
                    if not fields[4]:
                        raise ExportError(f"summary path_detail has an empty clock at line {record.line}")
                    detail_rows.append(
                        {
                            "index": index,
                            "clock": fields[4],
                            "slack": _number(fields[5], f"summary line {record.line} slack"),
                        }
                    )
            if len(path_rows) != report_count or len(detail_rows) != report_count:
                raise ExportError(
                    f"T-007 summary {model}/{timing_kind} path rows are incomplete "
                    f"(path={len(path_rows)}, detail={len(detail_rows)}, expected={report_count})"
                )
            path_indices: list[int] = []
            for record in path_rows:
                if len(record.fields) != 7:
                    raise ExportError(f"malformed path row at summary line {record.line}")
                path_indices.append(_integer(record.fields[3], f"summary line {record.line} path index"))
                if not record.fields[4] or not record.fields[5] or not record.fields[6]:
                    raise ExportError(f"summary path row has an empty node/clock at line {record.line}")
            detail_rows.sort(key=lambda row: row["index"])
            path_indices.sort()
            expected_indices = list(range(report_count))
            if path_indices != expected_indices or [row["index"] for row in detail_rows] != expected_indices:
                raise ExportError(f"T-007 summary {model}/{timing_kind} path indices are not unique/contiguous")
            _one_record(summary, "path_iter", model, label)
            yield_key = (model, timing_kind)
            # The function returns these through a local mapping below.  The
            # assignment is intentionally kept after all row validation.
            timing_rows[yield_key] = detail_rows

    unknown_timing_labels = {
        (record.model, record.label)
        for record in summary.records
        if record.kind in {"paths", "path", "path_detail", "path_iter"}
        and record.model in models
        and record.label not in {
            "emif_reset_to_adapter_recovery",
            "emif_reset_to_adapter_removal",
        }
        and record.label not in auxiliary_reports
    }
    if unknown_timing_labels:
        raise ExportError(f"T-007 summary has unexpected timing records: {sorted(unknown_timing_labels)!r}")
    for model in models:
        for label in sorted(auxiliary_reports):
            paths_record = _one_record(summary, "paths", model, label)
            if (
                len(paths_record.fields) != 7
                or paths_record.fields[3] != "ok"
                or paths_record.fields[4] not in {"max", "min"}
                or paths_record.fields[5] != "0"
                or paths_record.fields[6]
            ):
                raise ExportError(f"malformed auxiliary paths record at summary line {paths_record.line}")
            iterator_record = _one_record(summary, "path_iter", model, label)
            if len(iterator_record.fields) != 7 or iterator_record.fields[3] != "error" or any(iterator_record.fields[4:]):
                raise ExportError(f"malformed auxiliary path_iter record at summary line {iterator_record.line}")
            if _record_map(summary.records, "path", model, label) or _record_map(summary.records, "path_detail", model, label):
                raise ExportError(f"auxiliary timing report {model}/{label} unexpectedly contains path rows")
    done_rows = [record for record in summary.records if record.kind == "done"]
    if len(done_rows) != 1 or len(done_rows[0].fields) != 6 or any(done_rows[0].fields[2:]):
        raise ExportError("T-007 summary requires exactly one well-formed done record")

    # ``timing_rows`` is populated in the loop above.  Keep the local name
    # explicit to make accidental return of unvalidated rows impossible.
    return timing_rows


def _semicolons(line: str, where: str) -> list[str] | None:
    stripped = line.strip()
    if not stripped.startswith(";") or not stripped.endswith(";"):
        return None
    parts = [part.strip() for part in stripped.strip(";").split(";")]
    if any("\n" in part or "\r" in part for part in parts):
        raise ExportError(f"{where} contains a newline inside a table field")
    return parts


def _exact_heading(line: str, title: str) -> bool:
    return re.fullmatch(r";\s*" + re.escape(title) + r"\s*;", line.strip()) is not None


def _next_heading(lines: Sequence[str], start: int) -> int:
    for index in range(start, len(lines)):
        if re.fullmatch(r";\s*Unconstrained (?:Input|Output) (?:Ports|Port Paths)\s*;", lines[index].strip()):
            return index
        if re.fullmatch(r";\s*(?:Setup|Hold) Analysis\s*;", lines[index].strip()):
            return index
    return len(lines)


def _table_rows(lines: Sequence[str], title: str, fields_count: int, where: str) -> list[tuple[str, ...]]:
    indices = [index for index, line in enumerate(lines) if _exact_heading(line, title)]
    if len(indices) != 1:
        raise ExportError(f"{where} requires exactly one {title} table (got {len(indices)})")
    start = indices[0]
    end = _next_heading(lines, start + 1)
    rows: list[tuple[str, ...]] = []
    saw_header = False
    for line_number in range(start + 1, end):
        line = lines[line_number]
        if line.lstrip().startswith("+") or not line.strip():
            continue
        fields = _semicolons(line, f"{where} line {line_number + 1}")
        if fields is None:
            continue
        if fields and fields[0] in {
            "Input Port",
            "Output Port",
            "From",
            "To",
            "Property",
        }:
            saw_header = True
            continue
        if not saw_header:
            continue
        if len(fields) != fields_count:
            raise ExportError(
                f"{where} line {line_number + 1} has {len(fields)} fields, expected {fields_count}"
            )
        if any(not field for field in fields[:2]):
            raise ExportError(f"{where} line {line_number + 1} has an empty endpoint")
        rows.append(tuple(fields))
    if not saw_header:
        raise ExportError(f"{where} is missing its table header")
    if not rows:
        raise ExportError(f"{where} has no data rows")
    return rows


@dataclass(frozen=True)
class UcpData:
    summary: dict[str, int]
    unconstrained_clocks: tuple[dict[str, str], ...]
    input_ports: tuple[dict[str, str], ...]
    output_ports: tuple[dict[str, str], ...]
    input_paths: tuple[dict[str, str], ...]
    output_paths: tuple[dict[str, str], ...]


UCP_PROPERTIES = (
    "Illegal Clocks",
    "Unconstrained Clocks",
    "Unconstrained Input Ports",
    "Unconstrained Input Port Paths",
    "Unconstrained Output Ports",
    "Unconstrained Output Port Paths",
)


def _ucp_summary(lines: Sequence[str], path: Path) -> dict[str, int]:
    marker = [index for index, line in enumerate(lines) if _exact_heading(line, "Unconstrained Paths Summary")]
    if len(marker) != 1:
        raise ExportError(f"UCP report {path} has {len(marker)} summary tables")
    # The summary ends at the Clock Status Summary heading.
    clock_marker = [index for index, line in enumerate(lines) if _exact_heading(line, "Clock Status Summary")]
    if len(clock_marker) != 1 or clock_marker[0] <= marker[0]:
        raise ExportError(f"UCP report {path} has no unique clock status table")
    result: dict[str, int] = {}
    for line_number in range(marker[0] + 1, clock_marker[0]):
        fields = _semicolons(lines[line_number], f"UCP summary line {line_number + 1}")
        if fields is None or not fields:
            continue
        if fields[0] in {"Property", ""}:
            continue
        if fields[0] not in UCP_PROPERTIES:
            raise ExportError(f"UCP report {path} has an unknown summary property {fields[0]!r}")
        if len(fields) != 3:
            raise ExportError(f"UCP report {path} has malformed summary property {fields[0]!r}")
        setup = _integer(fields[1], f"UCP {path.name} {fields[0]} setup")
        hold = _integer(fields[2], f"UCP {path.name} {fields[0]} hold")
        if setup != hold:
            raise ExportError(f"UCP report {path} has setup/hold drift for {fields[0]!r}")
        if fields[0] in result:
            raise ExportError(f"UCP report {path} repeats summary property {fields[0]!r}")
        result[fields[0]] = setup
    if set(result) != set(UCP_PROPERTIES):
        raise ExportError(f"UCP report {path} is missing one or more summary properties")
    return result


def _ucp_clocks(lines: Sequence[str], path: Path) -> tuple[dict[str, str], ...]:
    markers = [index for index, line in enumerate(lines) if _exact_heading(line, "Clock Status Summary")]
    analyses = [index for index, line in enumerate(lines) if _exact_heading(line, "Setup Analysis")]
    if len(markers) != 1 or len(analyses) != 1 or analyses[0] <= markers[0]:
        raise ExportError(f"UCP report {path} has malformed clock status range")
    rows: list[dict[str, str]] = []
    seen: set[str] = set()
    for line_number in range(markers[0] + 1, analyses[0]):
        fields = _semicolons(lines[line_number], f"UCP clock table line {line_number + 1}")
        if fields is None or not fields or fields[0] in {"Target", ""}:
            continue
        if len(fields) != 4:
            raise ExportError(f"UCP report {path} has malformed clock row at line {line_number + 1}")
        target, clock, clock_type, status = fields
        if target in seen:
            raise ExportError(f"UCP report {path} repeats clock target {target!r}")
        if not target or status not in {"Constrained", "Unconstrained"}:
            raise ExportError(f"UCP report {path} has malformed clock target {target!r}")
        if status == "Unconstrained":
            if clock:
                raise ExportError(
                    f"UCP report {path} has a non-empty Clock field for unconstrained target {target!r}"
                )
            if any(
                marker in field.lower()
                for field in (target, clock_type, status)
                for marker in ("period", "create_clock")
            ):
                raise ExportError(
                    f"UCP report {path} contains period/create_clock text in an unconstrained clock row"
                )
        seen.add(target)
        rows.append({"target": target, "clock": clock, "type": clock_type, "status": status})
    unconstrained = [row for row in rows if row["status"] == "Unconstrained"]
    if not unconstrained:
        raise ExportError(f"UCP report {path} has no unconstrained clock rows")
    return tuple(unconstrained)


def _analysis_lines(lines: Sequence[str], title: str, path: Path) -> Sequence[str]:
    indices = [index for index, line in enumerate(lines) if _exact_heading(line, title)]
    if len(indices) != 1:
        raise ExportError(f"UCP report {path} has {len(indices)} {title} sections")
    start = indices[0]
    next_analysis = [
        index
        for index, line in enumerate(lines)
        if index > start
        and (
            _exact_heading(line, "Setup Analysis")
            or _exact_heading(line, "Hold Analysis")
        )
    ]
    end = min(next_analysis) if next_analysis else len(lines)
    return lines[start:end]


def _ports_and_paths(lines: Sequence[str], path: Path, model: str) -> UcpData:
    summary = _ucp_summary(lines, path)
    unconstrained = _ucp_clocks(lines, path)
    setup_lines = _analysis_lines(lines, "Setup Analysis", path)
    # ``_analysis_lines`` on the full report is called separately for Hold so
    # both reports must be present and independently parseable.
    input_port_rows = _table_rows(setup_lines, "Unconstrained Input Ports", 2, f"{path.name}/{model}/setup input ports")
    output_port_rows = _table_rows(setup_lines, "Unconstrained Output Ports", 2, f"{path.name}/{model}/setup output ports")
    input_path_rows = _table_rows(setup_lines, "Unconstrained Input Port Paths", 3, f"{path.name}/{model}/setup input paths")
    output_path_rows = _table_rows(setup_lines, "Unconstrained Output Port Paths", 3, f"{path.name}/{model}/setup output paths")
    hold_lines = _analysis_lines(lines, "Hold Analysis", path)
    hold_input_port_rows = _table_rows(hold_lines, "Unconstrained Input Ports", 2, f"{path.name}/{model}/hold input ports")
    hold_output_port_rows = _table_rows(hold_lines, "Unconstrained Output Ports", 2, f"{path.name}/{model}/hold output ports")
    hold_input_path_rows = _table_rows(hold_lines, "Unconstrained Input Port Paths", 3, f"{path.name}/{model}/hold input paths")
    hold_output_path_rows = _table_rows(hold_lines, "Unconstrained Output Port Paths", 3, f"{path.name}/{model}/hold output paths")
    if (
        input_port_rows != hold_input_port_rows
        or output_port_rows != hold_output_port_rows
        or input_path_rows != hold_input_path_rows
        or output_path_rows != hold_output_path_rows
    ):
        raise ExportError(f"UCP report {path} has setup/hold row drift")

    def port_rows(rows: Sequence[tuple[str, ...]], direction: str) -> tuple[dict[str, str], ...]:
        seen: set[str] = set()
        result: list[dict[str, str]] = []
        for name, comment in rows:
            if name in seen:
                raise ExportError(f"UCP report {path} repeats {direction} port {name!r}")
            if not comment:
                raise ExportError(f"UCP report {path} has an empty {direction} port comment")
            seen.add(name)
            result.append({"name": name, "comment": comment, "direction": direction})
        return tuple(result)

    def path_rows(rows: Sequence[tuple[str, ...]], direction: str) -> tuple[dict[str, str], ...]:
        seen: set[tuple[str, str, str]] = set()
        result: list[dict[str, str]] = []
        for source, destination, clock in rows:
            key = (source, destination, clock)
            if key in seen:
                raise ExportError(f"UCP report {path} repeats {direction} path {key!r}")
            if not source or not destination:
                raise ExportError(f"UCP report {path} has an empty {direction} path endpoint")
            seen.add(key)
            result.append({"from": source, "to": destination, "clock": clock})
        return tuple(result)

    result = UcpData(
        summary=summary,
        unconstrained_clocks=unconstrained,
        input_ports=port_rows(input_port_rows, "input"),
        output_ports=port_rows(output_port_rows, "output"),
        input_paths=path_rows(input_path_rows, "input"),
        output_paths=path_rows(output_path_rows, "output"),
    )
    derived = {
        "Illegal Clocks": 0,
        "Unconstrained Clocks": len(result.unconstrained_clocks),
        "Unconstrained Input Ports": len(result.input_ports),
        "Unconstrained Input Port Paths": len(result.input_paths),
        "Unconstrained Output Ports": len(result.output_ports),
        "Unconstrained Output Port Paths": len(result.output_paths),
    }
    if result.summary != {key: result.summary[key] for key in UCP_PROPERTIES}:
        raise ExportError(f"UCP report {path} has an incomplete summary")
    for key, value in derived.items():
        if result.summary[key] != value:
            raise ExportError(f"UCP report {path} summary {key!r} disagrees with table rows")
    return result


def _parse_ucp(path: Path, model: str) -> UcpData:
    text = _read_text(path, f"{model} raw UCP report")
    lines = text.splitlines()
    if not lines:
        raise ExportError(f"{model} raw UCP report is empty")
    return _ports_and_paths(lines, path, model)


@dataclass(frozen=True)
class TimingData:
    kind: str
    path_count: int
    violated: int
    worst_slack_ns: float
    rows: tuple[dict[str, Any], ...]


def _parse_timing(path: Path, kind: str, reset_name: str) -> TimingData:
    text = _read_text(path, f"{kind} timing report")
    lines = text.splitlines()
    pattern = re.compile(
        rf"Report Timing:\s+Found\s+(\d+)\s+{re.escape(kind)}\s+paths\s+\((\d+)\s+violated\)\.\s+Worst case slack is\s+({NUMBER_BODY})\s*$"
    )
    headers = [match for line in lines if (match := pattern.search(line))]
    if len(headers) != 1:
        raise ExportError(f"{kind} timing report {path} has {len(headers)} timing summary headers")
    header = headers[0]
    path_count = int(header.group(1))
    violated = int(header.group(2))
    worst_slack = _number(header.group(3), f"{path.name} worst slack")
    if path_count <= 0 or violated < 0 or violated > path_count:
        raise ExportError(f"{kind} timing report {path} has invalid header counts")

    if not any(f"-from [get_registers {{{reset_name}}}]" in line for line in lines):
        raise ExportError(f"{kind} timing report {path} has no exact reset source query")
    if not any("-to [get_registers {soc|emif_adapter|*}]" in line for line in lines):
        raise ExportError(f"{kind} timing report {path} has no exact adapter destination query")
    if not any(re.search(rf"\s-{re.escape(kind)}(?:\s|$)", line) for line in lines):
        raise ExportError(f"{kind} timing report {path} has no {kind} command option")

    summary_markers = [index for index, line in enumerate(lines) if _exact_heading(line, "Summary of Paths")]
    header_markers = [index for index, line in enumerate(lines) if "Slack ; From Node" in line]
    if len(summary_markers) != 1 or len(header_markers) != 1 or header_markers[0] <= summary_markers[0]:
        raise ExportError(f"{kind} timing report {path} has no unique detailed summary table")

    rows: list[dict[str, Any]] = []
    summary_end: int | None = None
    index = header_markers[0] + 1
    while index < len(lines):
        line = lines[index]
        if line.lstrip().startswith("+"):
            if rows:
                summary_end = index
                break
            index += 1
            continue
        if not line.strip():
            if rows:
                break
            index += 1
            continue
        fields = _semicolons(line, f"{kind} timing table line {index + 1}")
        if fields is None:
            if rows:
                break
            index += 1
            continue
        if fields and fields[0] == "Slack":
            index += 1
            continue
        if len(fields) != 9:
            raise ExportError(f"{kind} timing report {path} has malformed path row at line {index + 1}")
        slack = _number(fields[0], f"{path.name} path slack line {index + 1}")
        if not fields[1] or not fields[2] or not fields[3] or not fields[4] or not fields[8]:
            raise ExportError(f"{kind} timing report {path} has an empty path field at line {index + 1}")
        if fields[1] != reset_name or not fields[2].startswith("soc|emif_adapter|"):
            raise ExportError(f"{kind} timing report {path} has an out-of-contract reset endpoint")
        if fields[3] != fields[4]:
            raise ExportError(f"{kind} timing report {path} has mismatched launch/latch clocks")
        # Validate all numeric timing columns even though only slack is
        # exported; malformed columns must not be silently ignored.
        for column, value in zip(("relationship", "clock_skew", "data_delay"), fields[5:8]):
            _number(value, f"{path.name} {column} line {index + 1}")
        rows.append(
            {
                "slack": slack,
                "from": fields[1],
                "to": fields[2],
                "launch_clock": fields[3],
                "latch_clock": fields[4],
                "relationship": fields[5],
                "clock_skew": fields[6],
                "data_delay": fields[7],
                "corner": fields[8],
            }
        )
        index += 1
    if summary_end is None:
        raise ExportError(f"{kind} timing report {path} has no terminating summary-table separator")
    # Once the Summary of Paths table is closed, normal full-path detail rows
    # use a different column shape (eight fields).  A nine-field numeric row
    # here is therefore an extra Summary of Paths row that the old parser
    # would have silently ignored after breaking at the separator.
    for tail_index in range(summary_end + 1, len(lines)):
        fields = _semicolons(lines[tail_index], f"{kind} timing tail line {tail_index + 1}")
        if fields is not None and len(fields) == 9 and fields[0] != "Slack" and NUMBER.fullmatch(fields[0]):
            raise ExportError(
                f"{kind} timing report {path} has an extra path row after the summary-table separator"
            )
    if len(rows) != path_count:
        raise ExportError(f"{kind} timing report {path} has {len(rows)} rows, header says {path_count}")
    keys = [(row["from"], row["to"]) for row in rows]
    duplicate_keys = [key for key, count in Counter(keys).items() if count > 1]
    if duplicate_keys:
        raise ExportError(f"{kind} timing report {path} repeats timing endpoint {duplicate_keys[0]!r}")
    observed_worst = min(row["slack"] for row in rows)
    if not math.isclose(observed_worst, worst_slack, rel_tol=0.0, abs_tol=1e-9):
        raise ExportError(f"{kind} timing report {path} header slack differs from detailed rows")
    observed_violated = sum(row["slack"] < 0.0 for row in rows)
    if observed_violated != violated:
        raise ExportError(f"{kind} timing report {path} violation count differs from detailed rows")
    return TimingData(kind, path_count, violated, worst_slack, tuple(rows))


def _same_ucp(first: UcpData, second: UcpData) -> None:
    if first != second:
        raise ExportError("fast and slow raw UCP reports differ")


def _policy_maps(policy: dict[str, Any]) -> tuple[dict[str, dict[str, Any]], dict[str, dict[str, Any]], list[dict[str, Any]]]:
    ucp = policy["ucp"]
    clocks = {item["name"]: item for item in ucp["clocks"]}
    ports = {item["name"]: item for item in ucp["ports"]}
    classes = list(policy["jtag_hierarchy"]["allowed_classes"])
    return clocks, ports, classes


def _validate_ucp_contract(ucp: UcpData, policy: dict[str, Any]) -> None:
    clocks, ports, classes = _policy_maps(policy)
    observed_clock_names = [row["target"] for row in ucp.unconstrained_clocks]
    if set(observed_clock_names) != set(clocks) or len(observed_clock_names) != len(clocks):
        raise ExportError("raw UCP unconstrained clocks are missing, duplicated, or extra")
    for row in ucp.unconstrained_clocks:
        expected = clocks[row["target"]]
        if row["status"] != "Unconstrained" or row["type"] != "Base" or expected["status"] != "unconstrained":
            raise ExportError(f"raw UCP clock {row['target']!r} has an unexpected status/type")

    observed_ports = {row["name"]: row for row in (*ucp.input_ports, *ucp.output_ports)}
    if set(observed_ports) != set(ports) or len(observed_ports) != len(ports):
        raise ExportError("raw UCP unconstrained ports are missing, duplicated, or extra")
    for name, expected in ports.items():
        if observed_ports[name]["direction"] != expected["direction"]:
            raise ExportError(f"raw UCP port {name!r} has the wrong direction")
    if set(row["from"] for row in ucp.input_paths) - {row["name"] for row in ucp.input_ports}:
        raise ExportError("raw UCP input paths contain an unknown source port")
    if set(row["to"] for row in ucp.output_paths) - {row["name"] for row in ucp.output_ports}:
        raise ExportError("raw UCP output paths contain an unknown destination port")

    expected_summary = policy["ucp"]["summary"]
    actual_summary = {
        "clock_count": len(ucp.unconstrained_clocks),
        "input_port_count": len(ucp.input_ports),
        "input_path_count": len(ucp.input_paths),
        "output_port_count": len(ucp.output_ports),
        "output_path_count": len(ucp.output_paths),
    }
    if actual_summary != expected_summary or {
        "clock_count": ucp.summary["Unconstrained Clocks"],
        "input_port_count": ucp.summary["Unconstrained Input Ports"],
        "input_path_count": ucp.summary["Unconstrained Input Port Paths"],
        "output_port_count": ucp.summary["Unconstrained Output Ports"],
        "output_path_count": ucp.summary["Unconstrained Output Port Paths"],
    } != expected_summary:
        raise ExportError("raw UCP summary counts differ from the exact T-010 contract")
    if ucp.summary["Illegal Clocks"] != 0:
        raise ExportError("raw UCP report contains illegal clocks")

    class_map = {item["class"]: item for item in classes}
    required_present: set[str] = set()
    for port_name, expected in ports.items():
        paths = ucp.input_paths if expected["direction"] == "input" else ucp.output_paths
        if expected["direction"] == "input":
            rows = [row for row in paths if row["from"] == port_name]
        else:
            rows = [row for row in paths if row["to"] == port_name]
        if len(rows) != expected["path_count"]:
            raise ExportError(f"raw UCP port {port_name!r} path count differs from policy")
        group_counts: Counter[str] = Counter()
        direct_witnesses: dict[str, str] = {}
        fallback_count = 0
        output_group_names = list(expected["path_groups"])
        for row in rows:
            subject = row["to"] if expected["direction"] == "input" else row["from"]
            matches = [item["class"] for item in classes if fnmatch.fnmatchcase(subject, item["pattern"])]
            if len(matches) > 1:
                raise ExportError(f"raw UCP path {subject!r} ambiguously matches hierarchy classes {matches}")
            if len(matches) == 1 and matches[0] in expected["path_groups"]:
                group = matches[0]
                group_counts[group] += 1
                direct_witnesses.setdefault(group, subject)
                required_present.add(group)
                continue

            # Quartus reports the reserved TDI->TDO loopback as a port-only
            # endpoint.  T-010 assigns that single observed edge to the
            # reserved-port input group and to the sole output SLD group.  The
            # fallback is deliberately structural and narrow; arbitrary rows
            # cannot enter it.
            input_like = row["from"].lower().endswith("_tdi")
            output_like = row["to"].lower().endswith("_tdo")
            fallback_shape_ok = expected["direction"] == "input" or len(output_group_names) == 1
            if not (input_like and output_like and fallback_shape_ok):
                raise ExportError(f"raw UCP path {subject!r} is outside approved hierarchy classes")
            fallback_group = "reserved_jtag_port" if expected["direction"] == "input" else output_group_names[0]
            if fallback_group not in expected["path_groups"]:
                raise ExportError(f"raw UCP path {subject!r} has no approved fallback class")
            group_counts[fallback_group] += 1
            fallback_count += 1
            required_present.add(fallback_group)
            if expected["direction"] == "input":
                pattern = class_map[fallback_group]["pattern"]
                if "*" in pattern or not fnmatch.fnmatchcase(row["to"], pattern.split("|", 1)[-1]):
                    raise ExportError("reserved-port input fallback is not the exact policy endpoint")

        if fallback_count > 1:
            raise ExportError(f"raw UCP port {port_name!r} has multiple port-only fallback paths")
        if set(group_counts) != set(expected["path_groups"]):
            raise ExportError(f"raw UCP port {port_name!r} hierarchy classes differ from policy")
        for group_name, expected_group in expected["path_groups"].items():
            if group_counts[group_name] != expected_group:
                raise ExportError(f"raw UCP port {port_name!r} group {group_name!r} count differs from policy")
            witness = direct_witnesses.get(group_name)
            if witness is None:
                pattern = class_map[group_name]["pattern"]
                if "*" in pattern:
                    raise ExportError(f"raw UCP port {port_name!r} group {group_name!r} has no hierarchy witness")
                witness = pattern
            if not fnmatch.fnmatchcase(witness, class_map[group_name]["pattern"]):
                raise ExportError(f"raw UCP port {port_name!r} group {group_name!r} witness is outside policy")
    required_classes = {item["class"] for item in classes if item["required"]}
    if not required_classes.issubset(required_present):
        raise ExportError("raw UCP reports do not contain every required vendor hierarchy class")


def _path_groups(
    ucp: UcpData,
    policy: dict[str, Any],
) -> list[dict[str, Any]]:
    _, _, classes = _policy_maps(policy)
    class_map = {item["class"]: item for item in classes}
    result: list[dict[str, Any]] = []
    for policy_port in policy["ucp"]["ports"]:
        name = policy_port["name"]
        direction = policy_port["direction"]
        rows = [
            row
            for row in (ucp.input_paths if direction == "input" else ucp.output_paths)
            if (row["from"] if direction == "input" else row["to"]) == name
        ]
        groups: dict[str, dict[str, Any]] = {}
        direct: dict[str, str] = {}
        fallback = Counter()
        for row in rows:
            subject = row["to"] if direction == "input" else row["from"]
            matches = [item["class"] for item in classes if fnmatch.fnmatchcase(subject, item["pattern"])]
            if len(matches) == 1 and matches[0] in policy_port["path_groups"]:
                group = matches[0]
                direct.setdefault(group, subject)
            else:
                group = "reserved_jtag_port" if direction == "input" else next(iter(policy_port["path_groups"]))
                fallback[group] += 1
            if group not in policy_port["path_groups"]:
                raise ExportError(f"cannot derive hierarchy class for {direction} port {name!r}")
            groups.setdefault(group, {"count": 0, "hierarchy": ""})["count"] += 1
        for group_name in policy_port["path_groups"]:
            if group_name not in groups:
                raise ExportError(f"cannot derive missing hierarchy group {group_name!r} on port {name!r}")
            witness = direct.get(group_name)
            if witness is None:
                pattern = class_map[group_name]["pattern"]
                if "*" in pattern:
                    raise ExportError(f"cannot derive a witness hierarchy for {group_name!r}")
                witness = pattern
            groups[group_name]["hierarchy"] = witness
        result.append(
            {
                "name": name,
                "direction": direction,
                "path_count": len(rows),
                "path_groups": groups,
            }
        )
    return result


def _timing_inventory(
    timings: dict[tuple[str, str], TimingData],
    policy: dict[str, Any],
) -> dict[str, Any]:
    reset = policy["reset_control"]
    corners: dict[str, Any] = {}
    for corner in reset["corners"]:
        values: dict[str, Any] = {}
        for kind in ("recovery", "removal"):
            timing = timings[(corner, kind)]
            expected = reset["checks"][kind]
            if timing.path_count != expected["path_count"] or timing.violated != expected["violated"]:
                raise ExportError(f"{corner} {kind} report count differs from the exact T-010 contract")
            if not math.isclose(
                timing.worst_slack_ns,
                float(expected["baseline_worst_slack_ns"]),
                rel_tol=0.0,
                abs_tol=1e-9,
            ):
                raise ExportError(f"{corner} {kind} report worst slack differs from the frozen T-007 observation")
            if expected["require_worst_slack_positive"] and timing.worst_slack_ns <= 0:
                raise ExportError(f"{corner} {kind} report worst slack is not positive")
            values[kind] = {
                "path_count": timing.path_count,
                "violated": timing.violated,
                "worst_slack_ns": timing.worst_slack_ns,
            }
        corners[corner] = values
    return {
        "reset_control": reset["name"],
        "kind": reset["kind"],
        "corners": corners,
    }


def _inventory(
    summary: SummaryData,
    ucp: UcpData,
    timings: dict[tuple[str, str], TimingData],
    policy: dict[str, Any],
) -> dict[str, Any]:
    _validate_ucp_contract(ucp, policy)
    ports = _path_groups(ucp, policy)
    clocks, _, _ = _policy_maps(policy)
    observed_clock_rows = {row["target"]: row for row in ucp.unconstrained_clocks}
    ucp_summary = {
        "clock_count": len(observed_clock_rows),
        "input_port_count": sum(1 for port in ports if port["direction"] == "input"),
        "input_path_count": sum(port["path_count"] for port in ports if port["direction"] == "input"),
        "output_port_count": sum(1 for port in ports if port["direction"] == "output"),
        "output_path_count": sum(port["path_count"] for port in ports if port["direction"] == "output"),
    }
    expected_summary = policy["ucp"]["summary"]
    if ucp_summary != expected_summary:
        raise ExportError("derived UCP summary differs from the exact T-010 contract")
    clock_rows = [
        {
            "name": name,
            "status": "unconstrained",
            "kind": clocks[name]["kind"],
        }
        for name in clocks
    ]
    return {
        "schema_version": 1,
        "inventory_kind": policy["inventory_schema"]["kind"],
        "provenance": {
            "source_task": summary.source_task,
            "source_sha": summary.source_sha,
            "exporter": EXPORTER_NAME,
        },
        "ucp": {
            "summary": ucp_summary,
            "clocks": clock_rows,
            "ports": ports,
        },
        "recovery_removal": _timing_inventory(timings, policy),
        "clock_constraints": [],
        "exceptions": [],
    }


def export_inventory(args: argparse.Namespace) -> dict[str, Any]:
    policy_path = args.policy.resolve()
    policy = _policy_contract(_read_json(policy_path, "physical waiver policy"))
    summary = _parse_summary(args.summary.resolve())
    if summary.source_task != FROZEN_SOURCE_TASK or summary.source_sha != FROZEN_SOURCE_SHA:
        raise ExportError("summary provenance does not match the frozen T-007 physical source")

    paths = {
        "ucp_fast": args.ucp_fast.resolve(),
        "ucp_slow": args.ucp_slow.resolve(),
        "fast_recovery": args.fast_recovery.resolve(),
        "fast_removal": args.fast_removal.resolve(),
        "slow_recovery": args.slow_recovery.resolve(),
        "slow_removal": args.slow_removal.resolve(),
    }
    output = args.output.resolve()
    for label, path in {"summary": args.summary.resolve(), **paths, "policy": policy_path}.items():
        if output == path:
            raise ExportError(f"output path aliases input {label}: refusing to overwrite an artifact")

    fast_ucp = _parse_ucp(paths["ucp_fast"], "fast")
    slow_ucp = _parse_ucp(paths["ucp_slow"], "slow")
    _same_ucp(fast_ucp, slow_ucp)
    reset_name = policy["reset_control"]["name"]
    timings = {
        ("fast", "recovery"): _parse_timing(paths["fast_recovery"], "recovery", reset_name),
        ("fast", "removal"): _parse_timing(paths["fast_removal"], "removal", reset_name),
        ("slow", "recovery"): _parse_timing(paths["slow_recovery"], "recovery", reset_name),
        ("slow", "removal"): _parse_timing(paths["slow_removal"], "removal", reset_name),
    }
    reset_expected = {
        f"{corner}_{kind}": timings[(corner, kind)].path_count
        for corner in ("fast", "slow")
        for kind in ("recovery", "removal")
    }
    timing_rows = _validate_summary_records(summary, paths, reset_expected)
    for key, details in timing_rows.items():
        raw_rows = timings[key].rows
        if len(details) != len(raw_rows):
            raise ExportError(f"summary/raw timing row count differs for {key[0]} {key[1]}")
        for index, (detail, raw) in enumerate(zip(details, raw_rows)):
            if not math.isclose(detail["slack"], raw["slack"], rel_tol=0.0, abs_tol=1e-9):
                raise ExportError(f"summary/raw timing slack differs at {key[0]} {key[1]} row {index}")
    return _inventory(summary, fast_ucp, timings, policy)


def _write_inventory(path: Path, inventory: dict[str, Any]) -> None:
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(inventory, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    except OSError as exc:
        raise ExportError(f"cannot write inventory {path}: {exc}") from exc


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--policy", type=Path, default=Path(__file__).resolve().parents[1] / "physical_waivers.json")
    parser.add_argument("--summary", type=Path, required=True, help="T-007 machine-readable summary TSV")
    parser.add_argument("--ucp-fast", "--fast-ucp", dest="ucp_fast", type=Path, required=True)
    parser.add_argument("--ucp-slow", "--slow-ucp", dest="ucp_slow", type=Path, required=True)
    parser.add_argument("--fast-recovery", type=Path, required=True)
    parser.add_argument("--fast-removal", type=Path, required=True)
    parser.add_argument("--slow-recovery", type=Path, required=True)
    parser.add_argument("--slow-removal", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True, help="output inventory JSON")
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    try:
        inventory = export_inventory(args)
        _write_inventory(args.output.resolve(), inventory)
    except ExportError as exc:
        print("PHYSICAL_WAIVER_EXPORT_FAIL", file=sys.stderr)
        print(f"- {exc}", file=sys.stderr)
        return 1
    print(
        json.dumps(
            {
                "schema_version": 1,
                "status": "PASS",
                "inventory": str(args.output.resolve()),
                "inventory_kind": inventory["inventory_kind"],
                "source_sha": inventory["provenance"]["source_sha"],
            },
            sort_keys=True,
        )
    )
    print("PHYSICAL_WAIVER_EXPORT_PASS", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
