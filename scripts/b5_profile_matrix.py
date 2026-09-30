#!/usr/bin/env python3
"""B5 Profile freeze：生成 V82 profile row -> evidence 映射。

输入：
  docs/V82_PROFILE_MANIFEST.md 内嵌 JSON（权威 ROWS）
  build/coverage/b4_random_insn_final.txt（B4 随机覆盖摘要）
  build/coverage/b4_baremetal_cov.json（B4 裸机覆盖摘要）

输出：
  build/coverage/b5_profile_matrix.json

该映射以 manifest 中每行已有的 rtl/sv_tb/cocotb/qemu_oracle 为证据来源；
不把随机/裸机聚合覆盖冒充逐行精确命中。B4 聚合数据单独列在 aggregate 节。
"""

from __future__ import annotations

import json
import re
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
MANIFEST = REPO / "docs" / "V82_PROFILE_MANIFEST.md"
RANDOM_COV = REPO / "build" / "coverage" / "b4_random_insn_final.txt"
BAREMETAL_COV = REPO / "build" / "coverage" / "b4_baremetal_cov.json"
OUT = REPO / "build" / "coverage" / "b5_profile_matrix.json"


def load_manifest() -> list[dict]:
    text = MANIFEST.read_text(encoding="utf-8")
    m = re.search(r"<!-- V82_PROFILE_DATA_START -->\s*```json\n(.*?)\n```",
                  text, re.S)
    if not m:
        raise ValueError("manifest embedded JSON not found")
    return json.loads(m.group(1))["rows"]


def random_summary() -> dict | None:
    if not RANDOM_COV.exists():
        return None
    text = RANDOM_COV.read_text(encoding="utf-8")
    expected = next((l for l in text.splitlines() if l.startswith("# expected_hit")), None)
    observed = next((l for l in text.splitlines() if l.startswith("# observed_families")), None)
    counts = {}
    for line in text.splitlines():
        if line.startswith("#") or not line.strip():
            continue
        parts = line.split()
        if len(parts) == 2:
            counts[parts[0]] = int(parts[1])
    return {"expected_hit": expected, "observed_families": observed,
            "family_counts": counts}


def baremetal_summary() -> dict | None:
    if not BAREMETAL_COV.exists():
        return None
    data = json.loads(BAREMETAL_COV.read_text(encoding="utf-8"))
    return {
        "options": {
            name: {"unique_supported": info["unique_supported"],
                   "unknown_aliases": info["unknown_aliases"]}
            for name, info in data["opt_levels"].items()
        },
        "all_supported_seen": data["all_supported_seen"],
        "missing_supported": data["missing_supported"],
    }


def main() -> int:
    rows = load_manifest()
    matrix = []
    for r in rows:
        matrix.append({
            "row_id": r["row_id"],
            "category": r["category"],
            "status": r["status"],
            "feature": r["feature"],
            "encoding": r["encoding"],
            "required": r["required"],
            "negative": r["negative"],
            "evidence": {
                "rtl": [x.strip() for x in r["rtl"].split(";") if x.strip()],
                "sv_tb": [x.strip() for x in r["sv_tb"].split(";") if x.strip()],
                "cocotb": [x.strip() for x in r["cocotb"].split(";") if x.strip()],
                "qemu_oracle": r["qemu_oracle"],
            },
        })

    result = {
        "format": "LCVEX-B5-PROFILE-MATRIX-1",
        "freeze_branch": "feature/T-20260829-098-b5-profile-freeze",
        "freeze_base_sha": "62192862bfb51fbc32cd0ee45ef1c1f5a0bde444",
        "qemu": "QEMU 11.1.0 (fork commit 84f07211cc5b4fc6a371559bf8a5de4fb068e648)",
        "row_count": len(rows),
        "rows": matrix,
        "aggregate": {
            "random": random_summary(),
            "baremetal": baremetal_summary(),
        },
    }
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(json.dumps(result, ensure_ascii=False, indent=2,
                              sort_keys=True) + "\n", encoding="utf-8")

    by_status = {}
    for r in rows:
        by_status[r["status"]] = by_status.get(r["status"], 0) + 1
    print(f"==> B5 profile matrix rows={len(rows)} statuses={by_status}")
    print(f"==> output: {OUT}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
