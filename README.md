# agentic-dast

Isolated hub for **no-budget DAST** in **GitHub Actions only**: ZAP + ProjectDiscovery Nuclei, then AI triage.

Do **not** run scanners on corp laptops (Netskope / TLS interception). Use Actions → **DAST manual (hub)**.

## Pipeline role

```
PR:     agentic-review → agentic-quality-gate → agentic-verdict   (unchanged)
DAST:   schedule/manual (CI) → agentic-dast → sticky GitHub Issue
```

## What it does

1. ZAP against `target_url` (`baseline` = passive; `deep` = full/active)
2. Nuclei templates (broader tags in `deep`)
3. Deduplicate → `dast-findings.json`
4. AI triage — short summary + collapsed details on a sticky Issue
5. Upload `agentic-dast` artifact

## Scan profiles

| Profile | Behavior | Typical use |
|---------|----------|-------------|
| `baseline` | ZAP baseline + Nuclei | Nightly / quick |
| `deep` | ZAP full-scan + richer Nuclei tags | Manual / weekly deep |
| `api` | Alias of `deep` (OpenAPI import later) | Same as deep |

## How to run (CI)

1. Open https://github.com/pulumamidi-harsha/agentic-dast/actions  
2. **DAST manual (hub)** → Run workflow  
3. `target_url` = Dev HTTPS only (never production)  
4. `scan_profile` = `baseline` or `deep`  
5. Read the sticky Issue (summary short; expand sections for detail)

Required secrets: `AI_API_KEY`, `AI_API_ENDPOINT`.  
Optional: `DAST_AUTH_HEADER_VALUE` for authenticated scans.  
Optional variable: `DAST_TARGET_URL` for scheduled baseline.

## Non-goals

- No local laptop scans  
- No Burp / paid SaaS  
- No PR merge gate  
- No production scanning  
- Does not replace Semgrep SAST in quality-gate
