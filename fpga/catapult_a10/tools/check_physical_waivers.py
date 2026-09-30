#!/usr/bin/env python3
"""Hermetic checker for the B25 physical UCP/reset waiver contract.

The input is an exported, structured inventory.  This checker deliberately
does not parse Quartus text reports, open a fitted database, inspect the DUT,
or use a host-specific path.  A physical run can therefore export the same
small JSON shape on Windows, Linux, or CI and apply this gate offline.

Usage::

    python3 fpga/catapult_a10/tools/check_physical_waivers.py \
        --inventory build/agents/T-20260909-010/ucp_inventory.json

The positional form is accepted as a convenience.  JSON is always emitted
on stdout; the exit status is the machine-readable gate (0=PASS, 1=FAIL).
"""

from __future__ import annotations

import argparse
import fnmatch
import json
import math
import re
import sys
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_POLICY = ROOT / "physical_waivers.json"
HEX40 = re.compile(r"^[0-9a-fA-F]{40}$")


def _is_int(value: Any) -> bool:
    return isinstance(value, int) and not isinstance(value, bool)


def _is_number(value: Any) -> bool:
    return (
        isinstance(value, (int, float))
        and not isinstance(value, bool)
        and math.isfinite(float(value))
    )


def _exact_keys(value: Any, expected: set[str], where: str, errors: list[str]) -> bool:
    if not isinstance(value, dict):
        errors.append(f"{where} must be an object")
        return False
    actual = set(value)
    missing = sorted(expected - actual)
    extra = sorted(actual - expected)
    if missing:
        errors.append(f"{where} missing keys: {', '.join(missing)}")
    if extra:
        errors.append(f"{where} has unexpected keys: {', '.join(extra)}")
    return not missing and not extra


def _expect(value: Any, expected: Any, where: str, errors: list[str]) -> bool:
    if value != expected:
        errors.append(f"{where} must be {expected!r} (got {value!r})")
        return False
    return True


def _unique_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    """Build one JSON object while rejecting ambiguous duplicate keys."""

    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"duplicate JSON key {key!r}")
        result[key] = value
    return result


def _load_json(path: Path, label: str, errors: list[str]) -> dict[str, Any] | None:
    try:
        with path.open("r", encoding="utf-8") as stream:
            value = json.load(stream, object_pairs_hook=_unique_object)
    except (OSError, json.JSONDecodeError, ValueError) as exc:
        errors.append(f"{label} cannot be read as JSON: {exc}")
        return None
    if not isinstance(value, dict):
        errors.append(f"{label} must contain a JSON object")
        return None
    return value


def _policy_expected_ports(policy: dict[str, Any]) -> dict[str, dict[str, Any]]:
    ports = policy.get("ucp", {}).get("ports", [])
    if not isinstance(ports, list):
        return {}
    result: dict[str, dict[str, Any]] = {}
    for port in ports:
        if isinstance(port, dict) and isinstance(port.get("name"), str):
            result[port["name"]] = port
    return result


def _policy_expected_clocks(policy: dict[str, Any]) -> dict[str, dict[str, Any]]:
    clocks = policy.get("ucp", {}).get("clocks", [])
    if not isinstance(clocks, list):
        return {}
    result: dict[str, dict[str, Any]] = {}
    for clock in clocks:
        if isinstance(clock, dict) and isinstance(clock.get("name"), str):
            result[clock["name"]] = clock
    return result


def _check_policy(policy: dict[str, Any], errors: list[str]) -> bool:
    """Validate that the checked-in policy itself cannot be weakened."""

    good = True
    top = {
        "schema_version",
        "policy_id",
        "contract_source",
        "inventory_schema",
        "ucp",
        "jtag_hierarchy",
        "reset_control",
        "forbidden",
    }
    good &= _exact_keys(policy, top, "policy", errors)
    good &= _expect(policy.get("schema_version"), 1, "policy.schema_version", errors)
    good &= _expect(
        policy.get("policy_id"),
        "B25-PHYSICAL-UCP-WAIVER",
        "policy.policy_id",
        errors,
    )

    source = policy.get("contract_source")
    if _exact_keys(
        source,
        {"task_id", "source_sha", "evidence"},
        "policy.contract_source",
        errors,
    ):
        good &= _expect(
            source.get("task_id"),
            "T-20260909-007",
            "policy.contract_source.task_id",
            errors,
        )
        good &= _expect(
            source.get("source_sha"),
            "702bd8ee5295efe8a2ad9e094d6c12471a1d3089",
            "policy.contract_source.source_sha",
            errors,
        )
        evidence = source.get("evidence")
        good &= isinstance(evidence, str) and not Path(evidence).is_absolute()
        if not good and not isinstance(evidence, str):
            errors.append("policy.contract_source.evidence must be a relative path")
        elif isinstance(evidence, str) and Path(evidence).is_absolute():
            errors.append("policy.contract_source.evidence must not be absolute")

    schema = policy.get("inventory_schema")
    if _exact_keys(
        schema,
        {"kind", "required_top_level", "exceptions_exact"},
        "policy.inventory_schema",
        errors,
    ):
        good &= _expect(
            schema.get("kind"),
            "lcvex-physical-ucp-recovery-removal-v1",
            "policy.inventory_schema.kind",
            errors,
        )
        required_top = schema.get("required_top_level")
        expected_top = [
            "schema_version",
            "inventory_kind",
            "provenance",
            "ucp",
            "recovery_removal",
            "clock_constraints",
            "exceptions",
        ]
        good &= _expect(
            required_top,
            expected_top,
            "policy.inventory_schema.required_top_level",
            errors,
        )
        good &= _expect(
            schema.get("exceptions_exact"),
            [],
            "policy.inventory_schema.exceptions_exact",
            errors,
        )

    ucp = policy.get("ucp")
    if _exact_keys(ucp, {"summary", "clocks", "ports"}, "policy.ucp", errors):
        summary = ucp.get("summary")
        expected_summary = {
            "clock_count": 2,
            "input_port_count": 2,
            "input_path_count": 63,
            "output_port_count": 1,
            "output_path_count": 4,
        }
        if _exact_keys(
            summary,
            set(expected_summary),
            "policy.ucp.summary",
            errors,
        ):
            for key, value in expected_summary.items():
                good &= _expect(summary.get(key), value, f"policy.ucp.summary.{key}", errors)

        clocks = ucp.get("clocks")
        expected_clocks = [
            {
                "name": "altera_reserved_tck",
                "status": "unconstrained",
                "kind": "vendor_generated_jtag_clock",
            },
            {
                "name": "soc|emif_adapter|emif_rst_sync1_n",
                "status": "unconstrained",
                "kind": "synchronized_reset_control",
            },
        ]
        if not isinstance(clocks, list):
            errors.append("policy.ucp.clocks must be a list")
        elif clocks != expected_clocks:
            errors.append("policy.ucp.clocks must match the T-007 exact clock contract")

        expected_ports = [
            {
                "name": "altera_reserved_tdi",
                "direction": "input",
                "path_count": 26,
                "path_groups": {
                    "jtag_uart_alt_jtag_atlantic": 7,
                    "auto_fab_sld": 11,
                    "emif_embedded_jtag": 7,
                    "reserved_jtag_port": 1,
                },
            },
            {
                "name": "altera_reserved_tms",
                "direction": "input",
                "path_count": 37,
                "path_groups": {"auto_fab_sld": 37},
            },
            {
                "name": "altera_reserved_tdo",
                "direction": "output",
                "path_count": 4,
                "path_groups": {"auto_fab_sld": 4},
            },
        ]
        if not isinstance(ucp.get("ports"), list):
            errors.append("policy.ucp.ports must be a list")
        elif ucp.get("ports") != expected_ports:
            errors.append("policy.ucp.ports must match the T-007 exact port/path contract")
    else:
        expected_clocks = []

    hierarchy = policy.get("jtag_hierarchy")
    expected_classes = [
        {
            "class": "jtag_uart_alt_jtag_atlantic",
            "pattern": "jtag_uart_inst|jtag_uart|*alt_jtag_atlantic|*",
            "required": True,
        },
        {
            "class": "auto_fab_sld",
            "pattern": "auto_fab_0|alt_sld_fab_0|*",
            "required": True,
        },
        {
            "class": "emif_embedded_jtag",
            "pattern": "emif|emif_bot|*jtag_phy_embedded_in_jtag_master*",
            "required": True,
        },
        {
            "class": "reserved_jtag_port",
            "pattern": "reserved_jtag_port|altera_reserved_tdo",
            "required": False,
        },
    ]
    if _exact_keys(
        hierarchy,
        {"allowed_classes", "forbid_arbitrary_tck_period", "forbid_jtag_create_clock"},
        "policy.jtag_hierarchy",
        errors,
    ):
        good &= _expect(
            hierarchy.get("allowed_classes"),
            expected_classes,
            "policy.jtag_hierarchy.allowed_classes",
            errors,
        )
        good &= _expect(
            hierarchy.get("forbid_arbitrary_tck_period"),
            True,
            "policy.jtag_hierarchy.forbid_arbitrary_tck_period",
            errors,
        )
        good &= _expect(
            hierarchy.get("forbid_jtag_create_clock"),
            True,
            "policy.jtag_hierarchy.forbid_jtag_create_clock",
            errors,
        )

    reset = policy.get("reset_control")
    if _exact_keys(
        reset,
        {"name", "kind", "corners", "checks", "forbid_false_path_fields"},
        "policy.reset_control",
        errors,
    ):
        good &= _expect(
            reset.get("name"),
            "soc|emif_adapter|emif_rst_sync1_n",
            "policy.reset_control.name",
            errors,
        )
        good &= _expect(
            reset.get("kind"),
            "synchronized_active_low_reset_control",
            "policy.reset_control.kind",
            errors,
        )
        good &= _expect(reset.get("corners"), ["fast", "slow"], "policy.reset_control.corners", errors)
        checks = reset.get("checks")
        expected_checks = {
            "recovery": {
                "path_count": 627,
                "violated": 0,
                "baseline_worst_slack_ns": 1.202,
                "require_worst_slack_positive": True,
            },
            "removal": {
                "path_count": 627,
                "violated": 0,
                "baseline_worst_slack_ns": 0.191,
                "require_worst_slack_positive": True,
            },
        }
        if not isinstance(checks, dict) or checks != expected_checks:
            errors.append("policy.reset_control.checks must match the 627/627 T-007 contract")
        good &= _expect(
            reset.get("forbid_false_path_fields"),
            True,
            "policy.reset_control.forbid_false_path_fields",
            errors,
        )

    forbidden = policy.get("forbidden")
    expected_forbidden = {
        "reset_false_path_fields": [
            "false_path",
            "false_paths",
            "reset_false_path",
            "reset_false_paths",
            "set_false_path",
            "set_false_paths",
        ],
        "jtag_clock_period_fields": [
            "period",
            "period_ns",
            "clock_period",
            "clock_period_ns",
        ],
    }
    if not isinstance(forbidden, dict) or forbidden != expected_forbidden:
        errors.append("policy.forbidden must retain reset false-path and JTAG period guards")

    return bool(good and not errors)


def _hierarchy_classes(policy: dict[str, Any]) -> dict[str, dict[str, Any]]:
    rows = policy.get("jtag_hierarchy", {}).get("allowed_classes", [])
    if not isinstance(rows, list):
        return {}
    return {
        row["class"]: row
        for row in rows
        if isinstance(row, dict) and isinstance(row.get("class"), str)
    }


def _check_provenance(
    provenance: Any,
    policy: dict[str, Any],
    errors: list[str],
) -> None:
    expected_keys = {"source_task", "source_sha", "exporter"}
    if not _exact_keys(provenance, expected_keys, "inventory.provenance", errors):
        return
    source = policy.get("contract_source", {})
    _expect(
        provenance.get("source_task"),
        source.get("task_id"),
        "inventory.provenance.source_task",
        errors,
    )
    source_sha = provenance.get("source_sha")
    if not isinstance(source_sha, str) or not HEX40.fullmatch(source_sha):
        errors.append("inventory.provenance.source_sha must be a 40-digit commit SHA")
    else:
        _expect(
            source_sha,
            source.get("source_sha"),
            "inventory.provenance.source_sha",
            errors,
        )
    exporter = provenance.get("exporter")
    if not isinstance(exporter, str) or exporter != "quartus_sta_structured_inventory_v1":
        errors.append("inventory.provenance.exporter is not the structured inventory exporter")


def _check_ucp(inventory: dict[str, Any], policy: dict[str, Any], errors: list[str]) -> dict[str, Any]:
    report: dict[str, Any] = {}
    ucp = inventory.get("ucp")
    if not _exact_keys(ucp, {"summary", "clocks", "ports"}, "inventory.ucp", errors):
        return report

    expected_summary = policy["ucp"]["summary"]
    summary = ucp.get("summary")
    if _exact_keys(summary, set(expected_summary), "inventory.ucp.summary", errors):
        for key, expected in expected_summary.items():
            _expect(summary.get(key), expected, f"inventory.ucp.summary.{key}", errors)

    expected_clocks = _policy_expected_clocks(policy)
    clocks = ucp.get("clocks")
    actual_clock_names: list[str] = []
    if not isinstance(clocks, list):
        errors.append("inventory.ucp.clocks must be a list")
    else:
        for index, clock in enumerate(clocks):
            where = f"inventory.ucp.clocks[{index}]"
            if not _exact_keys(clock, {"name", "status", "kind"}, where, errors):
                continue
            name = clock.get("name")
            if not isinstance(name, str):
                errors.append(f"{where}.name must be a string")
                continue
            actual_clock_names.append(name)
            expected = expected_clocks.get(name)
            if expected is None:
                errors.append(f"unexpected unconstrained clock: {name}")
            else:
                for key in ("status", "kind"):
                    _expect(clock.get(key), expected.get(key), f"{where}.{key}", errors)
        if set(actual_clock_names) != set(expected_clocks) or len(actual_clock_names) != len(expected_clocks):
            errors.append("inventory.ucp.clocks must contain exactly the two T-007 clocks")
    report["clock_names"] = actual_clock_names
    report["clock_count"] = len(actual_clock_names)

    expected_ports = _policy_expected_ports(policy)
    ports = ucp.get("ports")
    actual_port_names: list[str] = []
    direction_totals = {"input": 0, "output": 0}
    direction_paths = {"input": 0, "output": 0}
    present_classes: set[str] = set()
    if not isinstance(ports, list):
        errors.append("inventory.ucp.ports must be a list")
    else:
        for index, port in enumerate(ports):
            where = f"inventory.ucp.ports[{index}]"
            if not _exact_keys(port, {"name", "direction", "path_count", "path_groups"}, where, errors):
                continue
            name = port.get("name")
            if not isinstance(name, str):
                errors.append(f"{where}.name must be a string")
                continue
            actual_port_names.append(name)
            expected = expected_ports.get(name)
            if expected is None:
                errors.append(f"unexpected unconstrained port: {name}")
                continue
            direction = port.get("direction")
            _expect(direction, expected.get("direction"), f"{where}.direction", errors)
            path_count = port.get("path_count")
            _expect(path_count, expected.get("path_count"), f"{where}.path_count", errors)
            if direction in direction_totals and _is_int(path_count):
                direction_totals[direction] += 1
                direction_paths[direction] += path_count

            expected_groups = expected.get("path_groups", {})
            groups = port.get("path_groups")
            if not isinstance(groups, dict):
                errors.append(f"{where}.path_groups must be an object")
                continue
            if set(groups) != set(expected_groups):
                errors.append(f"{where}.path_groups classes differ from the exact vendor contract")
            for group_class, group in groups.items():
                group_where = f"{where}.path_groups.{group_class}"
                if group_class not in expected_groups:
                    continue
                if not _exact_keys(group, {"count", "hierarchy"}, group_where, errors):
                    continue
                count = group.get("count")
                expected_count = expected_groups[group_class]
                _expect(count, expected_count, f"{group_where}.count", errors)
                if _is_int(count) and count > 0:
                    present_classes.add(group_class)
                hierarchy = group.get("hierarchy")
                if not isinstance(hierarchy, str) or not hierarchy or "\n" in hierarchy:
                    errors.append(f"{group_where}.hierarchy must be a non-empty single-line string")
                    continue
                class_policy = _hierarchy_classes(policy).get(group_class)
                if class_policy is None:
                    errors.append(f"{group_where} uses an unapproved hierarchy class")
                elif not fnmatch.fnmatchcase(hierarchy, class_policy["pattern"]):
                    errors.append(
                        f"{group_where}.hierarchy is outside the approved vendor hierarchy"
                    )

            if isinstance(groups, dict) and all(
                isinstance(group, dict) and _is_int(group.get("count"))
                for group in groups.values()
            ):
                derived = sum(group["count"] for group in groups.values())
                if _is_int(path_count) and derived != path_count:
                    errors.append(f"{where}.path_groups count sum {derived} != path_count {path_count}")

        if set(actual_port_names) != set(expected_ports) or len(actual_port_names) != len(expected_ports):
            errors.append("inventory.ucp.ports must contain exactly TDI, TMS and TDO")

    for required_class, class_policy in _hierarchy_classes(policy).items():
        if class_policy.get("required") and required_class not in present_classes:
            errors.append(f"required vendor hierarchy class missing: {required_class}")

    if isinstance(summary, dict):
        _expect(direction_totals["input"], summary.get("input_port_count"), "derived input port count", errors)
        _expect(direction_paths["input"], summary.get("input_path_count"), "derived input path count", errors)
        _expect(direction_totals["output"], summary.get("output_port_count"), "derived output port count", errors)
        _expect(direction_paths["output"], summary.get("output_path_count"), "derived output path count", errors)
        _expect(len(actual_clock_names), summary.get("clock_count"), "derived clock count", errors)

    report.update(
        {
            "port_names": actual_port_names,
            "summary": summary,
            "required_hierarchy_classes": sorted(present_classes),
        }
    )
    return report


def _check_reset(inventory: dict[str, Any], policy: dict[str, Any], errors: list[str]) -> dict[str, Any]:
    report: dict[str, Any] = {}
    reset_policy = policy["reset_control"]
    reset = inventory.get("recovery_removal")
    if not _exact_keys(reset, {"reset_control", "kind", "corners"}, "inventory.recovery_removal", errors):
        return report
    _expect(reset.get("reset_control"), reset_policy["name"], "inventory.recovery_removal.reset_control", errors)
    _expect(reset.get("kind"), reset_policy["kind"], "inventory.recovery_removal.kind", errors)
    corners = reset.get("corners")
    expected_corners = reset_policy["corners"]
    if not isinstance(corners, dict):
        errors.append("inventory.recovery_removal.corners must be an object")
        return report
    if set(corners) != set(expected_corners):
        errors.append("inventory.recovery_removal.corners must contain exactly fast and slow")

    check_policy = reset_policy["checks"]
    observed: dict[str, Any] = {}
    for corner in expected_corners:
        corner_value = corners.get(corner)
        corner_where = f"inventory.recovery_removal.corners.{corner}"
        if not _exact_keys(corner_value, {"recovery", "removal"}, corner_where, errors):
            continue
        observed[corner] = {}
        for check_name in ("recovery", "removal"):
            check_where = f"{corner_where}.{check_name}"
            check = corner_value.get(check_name)
            if not _exact_keys(check, {"path_count", "violated", "worst_slack_ns"}, check_where, errors):
                continue
            expected = check_policy[check_name]
            path_count = check.get("path_count")
            violated = check.get("violated")
            slack = check.get("worst_slack_ns")
            _expect(path_count, expected["path_count"], f"{check_where}.path_count", errors)
            _expect(violated, expected["violated"], f"{check_where}.violated", errors)
            if not _is_number(slack):
                errors.append(f"{check_where}.worst_slack_ns must be a finite number")
            elif expected["require_worst_slack_positive"] and slack <= 0:
                errors.append(f"{check_where}.worst_slack_ns must be > 0")
            observed[corner][check_name] = {
                "path_count": path_count,
                "violated": violated,
                "worst_slack_ns": slack,
                "baseline_worst_slack_ns": expected["baseline_worst_slack_ns"],
            }
    report["reset_control"] = reset.get("reset_control")
    report["corners"] = observed
    return report


def _string_contains_marker(value: Any, markers: tuple[str, ...]) -> bool:
    return isinstance(value, str) and any(marker in value.lower() for marker in markers)


def _scan_forbidden(
    value: Any,
    policy: dict[str, Any],
    errors: list[str],
    path: str = "inventory",
    reset_context: bool = False,
    jtag_context: bool = False,
) -> None:
    """Reject hidden reset cuts and JTAG clock construction in any section."""

    reset_name = str(policy.get("reset_control", {}).get("name", "")).lower()
    false_fields = {
        str(item).lower()
        for item in policy.get("forbidden", {}).get("reset_false_path_fields", [])
    }
    period_fields = {
        str(item).lower()
        for item in policy.get("forbidden", {}).get("jtag_clock_period_fields", [])
    }
    jtag_markers = (
        "altera_reserved_tck",
        "altera_reserved_tdi",
        "altera_reserved_tms",
        "altera_reserved_tdo",
        "alt_jtag_atlantic",
        "auto_fab",
        "alt_sld",
        "jtag_phy_embedded_in_jtag_master",
        "jtag",
        "sld",
    )

    if isinstance(value, dict):
        value_strings = [item for item in value.values() if isinstance(item, str)]
        local_reset = reset_context or any(reset_name and reset_name in item.lower() for item in value_strings)
        local_jtag = jtag_context or any(_string_contains_marker(item, jtag_markers) for item in value_strings)
        for key, item in value.items():
            key_lower = str(key).lower().replace("-", "_").replace(" ", "_")
            item_path = f"{path}.{key}"
            if key_lower in false_fields or key_lower.startswith("reset_false_path"):
                if local_reset or key_lower.startswith("reset_false_path"):
                    errors.append(f"forbidden reset false-path field at {item_path}")
            if (
                local_reset
                and isinstance(item, str)
                and ("false_path" in item.lower() or "set_false_path" in item.lower())
            ):
                errors.append(f"forbidden reset false-path value at {item_path}")
            if "create_clock" in key_lower or (
                isinstance(item, str) and "create_clock" in item.lower()
            ):
                if local_jtag:
                    errors.append(f"forbidden JTAG create_clock at {item_path}")
            if key_lower in period_fields and local_jtag:
                errors.append(f"forbidden JTAG clock period at {item_path}")
            _scan_forbidden(item, policy, errors, item_path, local_reset, local_jtag)
    elif isinstance(value, list):
        for index, item in enumerate(value):
            _scan_forbidden(item, policy, errors, f"{path}[{index}]", reset_context, jtag_context)


def _check_clock_constraints(
    inventory: dict[str, Any],
    policy: dict[str, Any],
    errors: list[str],
) -> dict[str, Any]:
    constraints = inventory.get("clock_constraints")
    report = {"count": 0, "jtag_constraints": 0}
    if not isinstance(constraints, list):
        errors.append("inventory.clock_constraints must be a list")
        return report
    jtag_markers = (
        "altera_reserved_tck",
        "altera_reserved_tdi",
        "altera_reserved_tms",
        "altera_reserved_tdo",
        "jtag",
        "sld",
        "auto_fab",
    )
    for index, constraint in enumerate(constraints):
        where = f"inventory.clock_constraints[{index}]"
        if not _exact_keys(constraint, {"name", "kind", "period_ns"}, where, errors):
            continue
        name = constraint.get("name")
        kind = constraint.get("kind")
        period = constraint.get("period_ns")
        if not isinstance(name, str) or not name:
            errors.append(f"{where}.name must be a non-empty string")
        if not isinstance(kind, str) or not kind:
            errors.append(f"{where}.kind must be a non-empty string")
        if not _is_number(period) or period <= 0:
            errors.append(f"{where}.period_ns must be a finite positive number")
        if _string_contains_marker(name, jtag_markers) or _string_contains_marker(kind, jtag_markers):
            report["jtag_constraints"] += 1
            errors.append(f"arbitrary JTAG clock constraint is forbidden at {where}")
    report["count"] = len(constraints)
    return report


def _check_inventory(inventory: dict[str, Any], policy: dict[str, Any], errors: list[str]) -> dict[str, Any]:
    expected_top = set(policy["inventory_schema"]["required_top_level"])
    if not _exact_keys(inventory, expected_top, "inventory", errors):
        return {}
    _expect(inventory.get("schema_version"), 1, "inventory.schema_version", errors)
    _expect(
        inventory.get("inventory_kind"),
        policy["inventory_schema"]["kind"],
        "inventory.inventory_kind",
        errors,
    )
    _check_provenance(inventory.get("provenance"), policy, errors)
    ucp_report = _check_ucp(inventory, policy, errors)
    reset_report = _check_reset(inventory, policy, errors)
    constraints_report = _check_clock_constraints(inventory, policy, errors)
    exceptions = inventory.get("exceptions")
    if not isinstance(exceptions, list):
        errors.append("inventory.exceptions must be a list")
    elif exceptions != policy["inventory_schema"]["exceptions_exact"]:
        errors.append("inventory.exceptions must match the exact empty waiver policy")
    _scan_forbidden(inventory, policy, errors)
    return {
        "ucp": ucp_report,
        "recovery_removal": reset_report,
        "clock_constraints": constraints_report,
        "exception_count": len(exceptions) if isinstance(exceptions, list) else 0,
    }


def check_inventory(policy_path: Path, inventory_path: Path) -> dict[str, Any]:
    """Return a deterministic report without writing files or using the network."""

    errors: list[str] = []
    policy = _load_json(policy_path, "policy", errors)
    inventory: dict[str, Any] | None = None
    policy_ok = False
    if policy is not None:
        policy_ok = _check_policy(policy, errors)
    inventory_report: dict[str, Any] = {}
    if policy is not None and policy_ok:
        inventory = _load_json(inventory_path, "inventory", errors)
        if inventory is not None:
            inventory_report = _check_inventory(inventory, policy, errors)
    elif policy is not None:
        # Keep malformed/weak policy failures fail-closed without attempting
        # to index a partially parsed contract below.
        inventory = None

    status = "PASS" if not errors and policy_ok and inventory is not None else "FAIL"
    return {
        "schema_version": 1,
        "status": status,
        "policy_id": policy.get("policy_id") if policy else None,
        "inventory_kind": inventory.get("inventory_kind") if inventory else None,
        "checks": inventory_report,
        "errors": errors,
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("inventory_positional", nargs="?", type=Path)
    parser.add_argument("--inventory", dest="inventory_option", type=Path)
    parser.add_argument("--policy", type=Path, default=DEFAULT_POLICY)
    parser.add_argument(
        "--json",
        action="store_true",
        help="accepted for consistency with repository checkers; JSON is always emitted",
    )
    args = parser.parse_args(argv)
    if args.inventory_option is not None and args.inventory_positional is not None:
        parser.error("use either positional inventory or --inventory, not both")
    inventory = args.inventory_option or args.inventory_positional
    if inventory is None:
        parser.error("an exported inventory is required (--inventory PATH)")

    result = check_inventory(args.policy, inventory)
    print(json.dumps(result, indent=2, sort_keys=True))
    if result["status"] == "PASS":
        print("PHYSICAL_WAIVER_CHECK_PASS", file=sys.stderr)
        return 0
    print("PHYSICAL_WAIVER_CHECK_FAIL", file=sys.stderr)
    for error in result["errors"]:
        print(f"- {error}", file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
