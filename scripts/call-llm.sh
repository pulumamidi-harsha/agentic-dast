#!/usr/bin/env bash
# Call OpenAI-compatible chat API with retries. Writes raw message to $1 (output file).
#
# Usage:
#   call-llm.sh <output_file> <system_prompt_or_@file> <user_msg_or_@file> [temperature] [max_tokens]
set -euo pipefail

OUTPUT_FILE="${1:?output file required}"
SYSTEM_PROMPT_ARG="${2:?system prompt required}"
USER_MSG_ARG="${3:?user message required}"
TEMPERATURE="${4:-0.1}"
MAX_TOKENS="${5:-4096}"

source "$(dirname "$0")/common.sh"

resolve_input() {
  local val="$1"
  if [[ "$val" == @* ]]; then
    local path="${val:1}"
    if [[ ! -f "$path" ]]; then
      echo "::error::call-llm.sh: file not found: $path" >&2
      exit 1
    fi
    cat "$path"
  else
    printf '%s' "$val"
  fi
}

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT
SYSTEM_FILE="$TMP_DIR/system.txt"
USER_FILE="$TMP_DIR/user.txt"
BODY_FILE="$TMP_DIR/body.json"
resolve_input "$SYSTEM_PROMPT_ARG" > "$SYSTEM_FILE"
resolve_input "$USER_MSG_ARG"     > "$USER_FILE"

if [[ -z "${AI_API_ENDPOINT:-}" || -z "${AI_API_KEY:-}" ]]; then
  echo "::warning::AI_API_ENDPOINT or AI_API_KEY not configured"
  exit 1
fi

resolve_llm_endpoint() {
  local url="${AI_API_ENDPOINT}"
  url="${url%/}"
  if [[ "$url" == *"/chat/completions" ]]; then
    echo "$url"
    return
  fi
  case "$url" in
    */api/v2|*/api/v1|*/v1|*/v2)
      echo "${url}/chat/completions"
      ;;
    *)
      echo "$url"
      ;;
  esac
}

LLM_ENDPOINT=$(resolve_llm_endpoint)
if [[ "$LLM_ENDPOINT" != "${AI_API_ENDPOINT%/}" ]]; then
  echo "::notice::AI_API_ENDPOINT normalized to ${LLM_ENDPOINT}"
fi

CURL_OPTS=(
  -sS
  -L
  --post301
  --post302
  --post303
  --max-time 120
  -w "\n%{http_code}"
  -X POST "${LLM_ENDPOINT}"
  -H "Content-Type: application/json"
  -H "Authorization: Bearer ${AI_API_KEY}"
)

jq -n \
  --rawfile system "$SYSTEM_FILE" \
  --rawfile user "$USER_FILE" \
  --arg model "$AI_MODEL" \
  --argjson temp "$TEMPERATURE" \
  --argjson max_tokens "$MAX_TOKENS" \
  '{
    model: $model,
    messages: [
      {role: "system", content: $system},
      {role: "user", content: $user}
    ],
    temperature: $temp,
    max_tokens: $max_tokens
  }' > "$BODY_FILE"

BODY_BYTES=$(wc -c < "$BODY_FILE" | tr -d ' ')
echo "::notice::LLM request size: ${BODY_BYTES} bytes"

for attempt in 1 2 3; do
  RESPONSE=$(curl "${CURL_OPTS[@]}" -d "@${BODY_FILE}" 2>/tmp/curl-error.txt) || true
  HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
  BODY=$(echo "$RESPONSE" | sed '$d')

  if [[ "$HTTP_CODE" =~ ^2 ]]; then
    CONTENT=$(echo "$BODY" | jq -r '.choices[0].message.content // empty' 2>/dev/null)
    if [[ -n "$CONTENT" ]]; then
      echo "$CONTENT" > "$OUTPUT_FILE"
      exit 0
    fi
    echo "::warning::LLM HTTP ${HTTP_CODE} but response missing choices[0].message.content"
  fi

  if [[ "$HTTP_CODE" == "401" || "$HTTP_CODE" == "403" ]]; then
    echo "::error::LLM auth failed (HTTP ${HTTP_CODE}) — check AI_API_KEY."
    exit 1
  elif [[ "$HTTP_CODE" == "429" || "$HTTP_CODE" =~ ^5 ]]; then
    echo "::warning::LLM attempt ${attempt} failed (HTTP ${HTTP_CODE}), retrying..."
    sleep $((attempt * 5))
    continue
  else
    echo "::warning::LLM call failed (HTTP ${HTTP_CODE})"
    echo "${BODY:0:500}"
  fi
  break
done

exit 1
