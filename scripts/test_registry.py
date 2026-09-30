#!/usr/bin/env python3
"""LCVEX 分层测试 registry 的校验与查询工具。

该工具只读取 registry 并输出筛选结果，不启动测试、不申请资源，也不替代现有
Gate/锁步 runner。这样可以先统一测试名称、域、层级和标签，再由集成者决定如何
排队执行。

示例：
  python3 scripts/test_registry.py --check
  python3 scripts/test_registry.py --check-consistency
  python3 scripts/test_registry.py list --level L0
  python3 scripts/test_registry.py list --domain difftest-infra --tag checkpoint
  python3 scripts/test_registry.py list --format json --level L2
  python3 scripts/test_registry.py show l3.gate-d
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path
from typing import Any, Iterable


REPO = Path(__file__).resolve().parent.parent
DEFAULT_REGISTRY = Path(__file__).with_name("test_registry.json")
LEVELS = ("L0", "L1", "L2", "L3", "L4")
DOMAINS = (
    "core-isa",
    "mem-subsys",
    "mmio-periph",
    "difftest-infra",
    "verify-suite",
    "fpga-platform",
    "multicore-cluster",
)
KINDS = {"microbench", "unit", "coverage", "smoke", "difftest", "checkpoint",
         "gate", "nightly", "linux"}
STATUSES = {"available", "planned", "disabled"}


class RegistryError(ValueError):
    """registry 格式或内容不符合约定。"""


def load_registry(path: Path = DEFAULT_REGISTRY) -> dict[str, Any]:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except OSError as exc:
        raise RegistryError(f"无法读取 registry：{path}: {exc}") from exc
    except json.JSONDecodeError as exc:
        raise RegistryError(f"registry JSON 无法解析：{path}: {exc}") from exc
    if not isinstance(data, dict):
        raise RegistryError("registry 根节点必须是对象")
    return data


def validate_registry(data: dict[str, Any]) -> list[str]:
    """返回所有校验错误；空列表表示通过。"""
    errors: list[str] = []
    if data.get("schema_version") != 1:
        errors.append("schema_version 必须为 1")
    if not isinstance(data.get("tests"), list) or not data["tests"]:
        errors.append("tests 必须是非空数组")
        return errors

    declared_levels = data.get("levels")
    if declared_levels != list(LEVELS):
        errors.append(f"levels 必须严格为 {list(LEVELS)!r}")
    declared_domains = data.get("domains")
    if declared_domains != list(DOMAINS):
        errors.append(f"domains 必须严格为 {list(DOMAINS)!r}")

    ids: set[str] = set()
    for index, item in enumerate(data["tests"]):
        prefix = f"tests[{index}]"
        if not isinstance(item, dict):
            errors.append(f"{prefix} 必须是对象")
            continue
        for key in ("id", "title", "domain", "level", "kind", "command", "status"):
            if not isinstance(item.get(key), str) or not item[key].strip():
                errors.append(f"{prefix}.{key} 必须是非空字符串")
        test_id = item.get("id")
        if isinstance(test_id, str):
            if test_id in ids:
                errors.append(f"重复测试 ID：{test_id}")
            ids.add(test_id)
        if item.get("domain") not in DOMAINS:
            errors.append(f"{prefix}.domain 不在允许集合：{item.get('domain')!r}")
        if item.get("level") not in LEVELS:
            errors.append(f"{prefix}.level 不在允许集合：{item.get('level')!r}")
        if item.get("kind") not in KINDS:
            errors.append(f"{prefix}.kind 不在允许集合：{item.get('kind')!r}")
        if item.get("status") not in STATUSES:
            errors.append(f"{prefix}.status 不在允许集合：{item.get('status')!r}")
        tags = item.get("tags")
        if not isinstance(tags, list) or not tags or any(
            not isinstance(tag, str) or not tag.strip() for tag in tags
        ):
            errors.append(f"{prefix}.tags 必须是非空字符串数组")
        resource = item.get("resource")
        if not isinstance(resource, dict):
            errors.append(f"{prefix}.resource 必须是对象")
        else:
            for key in ("cpu", "memory_mb", "disk_mb"):
                if not isinstance(resource.get(key), int) or resource[key] < 0:
                    errors.append(f"{prefix}.resource.{key} 必须是非负整数")
        if not isinstance(item.get("default"), bool):
            errors.append(f"{prefix}.default 必须是布尔值")
    return errors


def registry_tests(data: dict[str, Any]) -> list[dict[str, Any]]:
    errors = validate_registry(data)
    if errors:
        raise RegistryError("registry 校验失败：\n" + "\n".join(f"- {e}" for e in errors))
    return list(data["tests"])


def _extract_make_targets(command: str) -> set[str]:
    """从一个 shell 命令片段中提取 make 目标名（仅处理常见简单形式）。"""
    words = command.replace("&&", " ").replace("||", " ").replace(";", " ").split()
    targets: set[str] = set()
    for index, word in enumerate(words):
        if word != "make":
            continue
        j = index + 1
        while j < len(words) and words[j].startswith("-"):
            # 跳过常见带值选项；不认识的长选项按单个词跳过即可。
            if words[j] in ("-C", "-f", "-j", "-o", "-Mdir"):
                j += 2
            else:
                j += 1
        if j < len(words) and re.fullmatch(r"[A-Za-z0-9_.%/-]+", words[j]):
            targets.add(words[j])
    return targets


def _makefile_targets(repo: Path = REPO) -> set[str]:
    """返回 Makefile 中出现的顶层目标名（含变量定义，用于尽力检查）。"""
    makefile = repo / "Makefile"
    if not makefile.exists():
        return set()
    targets: set[str] = set()
    for line in makefile.read_text(encoding="utf-8", errors="replace").splitlines():
        match = re.match(r"^([A-Za-z0-9_.%/-]+)\s*:", line)
        if match:
            targets.add(match.group(1))
    return targets


def _command_mentions_make_target(command: str, target: str) -> bool:
    pattern = r"(?<![A-Za-z0-9_.-])" + re.escape(target) + r"(?![A-Za-z0-9_.-])"
    return "make" in command and re.search(pattern, command) is not None


def source_consistency_errors(data: dict[str, Any], repo: Path = REPO) -> list[str]:
    """反向/前向最小一致性检查。

    反向：registry 中声明的 tracked make/runner 入口必须至少有一个测试命令引用；
    前向：registry 命令引用的 make 目标必须确实存在于 Makefile。
    本检查是“部分清单”守卫，不枚举所有 Makefile 入口。
    """
    errors: list[str] = []
    source = data.get("source_consistency")
    if not isinstance(source, dict):
        return errors

    commands = [
        item.get("command", "")
        for item in data.get("tests", [])
        if isinstance(item, dict) and isinstance(item.get("command"), str)
    ]

    for target in source.get("make_targets", []):
        if not isinstance(target, str) or not target.strip():
            errors.append("source_consistency.make_targets 包含非字符串项")
            continue
        if not any(_command_mentions_make_target(command, target) for command in commands):
            errors.append(f"缺失 registry 条目：Makefile target '{target}' 未被任何 command 引用")

    for script in source.get("scripts", []):
        if not isinstance(script, str) or not script.strip():
            errors.append("source_consistency.scripts 包含非字符串项")
            continue
        normalized = script.replace("\\", "/")
        basename = Path(script).name
        if not any(
            normalized in command.replace("\\", "/") or basename in command
            for command in commands
        ):
            errors.append(f"缺失 registry 条目：runner/script '{script}' 未被任何 command 引用")

    known_targets = _makefile_targets(repo)
    if known_targets:
        for command in commands:
            for target in sorted(_extract_make_targets(command)):
                if target not in known_targets:
                    errors.append(f"registry command 引用了 Makefile 不存在的 target：{target}")

    return errors


def filter_tests(
    tests: Iterable[dict[str, Any]],
    *,
    name: str | None = None,
    domain: str | None = None,
    level: str | None = None,
    tag: str | None = None,
    status: str | None = None,
) -> list[dict[str, Any]]:
    """按字段筛选；name 使用 ID/title 的大小写不敏感子串匹配。"""
    needle = name.lower() if name else None
    result = []
    for item in tests:
        if needle and needle not in item["id"].lower() and needle not in item["title"].lower():
            continue
        if domain and item["domain"] != domain:
            continue
        if level and item["level"] != level:
            continue
        if tag and tag not in item["tags"]:
            continue
        if status and item["status"] != status:
            continue
        result.append(item)
    return result


def _format_text(items: list[dict[str, Any]]) -> str:
    if not items:
        return "（无匹配测试）"
    rows = [("ID", "层", "域", "标题", "标签")]
    rows.extend(
        (item["id"], item["level"], item["domain"], item["title"], ",".join(item["tags"]))
        for item in items
    )
    widths = [max(len(row[col]) for row in rows) for col in range(len(rows[0]))]
    return "\n".join("  ".join(value.ljust(widths[col]) for col, value in enumerate(row))
                      for row in rows)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--registry", type=Path, default=DEFAULT_REGISTRY,
                        help="registry JSON 路径")
    parser.add_argument("--check", action="store_true", help="只校验 registry")
    parser.add_argument("--check-consistency", action="store_true",
                        help="校验 registry 与 Makefile/runner 的最小一致性")
    sub = parser.add_subparsers(dest="command")
    list_parser = sub.add_parser("list", help="列出匹配测试（默认命令）")
    list_parser.add_argument("--name", help="ID/title 子串")
    list_parser.add_argument("--domain", choices=DOMAINS)
    list_parser.add_argument("--level", choices=LEVELS)
    list_parser.add_argument("--tag")
    list_parser.add_argument("--status", choices=sorted(STATUSES))
    list_parser.add_argument("--format", choices=("text", "json"), default="text")
    show_parser = sub.add_parser("show", help="显示一个测试的完整 JSON")
    show_parser.add_argument("id")
    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    if args.command is None and not args.check and not args.check_consistency:
        args.command = "list"
        args.name = args.domain = args.level = args.tag = args.status = None
        args.format = "text"
    try:
        data = load_registry(args.registry)
        errors = validate_registry(data)
        if args.check:
            if errors:
                for error in errors:
                    print(f"ERROR: {error}", file=sys.stderr)
                return 1
            print(f"PASS: registry 校验通过（{len(data['tests'])} 项）")
            if args.check_consistency:
                consistency_errors = source_consistency_errors(data, REPO)
                if consistency_errors:
                    for error in consistency_errors:
                        print(f"ERROR: {error}", file=sys.stderr)
                    return 1
                print("PASS: registry 与 Makefile/runner 最小一致性检查通过")
            return 0
        if args.check_consistency:
            if errors:
                for error in errors:
                    print(f"ERROR: {error}", file=sys.stderr)
                return 1
            consistency_errors = source_consistency_errors(data, REPO)
            if consistency_errors:
                for error in consistency_errors:
                    print(f"ERROR: {error}", file=sys.stderr)
                return 1
            print("PASS: registry 与 Makefile/runner 最小一致性检查通过")
            return 0
        if errors:
            raise RegistryError("registry 校验失败：\n" + "\n".join(f"- {e}" for e in errors))
        tests = list(data["tests"])
        if args.command == "show":
            matches = [item for item in tests if item["id"] == args.id]
            if not matches:
                print(f"ERROR: 未找到测试 ID：{args.id}", file=sys.stderr)
                return 2
            print(json.dumps(matches[0], ensure_ascii=False, indent=2))
            return 0
        items = filter_tests(
            tests,
            name=getattr(args, "name", None),
            domain=getattr(args, "domain", None),
            level=getattr(args, "level", None),
            tag=getattr(args, "tag", None),
            status=getattr(args, "status", None),
        )
        if getattr(args, "format", "text") == "json":
            print(json.dumps(items, ensure_ascii=False, indent=2))
        else:
            print(_format_text(items))
        return 0
    except RegistryError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
