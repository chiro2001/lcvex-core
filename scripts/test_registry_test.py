#!/usr/bin/env python3
"""test_registry.py 的无外部依赖单元测试。"""

from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

import test_registry


ROOT = Path(__file__).resolve().parent.parent


def test_default_registry_is_valid() -> None:
    data = test_registry.load_registry()
    assert test_registry.validate_registry(data) == []
    assert len(data["tests"]) >= 5
    assert {item["level"] for item in data["tests"]} == set(test_registry.LEVELS)


def test_filters_cover_domains_levels_and_tags() -> None:
    tests = test_registry.registry_tests(test_registry.load_registry())
    assert [item["id"] for item in test_registry.filter_tests(tests, level="L0")] == [
        "l0.microbench"
    ]
    p6 = test_registry.filter_tests(tests, tag="p6")
    assert {item["id"] for item in p6} == {
        "l2.p6-lse", "l2.p6-lse128", "l2.p6-wfi",
        "l2.p6-timer-el0", "l2.p6-maint-v82",
    }
    assert all(item["domain"] == "difftest-infra" for item in
               test_registry.filter_tests(tests, domain="difftest-infra"))
    assert test_registry.filter_tests(tests, name="GATE-D")[0]["id"] == "l3.gate-d"


def test_source_consistency_is_clean() -> None:
    data = test_registry.load_registry()
    assert test_registry.validate_registry(data) == []
    assert test_registry.source_consistency_errors(data, ROOT) == []


def test_cli_json_and_check() -> None:
    script = ROOT / "scripts" / "test_registry.py"
    check = subprocess.run([sys.executable, str(script), "--check"],
                           check=False, capture_output=True, text=True)
    assert check.returncode == 0, check.stderr
    consistency = subprocess.run(
        [sys.executable, str(script), "--check-consistency"],
        check=False, capture_output=True, text=True,
    )
    assert consistency.returncode == 0, consistency.stderr
    listed = subprocess.run(
        [sys.executable, str(script), "list", "--level", "L4", "--format", "json"],
        check=False, capture_output=True, text=True,
    )
    assert listed.returncode == 0, listed.stderr
    result = json.loads(listed.stdout)
    assert {item["level"] for item in result} == {"L4"}


if __name__ == "__main__":
    test_default_registry_is_valid()
    test_filters_cover_domains_levels_and_tags()
    test_source_consistency_is_clean()
    test_cli_json_and_check()
    print("PASS: test_registry 单元测试")
