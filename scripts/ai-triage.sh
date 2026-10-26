#!/usr/bin/env bash
# AI triage → dast-triage.json + dast-report.md
# Report UX: short solid summary always visible; details collapsed by default.
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
PROFILE=$(jq -r '.profile // "baseline"' "$RESULT" 2>/dev/null || echo "baseline")
COUNTS=$(jq -c '.counts // {}' "$RESULT" 2>/dev/null || echo '{}')

# Prefer actionable severities in the model window; still include some info for context
EVIDENCE=$(jq -c '
  ([.[] | select(.severity=="error" or .severity=="warning")] + [.[] | select(.severity=="info")])
  | .[0:60]
  | map({engine, rule_id, severity, category, path, message: (.message|.[0:240]), remediation})
' "$FINDINGS")

SYSTEM_PROMPT=$(cat "${SCRIPT_DIR}/prompts/dast-triage-system.txt")
USER_MSG="## Scan metadata
- Target: ${TARGET}
- Profile: ${PROFILE}
- Machine status: ${STATUS}
- Counts: ${COUNTS}

## Scanner findings (deduped evidence only — do not invent)
${EVIDENCE}

Triage. Keep summary short. Return JSON only."

printf '%s' "$SYSTEM_PROMPT" > "${AGENTIC_TMP}/dast-triage-system.txt"
printf '%s' "$USER_MSG" > "${AGENTIC_TMP}/dast-triage-user.txt"

if [[ -z "${AI_API_ENDPOINT:-}" || -z "${AI_API_KEY:-}" ]]; then
  echo "::warning::AI secrets missing — writing deterministic triage without LLM"
  jq -n \
    --arg target "$TARGET" \
    --arg status "$STATUS" \
    --arg profile "$PROFILE" \
    --argjson counts "$COUNTS" \
    --argjson findings "$(cat "$FINDINGS")" \
    '{
      summary: ("DAST (" + $profile + ") on " + $target + " finished with status=" + $status + ". AI triage skipped — secrets not configured."),
      status: $status,
      confidence: 0.5,
      counts: $counts,
      headline_risks: (
        $findings
        | map(select(.severity=="error" or .severity=="warning"))
        | map(.message[0:100])
        | unique
        | .[0:5]
      ),
      top_findings: (
        $findings
        | map(select(.severity=="error" or .severity=="warning"))
        | .[0:8]
        | map({
            severity, engine, rule_id,
            title: .message[0:80],
            what: .message,
            why: "Reported by scanner",
            how_to_fix: (.remediation // "Review and remediate per scanner guidance"),
            url: .path,
            likely_false_positive: false
          })
      ),
      false_positive_notes: [],
      recommendations: ["Configure AI_API_KEY/AI_API_ENDPOINT for richer triage", "Review error/warning findings first"]
    }' > "$OUT_JSON"
else
  if bash "${SCRIPT_DIR}/call-llm.sh" "${AGENTIC_TMP}/dast-triage-raw.txt" \
    "@${AGENTIC_TMP}/dast-triage-system.txt" \
    "@${AGENTIC_TMP}/dast-triage-user.txt" \
    0.1 3072; then
    RAW=$(cat "${AGENTIC_TMP}/dast-triage-raw.txt")
    CLEANED=$(echo "$RAW" | sed 's/^```json//;s/^```//;s/```$//')
    if echo "$CLEANED" | jq -e '.summary' &>/dev/null; then
      echo "$CLEANED" | jq '.' > "$OUT_JSON"
    else
      echo "::warning::AI triage returned invalid JSON — falling back"
      jq -n --arg raw "${RAW:0:500}" --arg status "$STATUS" --argjson counts "$COUNTS" \
        '{summary:"AI triage parse failed — see artifacts.",status:$status,confidence:0,counts:$counts,headline_risks:[],top_findings:[],false_positive_notes:[$raw],recommendations:[]}' \
        > "$OUT_JSON"
    fi
  else
    echo "::warning::AI triage API call failed"
    jq -n --arg status "$STATUS" --argjson counts "$COUNTS" \
      '{summary:"AI triage API call failed — see ZAP/Nuclei artifacts.",status:$status,confidence:0,counts:$counts,headline_risks:[],top_findings:[],false_positive_notes:[],recommendations:["Inspect zap-report.html and nuclei.jsonl"]}' \
      > "$OUT_JSON"
  fi
fi

# Ensure headline_risks exists for markdown rendering
jq 'if (.headline_risks|type) != "array" then .headline_risks = [] else . end' \
  "$OUT_JSON" > "${OUT_JSON}.tmp" && mv "${OUT_JSON}.tmp" "$OUT_JSON"

TRIAGE_STATUS=$(jq -r '.status' "$OUT_JSON")
ERR_N=$(jq -r '.counts.error // 0' "$OUT_JSON")
WARN_N=$(jq -r '.counts.warning // 0' "$OUT_JSON")
INFO_N=$(jq -r '.counts.info // 0' "$OUT_JSON")

# ── Markdown: short summary visible; details in <details> ────────────
{
  echo "<!-- agentic-dast:issue -->"
  echo "## Agentic DAST"
  echo ""
  echo "| | |"
  echo "|:---|:---|"
  echo "| **Target** | \`${TARGET}\` |"
  echo "| **Profile** | \`${PROFILE}\` |"
  echo "| **Status** | \`${TRIAGE_STATUS}\` (machine: \`${STATUS}\`) |"
  echo "| **Counts** | error **${ERR_N}** · warning **${WARN_N}** · info **${INFO_N}** |"
  if [[ -n "${GITHUB_SERVER_URL:-}" && -n "${GITHUB_REPOSITORY:-}" && -n "${GITHUB_RUN_ID:-}" ]]; then
    echo "| **Run** | [#${GITHUB_RUN_ID}](${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}) |"
  fi
  echo ""
  echo "### Summary"
  echo ""
  jq -r '.summary' "$OUT_JSON"
  echo ""

  HR_COUNT=$(jq '.headline_risks | length' "$OUT_JSON")
  if [[ "$HR_COUNT" != "0" ]]; then
    echo "### Top risks"
    echo ""
    jq -r '.headline_risks[] | "- \(.)"' "$OUT_JSON"
    echo ""
  fi

  # Collapsed: findings detail
  echo "<details>"
  echo "<summary><strong>Findings detail</strong> (expand)</summary>"
  echo ""
  TF=$(jq '.top_findings | length' "$OUT_JSON")
  if [[ "$TF" == "0" ]]; then
    echo "_No prioritized findings._"
  else
    jq -r '.top_findings[] | "#### [\(.severity)] \(.title // .rule_id)\n- **Engine:** `\(.engine)` · **Rule:** `\(.rule_id)`\n- **URL:** `\(.url // "n/a")`\n- **What:** \(.what)\n- **Why:** \(.why)\n- **Fix:** \(.how_to_fix)\n"' "$OUT_JSON"
  fi
  echo ""
  echo "</details>"
  echo ""

  # Collapsed: recommendations
  echo "<details>"
  echo "<summary><strong>Recommendations</strong> (expand)</summary>"
  echo ""
  REC=$(jq '(.recommendations // []) | length' "$OUT_JSON")
  if [[ "$REC" == "0" ]]; then
    echo "_None._"
  else
    jq -r '(.recommendations // [])[] | "- \(.)"' "$OUT_JSON"
  fi
  echo ""
  echo "</details>"
  echo ""

  # Collapsed: FP notes + raw inventory
  echo "<details>"
  echo "<summary><strong>More context</strong> (expand)</summary>"
  echo ""
  FP=$(jq '(.false_positive_notes // []) | length' "$OUT_JSON")
  if [[ "$FP" != "0" ]]; then
    echo "**False-positive notes**"
    echo ""
    jq -r '(.false_positive_notes // [])[] | "- \(.)"' "$OUT_JSON"
    echo ""
  fi
  echo "**All deduped scanner findings**"
  echo ""
  echo '```'
  jq -r '.[] | "[\(.severity)] \(.engine)/\(.rule_id) — \(.message[0:120])"' "$FINDINGS" | head -80
  echo '```'
  echo ""
  echo "</details>"
  echo ""
  echo "_CI-only DAST (ZAP + Nuclei). Not a PR merge gate. Never run against production._"
} > "$OUT_MD"

agentic_log "  Wrote dast-triage.json and dast-report.md"
write_github_output "triage_status" "$TRIAGE_STATUS"
exit 0
