# agentic-dast

Isolated hub for **no-budget DAST**: OWASP ZAP (baseline) + ProjectDiscovery Nuclei, then AI triage of scanner evidence.

Does **not** run on every PR. Call it on a schedule or `workflow_dispatch` against a live non-prod URL.

## Pipeline role

```
PR:     agentic-review → agentic-quality-gate → agentic-verdict   (unchanged)
DAST:   schedule/manual → agentic-dast (ZAP + Nuclei + AI) → sticky GitHub Issue
```

## What it does

1. ZAP baseline (passive) against `target_url`
2. Nuclei HTTP templates against the same URL
3. Normalize into `dast-findings.json`
4. AI triage (MGA / OpenAI-compatible) — ranks evidence only; does not invent vulns
5. Upload `agentic-dast` artifact + open/update a sticky Issue

## Caller example

See [examples/caller-dast.yml](examples/caller-dast.yml).

Required secrets on the **calling** repo: `AI_API_KEY`, `AI_API_ENDPOINT`.  
Required variable (or workflow input): `DAST_TARGET_URL` (Dev/staging HTTPS only — never production).

## Scan profiles

| Profile | Behavior |
|---------|----------|
| `baseline` | ZAP baseline + Nuclei (Phase A — default) |
| `api` | Reserved for OpenAPI + auth (Phase B) |

## Non-goals

- No Burp / paid SaaS
- No PR merge gate
- No production scanning
- Does not replace Semgrep SAST in quality-gate
