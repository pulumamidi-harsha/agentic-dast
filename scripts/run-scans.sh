#!/usr/bin/env bash
# Run ZAP baseline + Nuclei against TARGET_URL; write raw reports under AGENTIC_TMP.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

TARGET_URL="${TARGET_URL:?TARGET_URL required}"
SCAN_PROFILE="${SCAN_PROFILE:-baseline}"
PIPELINE_DIR="${PIPELINE_DIR:-$SCRIPT_DIR/..}"
RULES_TSV="${PIPELINE_DIR}/config/zap-rules.tsv"

require_non_prod_url "$TARGET_URL"

mkdir -p "${AGENTIC_TMP}/raw" "${AGENTIC_TMP}/reports"
agentic_log "═══ DAST scans (profile=${SCAN_PROFILE}) ═══"
agentic_log "  Target: ${TARGET_URL}"

# Optional auth header for future authenticated scans
ZAP_AUTH_ARGS=()
if [[ -n "${DAST_AUTH_HEADER_VALUE:-}" ]]; then
  export ZAP_AUTH_HEADER_VALUE
  export ZAP_AUTH_HEADER="${DAST_AUTH_HEADER:-Authorization}"
  agentic_log "  Auth header configured (${ZAP_AUTH_HEADER})"
fi

# ── ZAP baseline (Docker) ───────────────────────────────────────────
agentic_log "→ ZAP baseline"
ZAP_JSON="${AGENTIC_TMP}/raw/zap-report.json"
ZAP_HTML="${AGENTIC_TMP}/reports/zap-report.html"
ZAP_MD="${AGENTIC_TMP}/reports/zap-report.md"

# Copy rules into work dir ZAP can see
WORK_DIR="${AGENTIC_TMP}/zap-wrk"
mkdir -p "$WORK_DIR"
cp "$RULES_TSV" "${WORK_DIR}/zap-rules.tsv" 2>/dev/null || true

set +e
docker run --rm \
  -v "${WORK_DIR}:/zap/wrk/:rw" \
  -e ZAP_AUTH_HEADER_VALUE \
  -e ZAP_AUTH_HEADER \
  -e ZAP_AUTH_HEADER_SITE \
  ghcr.io/zaproxy/zaproxy:stable \
  zap-baseline.py \
  -t "${TARGET_URL}" \
  -J zap-report.json \
  -r zap-report.html \
  -w zap-report.md \
  -c zap-rules.tsv \
  -I \
  2>&1 | tee "${AGENTIC_TMP}/raw/zap-baseline.log"
ZAP_RC=${PIPESTATUS[0]}
set -e
agentic_log "  ZAP exit=${ZAP_RC} (baseline may be non-zero when alerts exist)"

# Stage reports from work dir
[[ -f "${WORK_DIR}/zap-report.json" ]] && cp "${WORK_DIR}/zap-report.json" "$ZAP_JSON"
[[ -f "${WORK_DIR}/zap-report.html" ]] && cp "${WORK_DIR}/zap-report.html" "$ZAP_HTML"
[[ -f "${WORK_DIR}/zap-report.md" ]] && cp "${WORK_DIR}/zap-report.md" "$ZAP_MD"

# ── Nuclei ───────────────────────────────────────────────────────────
agentic_log "→ Nuclei"
NUCLEI_OUT="${AGENTIC_TMP}/raw/nuclei.jsonl"
NUCLEI_WRK="${AGENTIC_TMP}/nuclei-wrk"
mkdir -p "$NUCLEI_WRK"
set +e
docker run --rm \
  -v "${NUCLEI_WRK}:/out:rw" \
  projectdiscovery/nuclei:latest \
  -u "${TARGET_URL}" \
  -severity critical,high,medium,low,info \
  -jsonl \
  -silent \
  -o /out/nuclei.jsonl \
  2>"${AGENTIC_TMP}/raw/nuclei.stderr"
NUCLEI_RC=$?
set -e
if [[ -f "${NUCLEI_WRK}/nuclei.jsonl" ]]; then
  cp "${NUCLEI_WRK}/nuclei.jsonl" "$NUCLEI_OUT"
else
  : > "$NUCLEI_OUT"
fi
agentic_log "  Nuclei exit=${NUCLEI_RC}"

# ── Normalize + merge ────────────────────────────────────────────────
agentic_log "→ Normalize findings"
python3 "${SCRIPT_DIR}/normalize-zap.py" \
  "$ZAP_JSON" \
  "${AGENTIC_TMP}/zap-findings.json" \
  "$RULES_TSV"

python3 "${SCRIPT_DIR}/normalize-nuclei.py" \
  "$NUCLEI_OUT" \
  "${AGENTIC_TMP}/nuclei-findings.json"

jq -s 'add' \
  "${AGENTIC_TMP}/zap-findings.json" \
  "${AGENTIC_TMP}/nuclei-findings.json" \
  > "${AGENTIC_TMP}/dast-findings.json"

TOTAL=$(jq 'length' "${AGENTIC_TMP}/dast-findings.json")
ERRORS=$(jq '[.[] | select(.severity=="error")] | length' "${AGENTIC_TMP}/dast-findings.json")
WARNS=$(jq '[.[] | select(.severity=="warning")] | length' "${AGENTIC_TMP}/dast-findings.json")
INFOS=$(jq '[.[] | select(.severity=="info")] | length' "${AGENTIC_TMP}/dast-findings.json")

jq -n \
  --arg target "$TARGET_URL" \
  --arg profile "$SCAN_PROFILE" \
  --argjson total "$TOTAL" \
  --argjson errors "$ERRORS" \
  --argjson warnings "$WARNS" \
  --argjson infos "$INFOS" \
  --argjson zap_rc "$ZAP_RC" \
  --argjson nuclei_rc "$NUCLEI_RC" \
  '{
    target: $target,
    profile: $profile,
    counts: {total: $total, error: $errors, warning: $warnings, info: $infos},
    scanners: {zap_exit: $zap_rc, nuclei_exit: $nuclei_rc},
    status: (if $errors > 0 then "fail" elif $warnings > 0 then "warn" else "pass" end)
  }' > "${AGENTIC_TMP}/dast-result.json"

agentic_log "  Findings: total=${TOTAL} error=${ERRORS} warning=${WARNS} info=${INFOS}"
agentic_log "═══ Done: dast-findings.json · dast-result.json ═══"

write_github_output "findings_total" "$TOTAL"
write_github_output "findings_error" "$ERRORS"
write_github_output "findings_warning" "$WARNS"
write_github_output "dast_status" "$(jq -r '.status' "${AGENTIC_TMP}/dast-result.json")"
exit 0
