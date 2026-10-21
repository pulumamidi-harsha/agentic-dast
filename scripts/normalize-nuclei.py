#!/usr/bin/env python3
"""Normalize Nuclei JSONL → findings list (agentic finding schema)."""
from __future__ import annotations

import json
import sys
from pathlib import Path
from typing import Any, Dict, List


def sev_map(sev: str) -> str:
    s = (sev or "info").lower()
    if s in ("critical", "high"):
        return "error"
    if s in ("medium", "unknown"):
        return "warning"
    return "info"


def normalize_line(obj: Dict[str, Any]) -> Dict[str, Any]:
    info = obj.get("info") or {}
    name = info.get("name") or obj.get("template-id") or "nuclei finding"
    severity = sev_map(info.get("severity") or "")
    template_id = obj.get("template-id") or obj.get("templateID") or name
    matched = obj.get("matched-at") or obj.get("host") or obj.get("url") or None
    description = (info.get("description") or "").strip()
    remediation = None
    meta = info.get("metadata") or {}
    if isinstance(meta, dict) and meta.get("remediation"):
        remediation = str(meta["remediation"])
    msg = name
    if description:
        msg = f"{name}: {description[:240]}"
    return {
        "engine": "nuclei",
        "rule_id": f"nuclei.{template_id}",
        "severity": severity,
        "category": "security",
        "path": matched,
        "start_line": None,
        "end_line": None,
        "message": msg[:500],
        "remediation": remediation,
        "in_pr_diff": False,
        "fingerprint": f"nuclei:{template_id}:{matched or ''}"[:200],
        "raw": {
            "template-id": template_id,
            "severity": info.get("severity"),
            "tags": info.get("tags"),
            "type": obj.get("type"),
        },
    }


def main() -> int:
    if len(sys.argv) < 3:
        print(
            "usage: normalize-nuclei.py <nuclei.jsonl|json> <out-findings.json>",
            file=sys.stderr,
        )
        return 2
    src = Path(sys.argv[1])
    out = Path(sys.argv[2])
    if not src.is_file():
        out.write_text("[]\n", encoding="utf-8")
        print(f"  Nuclei report missing ({src}) — empty findings")
        return 0

    findings: List[Dict[str, Any]] = []
    text = src.read_text(encoding="utf-8", errors="replace").strip()
    if not text:
        out.write_text("[]\n", encoding="utf-8")
        print("  Nuclei: empty report")
        return 0

    # JSONL (one object per line) or a JSON array
    if text.startswith("["):
        try:
            arr = json.loads(text)
            for obj in arr:
                if isinstance(obj, dict):
                    findings.append(normalize_line(obj))
        except json.JSONDecodeError as e:
            print(f"::warning::Invalid Nuclei JSON array: {e}")
    else:
        for line in text.splitlines():
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
            except json.JSONDecodeError:
                continue
            if isinstance(obj, dict):
                findings.append(normalize_line(obj))

    out.write_text(json.dumps(findings, indent=2) + "\n", encoding="utf-8")
    print(f"  Normalized Nuclei: {len(findings)} finding(s)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
