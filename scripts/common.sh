#!/usr/bin/env bash
# Shared helpers for agentic-dast.
set -euo pipefail

AGENTIC_TMP="${AGENTIC_TMP:-/tmp/agentic-dast}"
mkdir -p "$AGENTIC_TMP"

AI_MODEL="${AI_MODEL:-gpt-4.1}"

agentic_log() { echo "$@"; }

write_github_output() {
  local name="$1"
  local value="$2"
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    echo "${name}=${value}" >> "$GITHUB_OUTPUT"
  fi
}

require_non_prod_url() {
  local url="${1:-}"
  if [[ -z "$url" ]]; then
    echo "::error::target_url is required"
    return 1
  fi
  case "$url" in
    http://localhost*|http://127.0.0.1*|https://localhost*|https://127.0.0.1*)
      return 0
      ;;
    *prod*|*production*)
      echo "::error::Refusing production-like URL: ${url}"
      return 1
      ;;
  esac
  if [[ "$url" != https://* && "$url" != http://* ]]; then
    echo "::error::target_url must be http(s):// …"
    return 1
  fi
  return 0
}
