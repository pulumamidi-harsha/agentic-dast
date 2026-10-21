#!/usr/bin/env python3
"""Normalize ZAP JSON report → findings list (agentic finding schema)."""
from __future__ import annotations

import json
import sys
from pathlib import Path
from typing import Any, Dict, List, Optional


def risk_to_severity(riskcode: str, riskdesc: str = "") -> str:
    # ZAP riskcode: 0 Informational, 1 Low, 2 Medium, 3 High, 4 Critical (newer)
    code = str(riskcode or "0")
    if code in ("3", "4") or "High" in riskdesc or "Critical" in riskdesc:
        return "error"
    if code in ("2",) or "Medium" in riskdesc:
        return "warning"
    return "info"


def load_ignored_plugin_ids(rules_tsv: Optional[Path]) -> set:
    ignored = set()
    if not rules_tsv or not rules_tsv.is_file():
        return ignored
    for line in rules_tsv.read_text(encoding="utf-8", errors="replace").splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split("\t")
        if len(parts) >= 2 and parts[1].strip().upper() == "IGNORE":
            ignored.add(parts[0].strip())
    return ignored


def normalize(report: Dict[str, Any], ignored: set) -> List[Dict[str, Any]]:
    findings: List[Dict[str, Any]] = []
    for site in report.get("site") or []:
        site_name = site.get("@name") or site.get("name") or ""
        for alert in site.get("alerts") or []:
            plugin_id = str(alert.get("pluginid") or alert.get("pluginId") or "")
            if plugin_id in ignored:
                continue
            name = alert.get("name") or alert.get("alert") or "ZAP alert"
            riskcode = str(alert.get("riskcode") or "0")
            riskdesc = alert.get("riskdesc") or ""
            severity = risk_to_severity(riskcode, riskdesc)
            desc = (alert.get("desc") or alert.get("description") or "").strip()
            # Strip simple HTML tags from ZAP desc
            for tag in ("<p>", "</p>", "<br>", "<br/>", "&quot;", "&amp;"):
                desc = desc.replace(tag, " " if tag.startswith("<") else {"&quot;": '"', "&amp;": "&"}[tag])
            desc = " ".join(desc.split())
            solution = (alert.get("solution") or "").strip()
            for tag in ("<p>", "</p>", "<br>", "<br/>"):
                solution = solution.replace(tag, " ")
            solution = " ".join(solution.split()) or None

            instances = alert.get("instances") or [{}]
            for inst in instances[:5]:
                uri = inst.get("uri") or site_name or None
                param = inst.get("param") or ""
                msg = name
                if param:
                    msg = f"{name} (param={param})"
                if desc:
                    msg = f"{msg}: {desc[:240]}"
                fp = f"zap:{plugin_id}:{uri or ''}:{param}"
                findings.append(
                    {
                        "engine": "zap",
                        "rule_id": f"zap.{plugin_id}",
                        "severity": severity,
                        "category": "security",
                        "path": uri,
                        "start_line": None,
                        "end_line": None,
                        "message": msg[:500],
                        "remediation": solution[:400] if solution else None,
                        "in_pr_diff": False,
                        "fingerprint": fp[:200],
                        "raw": {
                            "pluginid": plugin_id,
                            "riskcode": riskcode,
                            "cweid": alert.get("cweid"),
                            "wascid": alert.get("wascid"),
                        },
                    }
                )
    return findings


def main() -> int:
    if len(sys.argv) < 3:
        print(
            "usage: normalize-zap.py <zap-report.json> <out-findings.json> [zap-rules.tsv]",
            file=sys.stderr,
        )
        return 2
    src = Path(sys.argv[1])
    out = Path(sys.argv[2])
    rules = Path(sys.argv[3]) if len(sys.argv) > 3 else None
    if not src.is_file():
        out.write_text("[]\n", encoding="utf-8")
        print(f"  ZAP report missing ({src}) — empty findings")
        return 0
    try:
        report = json.loads(src.read_text(encoding="utf-8"))
    except json.JSONDecodeError as e:
        print(f"::warning::Invalid ZAP JSON: {e}")
        out.write_text("[]\n", encoding="utf-8")
        return 0
    ignored = load_ignored_plugin_ids(rules)
    findings = normalize(report, ignored)
    out.write_text(json.dumps(findings, indent=2) + "\n", encoding="utf-8")
    print(f"  Normalized ZAP: {len(findings)} finding(s) (ignored plugins={len(ignored)})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
