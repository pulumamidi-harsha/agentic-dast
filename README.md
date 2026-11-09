# agentic-dast

Isolated hub for **open-source DAST** in **GitHub Actions only**: ZAP + ProjectDiscovery Nuclei, then AI triage.

Do **not** run scanners on corp laptops (Netskope / TLS interception). Use Actions → **DAST manual (hub)**.

## Part of the Agentic AppSec platform

This repo is one of four hubs that together give Bayer teams agentic SAST and DAST checks: open-source scanners, with findings explained and prioritized by AI. For the problem statement, the full architecture diagram and the end-to-end PR flow, see **[Platform overview in agentic-review](https://github.com/bayer-int/agentic-review#platform-overview)**.

```mermaid
flowchart LR
    LOCAL["Developer machine<br/>run-qg · chat · pre-push"]
    subgraph PRF["Pull request — GitHub Actions"]
        direction LR
        R["1 · agentic-review<br/>AI Pass 1"] --> Q["2 · agentic-quality-gate<br/>Sonar-style gate"] --> V["3 · agentic-verdict<br/>AI Pass 2"]
    end
    URL[("Non-prod URL")] --> D["4 · agentic-dast<br/>ZAP · Nuclei · AI triage"]
    LOCAL -. "same engines and rules" .-> Q

    classDef hub fill:#10384f,stroke:#0091df,stroke-width:2px,color:#ffffff
    classDef here fill:#de0043,stroke:#10384f,stroke-width:3px,color:#ffffff
    classDef dev fill:#e7f8ff,stroke:#0091df,stroke-width:2px,color:#10384f
    classDef env fill:#f5f5f5,stroke:#737373,color:#10384f
    class R,Q,V,D hub
    class D here
    class LOCAL dev
    class URL env
    style PRF fill:#f4fbff,stroke:#10384f,color:#10384f
```

<sub>Highlighted in pink: this repo.</sub>

| # | Hub | Role |
|:-:|:----|:-----|
| 1 | [agentic-review](https://github.com/bayer-int/agentic-review#readme) | AI Pass 1: detects the stack, runs lint / test / build, dependency audit, secret and IaC scans |
| 2 | [agentic-quality-gate](https://github.com/bayer-int/agentic-quality-gate#readme) | Sonar-style gate: security hotspots, secrets, duplication, complexity, coverage. Also runs locally as `run-qg` |
| 3 | [agentic-verdict](https://github.com/bayer-int/agentic-verdict#readme) | AI Pass 2: weighs all evidence, posts the final PR review, approve / request changes, label |
| 4 | **agentic-dast** (this repo) | Runtime scans of a live non-prod URL (OWASP ZAP + Nuclei) with AI triage into a sticky Issue |

---

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
