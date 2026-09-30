#!/usr/bin/env python3
"""Export a normalized, fail-closed B25 UCP/reset waiver inventory.

Quartus may add or remove a terminal ``~DUPLICATE`` register during fitter
routability optimization.  Those physical copies are not stable enough to be
an architectural waiver key.  This exporter therefore validates every raw
row, lifts only a narrowly-defined terminal duplicate to its existing base
row, and compares the complete normalized membership against a reviewed v2
policy.  The v1 policy and tools remain untouched for historical replay.
"""

from __future__ import annotations

import argparse
import fnmatch
import hashlib
import json
import math
import re
import sys
from collections import Counter
from pathlib import Path
from typing import Any, Iterable, Sequence

import export_physical_waiver_inventory as v1


POLICY_ID = "B25-PHYSICAL-UCP-INVARIANT-WAIVER"
PRODUCTION_POLICY_DIGEST = "b437b56554e6ea4b57ede797a956fe11ee2e9bf92a2a31149e7ca9d3a8bea8b3"
INVENTORY_KIND = "lcvex-physical-ucp-recovery-removal-invariant-v2"
EXPORTER_ID = "quartus_sta_normalized_invariant_inventory_v2"
DUPLICATE_SUFFIX = "~DUPLICATE"
HEX40 = re.compile(r"[0-9a-f]{40}")
HEX64 = re.compile(r"[0-9a-f]{64}")
RESET_CLOCK = "emif|emif_bot|emif_bot_core_usr_clk"
KNOWN_CORNERS = {
    "Slow 900mV 100C Model",
    "Slow 900mV 0C Model",
    "Fast 900mV 100C Model",
    "Fast 900mV 0C Model",
}
FIXTURE_ROOT = (Path(__file__).resolve().parents[3] / "build/agents/T-20260910-001").resolve()


class InvariantError(RuntimeError):
    """A deterministic v2 policy, report, or inventory failure."""


def _unique_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    value: dict[str, Any] = {}
    for key, item in pairs:
        if key in value:
            raise ValueError(f"duplicate JSON key {key!r}")
        value[key] = item
    return value


def _load_json(path: Path, label: str) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"), object_pairs_hook=_unique_object)
    except (OSError, UnicodeError, json.JSONDecodeError, ValueError) as exc:
        raise InvariantError(f"cannot read {label} {path}: {exc}") from exc
    if not isinstance(value, dict):
        raise InvariantError(f"{label} must be a JSON object")
    return value


def _exact_keys(value: Any, expected: set[str], where: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise InvariantError(f"{where} must be an object")
    actual = set(value)
    if actual != expected:
        missing = sorted(expected - actual)
        extra = sorted(actual - expected)
        raise InvariantError(f"{where} keys differ: missing={missing}, extra={extra}")
    return value


def _nonnegative_int(value: Any, where: str) -> int:
    if not isinstance(value, int) or isinstance(value, bool) or value < 0:
        raise InvariantError(f"{where} must be a non-negative integer")
    return value


def _digest(value: Any) -> str:
    canonical = json.dumps(value, ensure_ascii=True, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(canonical.encode("utf-8")).hexdigest()


def _sorted_members(rows: Iterable[dict[str, str]]) -> list[dict[str, str]]:
    return sorted(rows, key=lambda row: json.dumps(row, sort_keys=True, separators=(",", ":")))


def _validate_digest(value: Any, where: str) -> str:
    if not isinstance(value, str) or not HEX64.fullmatch(value):
        raise InvariantError(f"{where} must be a lowercase SHA-256")
    return value


def _policy(path: Path, allow_fixture: bool = False) -> dict[str, Any]:
    policy = _load_json(path, "invariant policy")
    _exact_keys(
        policy,
        {
            "schema_version",
            "policy_id",
            "contract_lineage",
            "inventory_schema",
            "normalization",
            "ucp",
            "jtag_hierarchy",
            "reset_control",
            "provenance",
            "forbidden",
        },
        "policy",
    )
    if policy["schema_version"] != 2:
        raise InvariantError("policy schema_version must be 2")
    expected_id = POLICY_ID if not allow_fixture else {POLICY_ID, POLICY_ID + "-FIXTURE"}
    if (policy["policy_id"] != expected_id if isinstance(expected_id, str) else policy["policy_id"] not in expected_id):
        raise InvariantError("policy_id is not an accepted v2 invariant policy")
    if policy["policy_id"] == POLICY_ID + "-FIXTURE" and not path.resolve().is_relative_to(FIXTURE_ROOT):
        raise InvariantError("fixture policy must remain under the task-owned ignored build root")

    lineage = _exact_keys(policy["contract_lineage"], {"task_id", "source_sha", "evidence"}, "policy.contract_lineage")
    if lineage["task_id"] != "T-20260909-007" or not HEX40.fullmatch(str(lineage["source_sha"])):
        raise InvariantError("contract lineage is not the reviewed T-007 source")
    if not isinstance(lineage["evidence"], str) or Path(lineage["evidence"]).is_absolute():
        raise InvariantError("contract lineage evidence must be a relative path")

    schema = _exact_keys(policy["inventory_schema"], {"kind", "required_top_level", "exceptions_exact"}, "policy.inventory_schema")
    required_top = [
        "schema_version",
        "inventory_kind",
        "provenance",
        "reports",
        "ucp",
        "recovery_removal",
        "clock_constraints",
        "exceptions",
    ]
    if schema["kind"] != INVENTORY_KIND or schema["required_top_level"] != required_top or schema["exceptions_exact"] != []:
        raise InvariantError("inventory schema is not the exact v2 contract")

    normalization = _exact_keys(
        policy["normalization"],
        {"duplicate_suffix", "canonical_digest", "ucp_duplicate_row", "timing_duplicate_row"},
        "policy.normalization",
    )
    if normalization["duplicate_suffix"] != DUPLICATE_SUFFIX:
        raise InvariantError("duplicate suffix contract was weakened")
    if normalization["canonical_digest"] != "sha256(canonical-json-sorted-members-v1)":
        raise InvariantError("unknown canonical digest contract")
    for key in ("ucp_duplicate_row", "timing_duplicate_row"):
        if not isinstance(normalization[key], str) or not normalization[key]:
            raise InvariantError(f"policy.normalization.{key} must be documented")

    ucp = _exact_keys(policy["ucp"], {"summary", "clocks", "ports"}, "policy.ucp")
    summary = _exact_keys(
        ucp["summary"],
        {"clock_count", "input_port_count", "input_path_count", "output_port_count", "output_path_count"},
        "policy.ucp.summary",
    )
    for key, value in summary.items():
        _nonnegative_int(value, f"policy.ucp.summary.{key}")
    if summary["clock_count"] != 2 or summary["input_port_count"] != 2 or summary["output_port_count"] != 1:
        raise InvariantError("policy UCP object cardinality is not 2 clocks / 2 inputs / 1 output")

    if not isinstance(ucp["clocks"], list) or len(ucp["clocks"]) != 2:
        raise InvariantError("policy UCP clocks must contain exactly two rows")
    clock_names: set[str] = set()
    for index, clock in enumerate(ucp["clocks"]):
        row = _exact_keys(clock, {"name", "status", "kind", "type", "clock_field"}, f"policy.ucp.clocks[{index}]")
        if row["name"] in clock_names or row["status"] != "unconstrained" or row["type"] != "Base" or row["clock_field"] != "":
            raise InvariantError("policy UCP clock row is duplicate or weakened")
        clock_names.add(row["name"])
    if clock_names != {"altera_reserved_tck", "soc|emif_adapter|emif_rst_sync1_n"}:
        raise InvariantError("policy UCP clock names differ from the reviewed pair")

    if not isinstance(ucp["ports"], list) or len(ucp["ports"]) != 3:
        raise InvariantError("policy UCP ports must contain TDI/TMS/TDO")
    port_names: set[str] = set()
    for index, port in enumerate(ucp["ports"]):
        row = _exact_keys(
            port,
            {"name", "direction", "normalized_path_count", "path_groups", "endpoint_digest"},
            f"policy.ucp.ports[{index}]",
        )
        if row["name"] in port_names or row["direction"] not in {"input", "output"}:
            raise InvariantError("policy UCP port identity is invalid")
        port_names.add(row["name"])
        _nonnegative_int(row["normalized_path_count"], f"policy port {row['name']} count")
        _validate_digest(row["endpoint_digest"], f"policy port {row['name']} digest")
        if not isinstance(row["path_groups"], dict) or not row["path_groups"]:
            raise InvariantError(f"policy port {row['name']} path groups are empty")
        for group, count in row["path_groups"].items():
            if not isinstance(group, str) or not group:
                raise InvariantError("policy path-group name is invalid")
            _nonnegative_int(count, f"policy path group {group}")
        if sum(row["path_groups"].values()) != row["normalized_path_count"]:
            raise InvariantError(f"policy port {row['name']} group counts do not close")
    if port_names != {"altera_reserved_tdi", "altera_reserved_tms", "altera_reserved_tdo"}:
        raise InvariantError("policy ports differ from exact TDI/TMS/TDO")

    hierarchy = _exact_keys(
        policy["jtag_hierarchy"],
        {"allowed_classes", "reserved_port_pair", "forbid_arbitrary_tck_period", "forbid_jtag_create_clock"},
        "policy.jtag_hierarchy",
    )
    if hierarchy["forbid_arbitrary_tck_period"] is not True or hierarchy["forbid_jtag_create_clock"] is not True:
        raise InvariantError("JTAG clock guards were weakened")
    classes = hierarchy["allowed_classes"]
    if not isinstance(classes, list) or not classes:
        raise InvariantError("allowed hierarchy classes are empty")
    class_names: set[str] = set()
    for index, item in enumerate(classes):
        row = _exact_keys(item, {"class", "pattern", "required"}, f"policy hierarchy class {index}")
        if row["class"] in class_names or not row["pattern"] or not isinstance(row["required"], bool):
            raise InvariantError("hierarchy class contract is invalid")
        class_names.add(row["class"])
    pair = _exact_keys(hierarchy["reserved_port_pair"], {"from", "to", "class"}, "policy reserved pair")
    if pair != {"from": "altera_reserved_tdi", "to": "altera_reserved_tdo", "class": "reserved_jtag_port"}:
        raise InvariantError("reserved TDI/TDO pair contract differs")

    reset = _exact_keys(
        policy["reset_control"],
        {"name", "kind", "clock", "allowed_corners", "corners", "checks", "endpoint_digest", "families", "forbid_false_path_fields"},
        "policy.reset_control",
    )
    if reset["name"] != "soc|emif_adapter|emif_rst_sync1_n" or reset["kind"] != "synchronized_active_low_reset_control":
        raise InvariantError("reset control identity differs")
    if (
        reset["clock"] != RESET_CLOCK
        or not isinstance(reset["allowed_corners"], list)
        or not all(isinstance(item, str) for item in reset["allowed_corners"])
        or set(reset["allowed_corners"]) != KNOWN_CORNERS
    ):
        raise InvariantError("reset timing clock/corner contract differs")
    if reset["corners"] != ["fast", "slow"] or reset["forbid_false_path_fields"] is not True:
        raise InvariantError("reset corner or false-path guard differs")
    _validate_digest(reset["endpoint_digest"], "policy reset endpoint digest")
    checks = _exact_keys(reset["checks"], {"recovery", "removal"}, "policy reset checks")
    for kind, check in checks.items():
        row = _exact_keys(check, {"normalized_path_count", "violated", "require_worst_slack_positive"}, f"policy reset {kind}")
        if _nonnegative_int(row["normalized_path_count"], f"policy reset {kind} count") <= 0 or row["violated"] != 0 or row["require_worst_slack_positive"] is not True:
            raise InvariantError(f"policy reset {kind} contract is weakened")
    families = reset["families"]
    if not isinstance(families, list) or not families:
        raise InvariantError("reset endpoint families are empty")
    family_names: set[str] = set()
    for index, family in enumerate(families):
        row = _exact_keys(family, {"name", "pattern", "normalized_path_count", "endpoint_digest"}, f"policy reset family {index}")
        if row["name"] in family_names:
            raise InvariantError("reset family names repeat")
        family_names.add(row["name"])
        try:
            re.compile(row["pattern"])
        except (TypeError, re.error) as exc:
            raise InvariantError(f"reset family pattern is invalid: {exc}") from exc
        _nonnegative_int(row["normalized_path_count"], f"policy reset family {row['name']} count")
        _validate_digest(row["endpoint_digest"], f"policy reset family {row['name']} digest")
    if sum(item["normalized_path_count"] for item in families) != checks["recovery"]["normalized_path_count"]:
        raise InvariantError("reset family counts do not close")

    provenance = _exact_keys(
        policy["provenance"],
        {"required_candidate_keys", "accepted_profiles", "report_profiles"},
        "policy.provenance",
    )
    required_candidate = {
        "task_id",
        "candidate_sha",
        "candidate_tree_sha",
        "branch",
        "worktree",
        "candidate_manifest",
        "user_sdc_sha256",
        "generated_sdc_sha256",
        "quartus",
        "device",
        "report_only",
        "source_pre_manifest_sha256",
        "source_post_manifest_sha256",
    }
    if provenance["required_candidate_keys"] != sorted(required_candidate):
        raise InvariantError("required candidate provenance keys differ")
    profiles = provenance["accepted_profiles"]
    if not isinstance(profiles, dict) or not profiles:
        raise InvariantError("accepted provenance profiles are empty")
    for profile_id, profile in profiles.items():
        row = _exact_keys(profile, required_candidate - {"task_id"}, f"policy provenance profile {profile_id}")
        if not isinstance(profile_id, str) or not profile_id:
            raise InvariantError("provenance profile id is invalid")
        if not HEX40.fullmatch(str(row["candidate_sha"])):
            raise InvariantError(f"profile {profile_id} candidate_sha is invalid")
        tree = row["candidate_tree_sha"]
        if tree is not None and not HEX40.fullmatch(str(tree)):
            raise InvariantError(f"profile {profile_id} candidate_tree_sha is invalid")
        for key in ("user_sdc_sha256", "generated_sdc_sha256", "source_pre_manifest_sha256", "source_post_manifest_sha256"):
            _validate_digest(row[key], f"profile {profile_id} {key}")
        if row["source_pre_manifest_sha256"] != row["source_post_manifest_sha256"] or row["report_only"] is not True:
            raise InvariantError(f"profile {profile_id} is not an immutable report-only source")
    report_profiles = provenance["report_profiles"]
    report_labels = {"summary", "ucp_fast", "ucp_slow", "fast_recovery", "fast_removal", "slow_recovery", "slow_removal"}
    if not isinstance(report_profiles, dict):
        raise InvariantError("provenance report_profiles must be an object")
    if policy["policy_id"] == POLICY_ID:
        if set(report_profiles) != set(profiles):
            raise InvariantError("production report profiles do not cover every measurement profile")
        for profile_id, report_profile in report_profiles.items():
            row = _exact_keys(report_profile, report_labels, f"policy report profile {profile_id}")
            for label, digest in row.items():
                _validate_digest(digest, f"policy report profile {profile_id}/{label}")
    elif report_profiles != {}:
        raise InvariantError("fixture policy may not whitelist production raw report hashes")

    forbidden = _exact_keys(policy["forbidden"], {"reset_false_path_fields", "jtag_clock_period_fields"}, "policy.forbidden")
    if not forbidden["reset_false_path_fields"] or not forbidden["jtag_clock_period_fields"]:
        raise InvariantError("forbidden field lists are empty")
    if policy["policy_id"] == POLICY_ID and _digest(policy) != PRODUCTION_POLICY_DIGEST:
        raise InvariantError("production invariant policy differs from the reviewed canonical contract")
    return policy


def _profile(policy: dict[str, Any], value: dict[str, Any]) -> dict[str, Any]:
    required = set(policy["provenance"]["required_candidate_keys"])
    measurement = _exact_keys(value, required, "measurement provenance")
    task_id = measurement["task_id"]
    if not isinstance(task_id, str) or not task_id:
        raise InvariantError("measurement provenance task_id must be a non-empty string")
    expected = policy["provenance"]["accepted_profiles"].get(task_id)
    if expected is None or {key: measurement[key] for key in measurement if key != "task_id"} != expected:
        raise InvariantError("measurement provenance differs from the selected reviewed profile")
    return measurement


def _marker(value: str) -> bool:
    return "~duplicate" in value.lower()


def _normalize_endpoint(value: str, where: str) -> tuple[str, bool]:
    if not _marker(value):
        return value, False
    if value.count(DUPLICATE_SUFFIX) != 1 or not value.endswith(DUPLICATE_SUFFIX):
        raise InvariantError(f"{where} contains an illegal duplicate marker")
    base = value[: -len(DUPLICATE_SUFFIX)]
    if not base or _marker(base):
        raise InvariantError(f"{where} contains a nested or empty duplicate marker")
    return base, True


def _hierarchy_classes(policy: dict[str, Any]) -> dict[str, dict[str, Any]]:
    return {item["class"]: item for item in policy["jtag_hierarchy"]["allowed_classes"]}


def _classify_ucp(member: dict[str, str], policy: dict[str, Any]) -> str:
    pair = policy["jtag_hierarchy"]["reserved_port_pair"]
    if member["from"] == pair["from"] and member["to"] == pair["to"]:
        return pair["class"]
    endpoint = member["to"] if member["from"] in {"altera_reserved_tdi", "altera_reserved_tms"} else member["from"]
    matches = [
        name
        for name, row in _hierarchy_classes(policy).items()
        if name != pair["class"] and fnmatch.fnmatchcase(endpoint, row["pattern"])
    ]
    if len(matches) != 1:
        raise InvariantError(f"normalized UCP endpoint has {len(matches)} hierarchy classes: {endpoint!r}")
    return matches[0]


def _normalize_port_rows(
    rows: Sequence[dict[str, str]],
    port: dict[str, Any],
    policy: dict[str, Any],
    model: str,
) -> dict[str, Any]:
    name = port["name"]
    direction = port["direction"]
    selected = [row for row in rows if row["from"] == name] if direction == "input" else [row for row in rows if row["to"] == name]
    if not selected:
        raise InvariantError(f"{model} UCP port {name} has no raw paths")
    normalized: list[dict[str, str]] = []
    duplicate_pairs: list[dict[str, str]] = []
    raw_keys = {(row["from"], row["to"], row["clock"]) for row in selected}
    normalized_keys: Counter[tuple[str, str, str]] = Counter()
    for index, row in enumerate(selected):
        if row["clock"] or _marker(row["clock"]):
            raise InvariantError(f"{model} UCP {name} row {index} has a non-empty clock field")
        internal_field = "to" if direction == "input" else "from"
        external_field = "from" if direction == "input" else "to"
        if row[external_field] != name or _marker(row[external_field]):
            raise InvariantError(f"{model} UCP {name} row {index} has a wrong/marked port field")
        pair = policy["jtag_hierarchy"]["reserved_port_pair"]
        is_reserved = row["from"] == pair["from"] and row["to"] == pair["to"]
        if is_reserved:
            if _marker(row[internal_field]):
                raise InvariantError("reserved TDI/TDO loopback may not carry a duplicate marker")
            base_endpoint, duplicate = row[internal_field], False
        else:
            base_endpoint, duplicate = _normalize_endpoint(row[internal_field], f"{model} UCP {name} row {index}")
        member = dict(row)
        member[internal_field] = base_endpoint
        key = (member["from"], member["to"], member["clock"])
        normalized_keys[key] += 1
        if duplicate:
            base_key = list(key)
            base_key[1 if internal_field == "to" else 0] = base_endpoint
            if tuple(base_key) not in raw_keys:
                raise InvariantError(f"{model} UCP duplicate has no identical base row: {row[internal_field]!r}")
            duplicate_pairs.append({"raw_endpoint": row[internal_field], "base_endpoint": base_endpoint})
        normalized.append(member)
    if any(count > 2 for count in normalized_keys.values()):
        raise InvariantError(f"{model} UCP {name} has more than one physical duplicate for a base")
    members = _sorted_members({json.dumps(row, sort_keys=True): row for row in normalized}.values())
    groups: dict[str, list[dict[str, str]]] = {}
    for member in members:
        groups.setdefault(_classify_ucp(member, policy), []).append(member)
    group_counts = {group: len(values) for group, values in sorted(groups.items())}
    if len(members) != port["normalized_path_count"] or group_counts != port["path_groups"]:
        raise InvariantError(f"{model} UCP normalized membership/group count differs for {name}")
    digest = _digest(members)
    if digest != port["endpoint_digest"]:
        raise InvariantError(f"{model} UCP normalized endpoint digest differs for {name}")
    return {
        "name": name,
        "direction": direction,
        "raw_path_count": len(selected),
        "normalized_path_count": len(members),
        "duplicate_count": len(duplicate_pairs),
        "duplicates": sorted(duplicate_pairs, key=lambda row: (row["base_endpoint"], row["raw_endpoint"])),
        "endpoint_digest": digest,
        "normalized_members": members,
        "path_groups": {
            group: {
                "count": len(values),
                "member_digest": _digest(_sorted_members(values)),
                "hierarchy": next(
                    (
                        policy["jtag_hierarchy"]["reserved_port_pair"]["from"]
                        + " -> "
                        + policy["jtag_hierarchy"]["reserved_port_pair"]["to"]
                        if group == "reserved_jtag_port"
                        else value["to"] if direction == "input" else value["from"]
                    )
                    for value in values
                ),
            }
            for group, values in sorted(groups.items())
        },
    }


def _normalize_ucp(data: v1.UcpData, policy: dict[str, Any], model: str) -> dict[str, Any]:
    if any(_marker(row["from"]) or _marker(row["clock"]) for row in data.input_paths):
        raise InvariantError(f"{model} UCP input path contains a marker in a port/clock field")
    if any(_marker(row["to"]) or _marker(row["clock"]) for row in data.output_paths):
        raise InvariantError(f"{model} UCP output path contains a marker in a port/clock field")
    expected_clock_rows = {item["name"]: item for item in policy["ucp"]["clocks"]}
    observed_clock_rows = {row["target"]: row for row in data.unconstrained_clocks}
    if set(observed_clock_rows) != set(expected_clock_rows):
        raise InvariantError(f"{model} unconstrained clocks differ from the exact pair")
    clocks: list[dict[str, str]] = []
    for name in sorted(expected_clock_rows):
        raw = observed_clock_rows[name]
        expected = expected_clock_rows[name]
        if raw["clock"] != expected["clock_field"] or raw["type"] != expected["type"] or raw["status"].lower() != expected["status"]:
            raise InvariantError(f"{model} unconstrained clock metadata differs for {name}")
        if any(marker in " ".join(raw.values()).lower() for marker in ("period", "create_clock")):
            raise InvariantError(f"{model} unconstrained clock contains a forbidden clock assignment")
        clocks.append({"name": name, "status": expected["status"], "kind": expected["kind"], "type": raw["type"], "clock_field": raw["clock"]})

    expected_ports = {item["name"]: item for item in policy["ucp"]["ports"]}
    observed_ports = {row["name"]: row["direction"] for row in (*data.input_ports, *data.output_ports)}
    if observed_ports != {name: row["direction"] for name, row in expected_ports.items()}:
        raise InvariantError(f"{model} UCP port names/directions differ")
    ports = []
    for name in sorted(expected_ports):
        port = expected_ports[name]
        raw_rows = data.input_paths if port["direction"] == "input" else data.output_paths
        ports.append(_normalize_port_rows(raw_rows, port, policy, model))
    if sum(row["raw_path_count"] for row in ports if row["direction"] == "input") != len(data.input_paths):
        raise InvariantError(f"{model} UCP contains an input path outside the exact port set")
    if sum(row["raw_path_count"] for row in ports if row["direction"] == "output") != len(data.output_paths):
        raise InvariantError(f"{model} UCP contains an output path outside the exact port set")
    summary = {
        "clock_count": len(clocks),
        "input_port_count": sum(row["direction"] == "input" for row in ports),
        "input_path_count": sum(row["normalized_path_count"] for row in ports if row["direction"] == "input"),
        "output_port_count": sum(row["direction"] == "output" for row in ports),
        "output_path_count": sum(row["normalized_path_count"] for row in ports if row["direction"] == "output"),
    }
    if summary != policy["ucp"]["summary"]:
        raise InvariantError(f"{model} normalized UCP summary differs from policy")
    return {"summary": summary, "clocks": clocks, "ports": ports}


def _ucp_invariant(first: dict[str, Any], second: dict[str, Any]) -> None:
    if first["summary"] != second["summary"] or first["clocks"] != second["clocks"]:
        raise InvariantError("fast/slow normalized UCP object identity differs")
    first_ports = {row["name"]: row for row in first["ports"]}
    second_ports = {row["name"]: row for row in second["ports"]}
    for name in first_ports:
        for key in ("direction", "normalized_path_count", "endpoint_digest", "normalized_members", "path_groups"):
            if key == "path_groups":
                left = {group: (value["count"], value["member_digest"]) for group, value in first_ports[name][key].items()}
                right = {group: (value["count"], value["member_digest"]) for group, value in second_ports[name][key].items()}
                if left != right:
                    raise InvariantError(f"fast/slow normalized UCP path groups differ for {name}")
            elif first_ports[name][key] != second_ports[name][key]:
                raise InvariantError(f"fast/slow normalized UCP membership differs for {name}")


def _normalize_timing(data: v1.TimingData, policy: dict[str, Any], model: str, kind: str) -> dict[str, Any]:
    reset = policy["reset_control"]
    raw_endpoints = {row["to"] for row in data.rows}
    normalized_endpoints: set[str] = set()
    duplicate_pairs: list[dict[str, str]] = []
    counts: Counter[str] = Counter()
    for index, row in enumerate(data.rows):
        if row["from"] != reset["name"] or _marker(row["from"]):
            raise InvariantError(f"{model} {kind} row {index} reset source differs")
        if row["launch_clock"] != reset["clock"] or row["latch_clock"] != reset["clock"] or _marker(row["launch_clock"]) or _marker(row["latch_clock"]):
            raise InvariantError(f"{model} {kind} row {index} clock identity differs")
        if row["corner"] not in set(reset["allowed_corners"]):
            raise InvariantError(f"{model} {kind} row {index} has an unknown corner")
        if not math.isfinite(row["slack"]) or row["slack"] <= 0.0:
            raise InvariantError(f"{model} {kind} row {index} slack is not strictly positive")
        base, duplicate = _normalize_endpoint(row["to"], f"{model} {kind} row {index}")
        counts[base] += 1
        if duplicate:
            if base not in raw_endpoints:
                raise InvariantError(f"{model} {kind} duplicate has no base endpoint: {row['to']!r}")
            duplicate_pairs.append({"raw_endpoint": row["to"], "base_endpoint": base})
        normalized_endpoints.add(base)
    if any(count > 2 for count in counts.values()):
        raise InvariantError(f"{model} {kind} has more than one duplicate for a logical endpoint")
    members = sorted(normalized_endpoints)
    check = reset["checks"][kind]
    digest = _digest(members)
    if len(members) != check["normalized_path_count"] or digest != reset["endpoint_digest"]:
        raise InvariantError(f"{model} {kind} normalized reset endpoint membership differs")

    family_rows: dict[str, list[str]] = {item["name"]: [] for item in reset["families"]}
    for endpoint in members:
        matches = [item for item in reset["families"] if re.fullmatch(item["pattern"], endpoint)]
        if len(matches) != 1:
            raise InvariantError(f"reset endpoint has {len(matches)} family matches: {endpoint!r}")
        family_rows[matches[0]["name"]].append(endpoint)
    families: dict[str, Any] = {}
    for item in reset["families"]:
        values = sorted(family_rows[item["name"]])
        observed_digest = _digest(values)
        if len(values) != item["normalized_path_count"] or observed_digest != item["endpoint_digest"]:
            raise InvariantError(f"{model} {kind} reset family differs: {item['name']}")
        families[item["name"]] = {"count": len(values), "endpoint_digest": observed_digest}
    if data.violated != check["violated"] or data.worst_slack_ns <= 0.0:
        raise InvariantError(f"{model} {kind} reset timing does not have positive zero-violation closure")
    return {
        "raw_path_count": data.path_count,
        "normalized_path_count": len(members),
        "duplicate_count": len(duplicate_pairs),
        "duplicates": sorted(duplicate_pairs, key=lambda row: (row["base_endpoint"], row["raw_endpoint"])),
        "violated": data.violated,
        "worst_slack_ns": data.worst_slack_ns,
        "endpoint_digest": digest,
        "observed_corners": sorted({row["corner"] for row in data.rows}),
        "families": families,
        "normalized_members": members,
    }


def _report_identity(paths: dict[str, Path]) -> list[dict[str, Any]]:
    rows = []
    for label, path in sorted(paths.items()):
        try:
            payload = path.read_bytes()
        except OSError as exc:
            raise InvariantError(f"cannot hash report {path}: {exc}") from exc
        rows.append({"label": label, "name": path.name, "bytes": len(payload), "sha256": hashlib.sha256(payload).hexdigest()})
    return rows


def _validate_report_profile(policy: dict[str, Any], task_id: str, reports: list[dict[str, Any]]) -> None:
    if policy["policy_id"] != POLICY_ID:
        return
    expected = policy["provenance"]["report_profiles"].get(task_id)
    actual = {row["label"]: row["sha256"] for row in reports}
    if expected is None or actual != expected:
        raise InvariantError("raw report hashes differ from the selected measurement profile")


def _file_identity(label: str, path: Path) -> dict[str, Any]:
    try:
        payload = path.read_bytes()
    except OSError as exc:
        raise InvariantError(f"cannot read measurement artifact {path}: {exc}") from exc
    return {
        "label": label,
        "name": path.name,
        "bytes": len(payload),
        "sha256": hashlib.sha256(payload).hexdigest(),
    }


def _measurement_artifacts(args: argparse.Namespace, measurement: dict[str, Any]) -> list[dict[str, Any]]:
    paths = {
        "user_sdc": args.user_sdc.resolve(),
        "generated_sdc": args.generated_sdc.resolve(),
        "source_pre_manifest": args.source_pre_manifest.resolve(),
        "source_post_manifest": args.source_post_manifest.resolve(),
    }
    expected_hashes = {
        "user_sdc": measurement["user_sdc_sha256"],
        "generated_sdc": measurement["generated_sdc_sha256"],
        "source_pre_manifest": measurement["source_pre_manifest_sha256"],
        "source_post_manifest": measurement["source_post_manifest_sha256"],
    }
    rows = [_file_identity(label, path) for label, path in sorted(paths.items())]
    for row in rows:
        if row["sha256"] != expected_hashes[row["label"]]:
            raise InvariantError(f"measurement artifact hash differs for {row['label']}")

    manifest_contract = measurement["candidate_manifest"]
    if manifest_contract is None:
        if args.candidate_manifest is not None:
            raise InvariantError("measurement profile has no candidate manifest but one was supplied")
        return rows
    if args.candidate_manifest is None:
        raise InvariantError("measurement profile requires an explicit candidate manifest")
    manifest_path = args.candidate_manifest.resolve()
    manifest_row = _file_identity("candidate_manifest", manifest_path)
    if manifest_row["sha256"] != manifest_contract["manifest_sha256"]:
        raise InvariantError("candidate manifest file hash differs from the reviewed profile")
    manifest = _load_json(manifest_path, "candidate manifest")
    expected_manifest_fields = {
        "task_id": measurement["task_id"],
        "candidate_sha": measurement["candidate_sha"],
        "candidate_tree_sha": measurement["candidate_tree_sha"],
        "canonical_sha256": manifest_contract["canonical_sha256"],
    }
    for key, expected in expected_manifest_fields.items():
        if manifest.get(key) != expected:
            raise InvariantError(f"candidate manifest field differs: {key}")
    if not isinstance(manifest.get("files"), list) or len(manifest["files"]) != manifest_contract["canonical_entries"]:
        raise InvariantError("candidate manifest canonical entry count differs")
    if not isinstance(manifest.get("qsf_relative_aliases"), list) or len(manifest["qsf_relative_aliases"]) != manifest_contract["qsf_relative_aliases"]:
        raise InvariantError("candidate manifest QSF alias count differs")
    rows.append(manifest_row)
    return sorted(rows, key=lambda row: row["label"])


def _build_inventory(
    policy: dict[str, Any],
    measurement: dict[str, Any],
    summary: v1.SummaryData,
    reports: list[dict[str, Any]],
    measurement_artifacts: list[dict[str, Any]],
    fast_ucp: dict[str, Any],
    slow_ucp: dict[str, Any],
    timing: dict[tuple[str, str], dict[str, Any]],
) -> dict[str, Any]:
    _ucp_invariant(fast_ucp, slow_ucp)
    timing_digests = {row["endpoint_digest"] for row in timing.values()}
    timing_members = {json.dumps(row["normalized_members"], separators=(",", ":")) for row in timing.values()}
    if len(timing_digests) != 1 or len(timing_members) != 1:
        raise InvariantError("fast/slow recovery/removal normalized endpoint sets differ")
    root_members = timing[("fast", "recovery")]["normalized_members"]
    ucp_ports = []
    fast_ports = {row["name"]: row for row in fast_ucp["ports"]}
    slow_ports = {row["name"]: row for row in slow_ucp["ports"]}
    for name in sorted(fast_ports):
        first = fast_ports[name]
        second = slow_ports[name]
        ucp_ports.append(
            {
                "name": name,
                "direction": first["direction"],
                "normalized_path_count": first["normalized_path_count"],
                "endpoint_digest": first["endpoint_digest"],
                "normalized_members": first["normalized_members"],
                "path_groups": first["path_groups"],
                "raw": {
                    "fast": {key: first[key] for key in ("raw_path_count", "duplicate_count", "duplicates")},
                    "slow": {key: second[key] for key in ("raw_path_count", "duplicate_count", "duplicates")},
                },
            }
        )
    timing_output: dict[str, Any] = {}
    for model in ("fast", "slow"):
        timing_output[model] = {}
        for kind in ("recovery", "removal"):
            row = dict(timing[(model, kind)])
            row.pop("normalized_members")
            timing_output[model][kind] = row
    reset = policy["reset_control"]
    family_output = {
        item["name"]: {
            "count": item["normalized_path_count"],
            "endpoint_digest": item["endpoint_digest"],
        }
        for item in reset["families"]
    }
    return {
        "schema_version": 2,
        "inventory_kind": INVENTORY_KIND,
        "provenance": {
            "exporter": EXPORTER_ID,
            "contract_lineage": policy["contract_lineage"],
            "summary_lineage": {
                "producer_task": summary.headers["task"],
                "contract_task": summary.source_task,
                "contract_source_sha": summary.source_sha,
            },
            "measurement": measurement,
            "measurement_artifacts": measurement_artifacts,
        },
        "reports": reports,
        "ucp": {"summary": fast_ucp["summary"], "clocks": fast_ucp["clocks"], "ports": ucp_ports},
        "recovery_removal": {
            "reset_control": reset["name"],
            "kind": reset["kind"],
            "clock": reset["clock"],
            "normalized_path_count": len(root_members),
            "endpoint_digest": _digest(root_members),
            "normalized_members": root_members,
            "families": family_output,
            "corners": timing_output,
        },
        "clock_constraints": [],
        "exceptions": [],
    }


def validate_inventory(policy: dict[str, Any], inventory: dict[str, Any]) -> dict[str, Any]:
    expected_top = set(policy["inventory_schema"]["required_top_level"])
    _exact_keys(inventory, expected_top, "inventory")
    if inventory["schema_version"] != 2 or inventory["inventory_kind"] != INVENTORY_KIND:
        raise InvariantError("inventory identity is not v2")
    provenance = _exact_keys(
        inventory["provenance"],
        {"exporter", "contract_lineage", "summary_lineage", "measurement", "measurement_artifacts"},
        "inventory.provenance",
    )
    if provenance["exporter"] != EXPORTER_ID or provenance["contract_lineage"] != policy["contract_lineage"]:
        raise InvariantError("inventory exporter/contract lineage differs")
    lineage = _exact_keys(
        provenance["summary_lineage"],
        {"producer_task", "contract_task", "contract_source_sha"},
        "inventory summary lineage",
    )
    if (
        lineage["producer_task"] not in {"T-20260909-007", "T-20260909-011"}
        or lineage["contract_task"] != policy["contract_lineage"]["task_id"]
        or lineage["contract_source_sha"] != policy["contract_lineage"]["source_sha"]
    ):
        raise InvariantError("inventory summary lineage differs from v1 contract lineage")
    _profile(policy, provenance["measurement"])
    measurement = provenance["measurement"]
    measurement_artifacts = provenance["measurement_artifacts"]
    expected_measurement_labels = {"user_sdc", "generated_sdc", "source_pre_manifest", "source_post_manifest"}
    if measurement["candidate_manifest"] is not None:
        expected_measurement_labels.add("candidate_manifest")
    if not isinstance(measurement_artifacts, list) or len(measurement_artifacts) != len(expected_measurement_labels):
        raise InvariantError("inventory measurement artifact set is incomplete")
    observed_measurement_labels: set[str] = set()
    for index, artifact in enumerate(measurement_artifacts):
        row = _exact_keys(artifact, {"label", "name", "bytes", "sha256"}, f"inventory measurement artifact {index}")
        if row["label"] in observed_measurement_labels or not isinstance(row["name"], str) or not row["name"]:
            raise InvariantError("inventory measurement artifact identity is empty or repeated")
        observed_measurement_labels.add(row["label"])
        if _nonnegative_int(row["bytes"], "measurement artifact bytes") <= 0:
            raise InvariantError("inventory measurement artifact is empty")
        _validate_digest(row["sha256"], "measurement artifact sha256")
    if observed_measurement_labels != expected_measurement_labels:
        raise InvariantError("inventory measurement artifact labels differ")
    artifacts_by_label = {row["label"]: row for row in measurement_artifacts}
    expected_measurement_hashes = {
        "user_sdc": measurement["user_sdc_sha256"],
        "generated_sdc": measurement["generated_sdc_sha256"],
        "source_pre_manifest": measurement["source_pre_manifest_sha256"],
        "source_post_manifest": measurement["source_post_manifest_sha256"],
    }
    if measurement["candidate_manifest"] is not None:
        expected_measurement_hashes["candidate_manifest"] = measurement["candidate_manifest"]["manifest_sha256"]
    for label, expected_hash in expected_measurement_hashes.items():
        if artifacts_by_label[label]["sha256"] != expected_hash:
            raise InvariantError(f"inventory measurement artifact hash differs for {label}")

    reports = inventory["reports"]
    if not isinstance(reports, list) or len(reports) != 7:
        raise InvariantError("inventory must bind exactly seven raw inputs")
    labels: set[str] = set()
    for index, report in enumerate(reports):
        row = _exact_keys(report, {"label", "name", "bytes", "sha256"}, f"inventory report {index}")
        if row["label"] in labels or not row["name"] or _nonnegative_int(row["bytes"], "report bytes") <= 0:
            raise InvariantError("inventory report identity is empty or repeated")
        labels.add(row["label"])
        _validate_digest(row["sha256"], "inventory report sha256")
    if labels != {"summary", "ucp_fast", "ucp_slow", "fast_recovery", "fast_removal", "slow_recovery", "slow_removal"}:
        raise InvariantError("inventory raw report labels differ")
    _validate_report_profile(policy, provenance["measurement"]["task_id"], reports)

    ucp = _exact_keys(inventory["ucp"], {"summary", "clocks", "ports"}, "inventory.ucp")
    if ucp["summary"] != policy["ucp"]["summary"]:
        raise InvariantError("inventory normalized UCP summary differs")
    expected_clocks = {row["name"]: row for row in policy["ucp"]["clocks"]}
    if not isinstance(ucp["clocks"], list) or {row.get("name") for row in ucp["clocks"] if isinstance(row, dict)} != set(expected_clocks):
        raise InvariantError("inventory UCP clock set differs")
    for row in ucp["clocks"]:
        expected = expected_clocks[row["name"]]
        if row != expected:
            raise InvariantError(f"inventory UCP clock metadata differs for {row['name']}")
    expected_ports = {row["name"]: row for row in policy["ucp"]["ports"]}
    if not isinstance(ucp["ports"], list) or {row.get("name") for row in ucp["ports"] if isinstance(row, dict)} != set(expected_ports):
        raise InvariantError("inventory UCP port set differs")
    for port in ucp["ports"]:
        _exact_keys(port, {"name", "direction", "normalized_path_count", "endpoint_digest", "normalized_members", "path_groups", "raw"}, f"inventory UCP port {port.get('name')}")
        expected = expected_ports[port["name"]]
        members = port["normalized_members"]
        if not isinstance(members, list) or members != _sorted_members(members) or len({json.dumps(row, sort_keys=True) for row in members}) != len(members):
            raise InvariantError(f"inventory UCP members are not sorted/unique for {port['name']}")
        if port["direction"] != expected["direction"] or port["normalized_path_count"] != len(members) or len(members) != expected["normalized_path_count"]:
            raise InvariantError(f"inventory UCP normalized count differs for {port['name']}")
        if _digest(members) != port["endpoint_digest"] or port["endpoint_digest"] != expected["endpoint_digest"]:
            raise InvariantError(f"inventory UCP endpoint digest differs for {port['name']}")
        derived_groups: dict[str, list[dict[str, str]]] = {}
        for index, member in enumerate(members):
            _exact_keys(member, {"from", "to", "clock"}, f"inventory UCP member {port['name']}/{index}")
            if member["clock"] or _marker(member["from"]) or _marker(member["to"]):
                raise InvariantError(f"inventory UCP member is not normalized for {port['name']}")
            if port["direction"] == "input" and member["from"] != port["name"]:
                raise InvariantError(f"inventory UCP input member has the wrong source port for {port['name']}")
            if port["direction"] == "output" and member["to"] != port["name"]:
                raise InvariantError(f"inventory UCP output member has the wrong destination port for {port['name']}")
            derived_groups.setdefault(_classify_ucp(member, policy), []).append(member)
        groups = port["path_groups"]
        if not isinstance(groups, dict) or any(not isinstance(row, dict) for row in groups.values()):
            raise InvariantError(f"inventory UCP path groups are malformed for {port['name']}")
        if {name: row.get("count") for name, row in groups.items()} != expected["path_groups"]:
            raise InvariantError(f"inventory UCP path groups differ for {port['name']}")
        for group, value in groups.items():
            _exact_keys(value, {"count", "member_digest", "hierarchy"}, f"inventory UCP group {port['name']}/{group}")
            _validate_digest(value["member_digest"], "inventory group digest")
            if not isinstance(value["hierarchy"], str) or not value["hierarchy"]:
                raise InvariantError("inventory hierarchy witness is empty")
            group_members = _sorted_members(derived_groups.get(group, []))
            if value["count"] != len(group_members) or value["member_digest"] != _digest(group_members):
                raise InvariantError(f"inventory UCP group membership differs for {port['name']}/{group}")
            if group == policy["jtag_hierarchy"]["reserved_port_pair"]["class"]:
                pair = policy["jtag_hierarchy"]["reserved_port_pair"]
                expected_witness = pair["from"] + " -> " + pair["to"]
                if value["hierarchy"] != expected_witness:
                    raise InvariantError("inventory reserved-port hierarchy witness differs")
            else:
                class_policy = _hierarchy_classes(policy).get(group)
                endpoints = [member["to"] if port["direction"] == "input" else member["from"] for member in group_members]
                if class_policy is None or value["hierarchy"] not in endpoints or not fnmatch.fnmatchcase(value["hierarchy"], class_policy["pattern"]):
                    raise InvariantError(f"inventory hierarchy witness is outside normalized membership for {port['name']}/{group}")
        raw = _exact_keys(port["raw"], {"fast", "slow"}, f"inventory UCP raw {port['name']}")
        for model, value in raw.items():
            row = _exact_keys(value, {"raw_path_count", "duplicate_count", "duplicates"}, f"inventory UCP raw {port['name']}/{model}")
            raw_count = _nonnegative_int(row["raw_path_count"], "inventory UCP raw path count")
            duplicate_count = _nonnegative_int(row["duplicate_count"], "inventory UCP duplicate count")
            if not isinstance(row["duplicates"], list):
                raise InvariantError("inventory UCP duplicates must be a list")
            if raw_count != len(members) + duplicate_count or duplicate_count != len(row["duplicates"]):
                raise InvariantError("inventory UCP raw/duplicate counts do not close")
            seen_duplicate_bases: set[str] = set()
            for duplicate in row["duplicates"]:
                pair = _exact_keys(duplicate, {"raw_endpoint", "base_endpoint"}, "inventory UCP duplicate")
                if pair["raw_endpoint"] != pair["base_endpoint"] + DUPLICATE_SUFFIX or pair["base_endpoint"] in seen_duplicate_bases:
                    raise InvariantError("inventory UCP duplicate metadata is invalid")
                seen_duplicate_bases.add(pair["base_endpoint"])
                internal_values = [member["to"] if port["direction"] == "input" else member["from"] for member in members]
                if pair["base_endpoint"] not in internal_values:
                    raise InvariantError("inventory UCP duplicate base is absent from normalized membership")

    reset = _exact_keys(
        inventory["recovery_removal"],
        {"reset_control", "kind", "clock", "normalized_path_count", "endpoint_digest", "normalized_members", "families", "corners"},
        "inventory.recovery_removal",
    )
    reset_policy = policy["reset_control"]
    members = reset["normalized_members"]
    if not isinstance(members, list) or not all(isinstance(item, str) for item in members) or members != sorted(members) or len(set(members)) != len(members):
        raise InvariantError("inventory reset members are not sorted/unique")
    if reset["reset_control"] != reset_policy["name"] or reset["kind"] != reset_policy["kind"] or reset["clock"] != reset_policy["clock"]:
        raise InvariantError("inventory reset identity differs")
    if reset["normalized_path_count"] != len(members) or _digest(members) != reset["endpoint_digest"] or reset["endpoint_digest"] != reset_policy["endpoint_digest"]:
        raise InvariantError("inventory reset endpoint membership differs")
    derived_family_members: dict[str, list[str]] = {row["name"]: [] for row in reset_policy["families"]}
    for endpoint in members:
        if not isinstance(endpoint, str) or _marker(endpoint):
            raise InvariantError("inventory reset endpoint is not a normalized string")
        matches = [row for row in reset_policy["families"] if re.fullmatch(row["pattern"], endpoint)]
        if len(matches) != 1:
            raise InvariantError(f"inventory reset endpoint has {len(matches)} family matches: {endpoint!r}")
        derived_family_members[matches[0]["name"]].append(endpoint)
    expected_families = {row["name"]: {"count": row["normalized_path_count"], "endpoint_digest": row["endpoint_digest"]} for row in reset_policy["families"]}
    if reset["families"] != expected_families:
        raise InvariantError("inventory reset family contract differs")
    for name, values in derived_family_members.items():
        expected_family = expected_families[name]
        if len(values) != expected_family["count"] or _digest(sorted(values)) != expected_family["endpoint_digest"]:
            raise InvariantError(f"inventory reset family membership differs for {name}")
    corners = _exact_keys(reset["corners"], {"fast", "slow"}, "inventory reset corners")
    for model, checks in corners.items():
        _exact_keys(checks, {"recovery", "removal"}, f"inventory reset corner {model}")
        for kind, value in checks.items():
            row = _exact_keys(value, {"raw_path_count", "normalized_path_count", "duplicate_count", "duplicates", "violated", "worst_slack_ns", "endpoint_digest", "observed_corners", "families"}, f"inventory reset {model}/{kind}")
            if row["normalized_path_count"] != len(members) or row["endpoint_digest"] != reset["endpoint_digest"] or row["families"] != expected_families:
                raise InvariantError(f"inventory reset {model}/{kind} normalized set differs")
            raw_count = _nonnegative_int(row["raw_path_count"], "inventory reset raw path count")
            duplicate_count = _nonnegative_int(row["duplicate_count"], "inventory reset duplicate count")
            if not isinstance(row["duplicates"], list):
                raise InvariantError(f"inventory reset {model}/{kind} duplicates must be a list")
            if raw_count != len(members) + duplicate_count or duplicate_count != len(row["duplicates"]):
                raise InvariantError(f"inventory reset {model}/{kind} raw/duplicate counts do not close")
            if row["violated"] != 0 or not isinstance(row["worst_slack_ns"], (int, float)) or isinstance(row["worst_slack_ns"], bool) or not math.isfinite(row["worst_slack_ns"]) or row["worst_slack_ns"] <= 0:
                raise InvariantError(f"inventory reset {model}/{kind} timing is not positive and violation-free")
            if not isinstance(row["observed_corners"], list) or not row["observed_corners"] or not all(isinstance(item, str) for item in row["observed_corners"]) or not set(row["observed_corners"]).issubset(KNOWN_CORNERS):
                raise InvariantError(f"inventory reset {model}/{kind} corners differ")
            seen_duplicate_bases: set[str] = set()
            for duplicate in row["duplicates"]:
                pair = _exact_keys(duplicate, {"raw_endpoint", "base_endpoint"}, "inventory reset duplicate")
                if pair["raw_endpoint"] != pair["base_endpoint"] + DUPLICATE_SUFFIX or pair["base_endpoint"] not in members or pair["base_endpoint"] in seen_duplicate_bases:
                    raise InvariantError("inventory reset duplicate metadata is invalid")
                seen_duplicate_bases.add(pair["base_endpoint"])
    if inventory["clock_constraints"] != [] or inventory["exceptions"] != policy["inventory_schema"]["exceptions_exact"]:
        raise InvariantError("inventory contains clock constraints or exceptions")
    return {
        "status": "PASS",
        "task_id": provenance["measurement"]["task_id"],
        "normalized_ucp_input_paths": ucp["summary"]["input_path_count"],
        "normalized_reset_paths": reset["normalized_path_count"],
    }


def export_inventory(args: argparse.Namespace) -> dict[str, Any]:
    policy = _policy(args.policy.resolve(), args.allow_fixture_policy)
    measurement = _profile(policy, _load_json(args.provenance.resolve(), "measurement provenance"))
    measurement_artifacts = _measurement_artifacts(args, measurement)
    try:
        summary = v1._parse_summary(args.summary.resolve())
        paths = {
            "summary": args.summary.resolve(),
            "ucp_fast": args.ucp_fast.resolve(),
            "ucp_slow": args.ucp_slow.resolve(),
            "fast_recovery": args.fast_recovery.resolve(),
            "fast_removal": args.fast_removal.resolve(),
            "slow_recovery": args.slow_recovery.resolve(),
            "slow_removal": args.slow_removal.resolve(),
        }
        output = args.output.resolve()
        protected_inputs = {
            args.policy.resolve(),
            args.provenance.resolve(),
            args.user_sdc.resolve(),
            args.generated_sdc.resolve(),
            args.source_pre_manifest.resolve(),
            args.source_post_manifest.resolve(),
        }
        if args.candidate_manifest is not None:
            protected_inputs.add(args.candidate_manifest.resolve())
        if output in paths.values() or output in protected_inputs:
            raise InvariantError("output aliases a policy, provenance, measurement, or raw report input")
        fast_raw = v1._parse_ucp(paths["ucp_fast"], "fast")
        slow_raw = v1._parse_ucp(paths["ucp_slow"], "slow")
        reset_name = policy["reset_control"]["name"]
        timing_raw = {
            ("fast", "recovery"): v1._parse_timing(paths["fast_recovery"], "recovery", reset_name),
            ("fast", "removal"): v1._parse_timing(paths["fast_removal"], "removal", reset_name),
            ("slow", "recovery"): v1._parse_timing(paths["slow_recovery"], "recovery", reset_name),
            ("slow", "removal"): v1._parse_timing(paths["slow_removal"], "removal", reset_name),
        }
        reset_expected = {f"{model}_{kind}": value.path_count for (model, kind), value in timing_raw.items()}
        detail = v1._validate_summary_records(summary, {key: value for key, value in paths.items() if key != "summary"}, reset_expected)
        for key, rows in detail.items():
            raw = timing_raw[key].rows
            if len(rows) != len(raw) or any(not math.isclose(item["slack"], raw[index]["slack"], rel_tol=0.0, abs_tol=1e-9) for index, item in enumerate(rows)):
                raise InvariantError(f"summary/raw timing rows differ for {key[0]} {key[1]}")
    except v1.ExportError as exc:
        raise InvariantError(str(exc)) from exc

    fast_ucp = _normalize_ucp(fast_raw, policy, "fast")
    slow_ucp = _normalize_ucp(slow_raw, policy, "slow")
    timing = {key: _normalize_timing(value, policy, *key) for key, value in timing_raw.items()}
    report_rows = _report_identity(paths)
    _validate_report_profile(policy, measurement["task_id"], report_rows)
    inventory = _build_inventory(
        policy,
        measurement,
        summary,
        report_rows,
        measurement_artifacts,
        fast_ucp,
        slow_ucp,
        timing,
    )
    validate_inventory(policy, inventory)
    return inventory


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--policy", type=Path, default=Path(__file__).resolve().parents[1] / "physical_waivers_invariant.json")
    parser.add_argument("--provenance", type=Path, required=True)
    parser.add_argument("--user-sdc", type=Path, required=True)
    parser.add_argument("--generated-sdc", type=Path, required=True)
    parser.add_argument("--source-pre-manifest", type=Path, required=True)
    parser.add_argument("--source-post-manifest", type=Path, required=True)
    parser.add_argument("--candidate-manifest", type=Path)
    parser.add_argument("--summary", type=Path, required=True)
    parser.add_argument("--ucp-fast", type=Path, required=True)
    parser.add_argument("--ucp-slow", type=Path, required=True)
    parser.add_argument("--fast-recovery", type=Path, required=True)
    parser.add_argument("--fast-removal", type=Path, required=True)
    parser.add_argument("--slow-recovery", type=Path, required=True)
    parser.add_argument("--slow-removal", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--allow-fixture-policy", action="store_true", help=argparse.SUPPRESS)
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    try:
        inventory = export_inventory(args)
        args.output.resolve().parent.mkdir(parents=True, exist_ok=True)
        args.output.resolve().write_text(json.dumps(inventory, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    except (InvariantError, OSError, TypeError, KeyError, ValueError) as exc:
        print("PHYSICAL_WAIVER_INVARIANT_EXPORT_FAIL", file=sys.stderr)
        print(f"- {exc}", file=sys.stderr)
        return 1
    print(json.dumps({"schema_version": 2, "status": "PASS", "inventory": str(args.output.resolve())}, sort_keys=True))
    print("PHYSICAL_WAIVER_INVARIANT_EXPORT_PASS", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
