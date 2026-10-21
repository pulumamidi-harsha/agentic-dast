#!/usr/bin/env bash
# AI triage of dast-findings.json → dast-triage.json + dast-report.md
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

FINDINGS="${AGENTIC_TMP}/dast-findings.json"
RESULT="${AGENTIC_TMP}/dast-result.json"
OUT_JSON="${AGENTIC_TMP}/dast-triage.json"
OUT_MD="${AGENTIC_TMP}/dast-report.md"

if [[ ! -f "$FINDINGS" ]]; then
  echo "::error::dast-findings.json missing — run scans first"
  exit 1
fi

TARGET=$(jq -r '.target // "unknown"' "$RESULT" 2>/dev/null || echo "unknown")
STATUS=$(jq -r '.status // "unknown"' "$RESULT" 2>/dev/null || echo "unknown")
COUNTS=$(jq -c '.counts // {}' "$RESULT" 2>/dev/null || echo '{}')

# Cap evidence sent to the model
EVIDENCE=$(jq -c '[.[] | {engine, rule_id, severity, category, path, message: (.message|.[0:280]), remediation}] | .[0:80]' "$FINDINGS")

SYSTEM_PROMPT=$(cat "${SCRIPT_DIR}/prompts/dast-triage-system.txt")
USER_MSG="## Scan metadata
- Target: ${TARGET}
- Machine status: ${STATUS}
- Counts: ${COUNTS}

## Scanner findings (evidence only — do not invent)
${EVIDENCE}

Triage these findings. Return JSON only."

printf '%s' "$SYSTEM_PROMPT" > "${AGENTIC_TMP}/dast-triage-system.txt"
printf '%s' "$USER_MSG" > "${AGENTIC_TMP}/dast-triage-user.txt"

if [[ -z "${AI_API_ENDPOINT:-}" || -z "${AI_API_KEY:-}" ]]; then
  echo "::warning::AI secrets missing — writing deterministic triage without LLM"
  jq -n \
    --arg target "$TARGET" \
    --arg status "$STATUS" \
    --argjson counts "$COUNTS" \
    --argjson findings "$(cat "$FINDINGS")" \
    '{
      summary: ("DAST scan of " + $target + " completed without AI triage (secrets not configured). Machine status=" + $status + "."),
      status: $status,
      confidence: 0.5,
      counts: $counts,
      top_findings: ($findings | map(select(.severity=="error" or .severity=="warning")) | .[0:10] | map({
        severity, engine, rule_id, title: .message[0:80], what: .message, why: "Reported by scanner",
        how_to_fix: (.remediation // "Review and remediate per scanner guidance"),
        url: .path, likely_false_positive: false
      })),
      false_positive_notes: [],
      recommendations: ["Configure AI_API_KEY/AI_API_ENDPOINT for richer triage", "Review high/medium findings first"]
    }' > "$OUT_JSON"
else
  if bash "${SCRIPT_DIR}/call-llm.sh" "${AGENTIC_TMP}/dast-triage-raw.txt" \
    "@${AGENTIC_TMP}/dast-triage-system.txt" \
    "@${AGENTIC_TMP}/dast-triage-user.txt" \
    0.1 4096; then
    RAW=$(cat "${AGENTIC_TMP}/dast-triage-raw.txt")
    CLEANED=$(echo "$RAW" | sed 's/^```json//;s/^```//;s/```$//')
    if echo "$CLEANED" | jq -e '.summary' &>/dev/null; then
      echo "$CLEANED" | jq '.' > "$OUT_JSON"
    else
      echo "::warning::AI triage returned invalid JSON — falling back"
      jq -n --arg raw "${RAW:0:800}" --arg status "$STATUS" --argjson counts "$COUNTS" \
        '{summary: "AI triage parse failed", status: $status, confidence: 0, counts: $counts, top_findings: [], false_positive_notes: [$raw], recommendations: []}' \
        > "$OUT_JSON"
    fi
  else
    echo "::warning::AI triage API call failed"
    jq -n --arg status "$STATUS" --argjson counts "$COUNTS" \
      '{summary: "AI triage API call failed — see raw scanner artifacts", status: $status, confidence: 0, counts: $counts, top_findings: [], false_positive_notes: [], recommendations: ["Inspect zap-report.html and nuclei.jsonl artifacts"]}' \
      > "$OUT_JSON"
  fi
fi

# Markdown report for Issue body
{
  echo "<!-- agentic-dast:issue -->"
  echo "## 🔍 Agentic DAST report"
  echo ""
  echo "**Target:** \`${TARGET}\`"
  echo "**Status:** \`$(jq -r '.status' "$OUT_JSON")\` · **Machine:** \`${STATUS}\`"
  echo ""
  echo "### Summary"
  echo ""
  jq -r '.summary' "$OUT_JSON"
  echo ""
  echo "### Counts"
  echo ""
  echo "| Severity | Count |"
  echo "|----------|------:|"
  echo "| error | $(jq -r '.counts.error // 0' "$OUT_JSON") |"
  echo "| warning | $(jq -r '.counts.warning // 0' "$OUT_JSON") |"
  echo "| info | $(jq -r '.counts.info // 0' "$OUT_JSON") |"
  echo ""
  echo "### Top findings"
  echo ""
  if [[ "$(jq '.top_findings | length' "$OUT_JSON")" == "0" ]]; then
    echo "_No prioritized findings._"
  else
    jq -r '.top_findings[] | "#### [\(.severity)] \(.title // .rule_id)\n- **Engine:** `\(.engine)` · **Rule:** `\(.rule_id)`\n- **URL:** `\(.url // "n/a")`\n- **What:** \(.what)\n- **Why:** \(.why)\n- **How to fix:** \(.how_to_fix)\n- **Likely FP:** \(.likely_false_positive)\n"' "$OUT_JSON"
  fi
  echo ""
  echo "### Recommendations"
  echo ""
  jq -r '(.recommendations // [])[] | "- \(.)"' "$OUT_JSON"
  echo ""
  if [[ -n "${GITHUB_SERVER_URL:-}" && -n "${GITHUB_REPOSITORY:-}" && -n "${GITHUB_RUN_ID:-}" ]]; then
    echo "### Artifacts"
    echo ""
    echo "[Workflow run #${GITHUB_RUN_ID}](${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID})"
  fi
} > "$OUT_MD"

agentic_log "  Wrote dast-triage.json and dast-report.md"
write_github_output "triage_status" "$(jq -r '.status' "$OUT_JSON")"
exit 0
