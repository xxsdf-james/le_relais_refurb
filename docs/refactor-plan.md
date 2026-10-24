# Refactor plan: from field toolkit to a portfolio project

*Living document. Update the status section at the end of each step. Started 2026-10-24.*

## Why

The toolkit works: 30 of the 36 class machines are done with it. A review on
2026-10-22 found the weak points in organisation, not engineering:
- no front door (no README);
- the docs keep their history inline, so they contradict themselves;
- three version schemes;
- the script comments double as changelogs (48% of `erase-partition.sh`);
- fixtures with no test runner;
- key state that lives only on the laptop.

The refactor also has a second goal: to get back into programming and AI-assisted
workflows, and to end with a project that shows **how** the work was done, not only
the result.

**Audiences:**
- **Le Relais (French):** IT must be able to run it and take it over.
- **Future employers (French and English):** a readable before/after, with a
  visible process.

## Ground rules

1. **The batch is not put at risk.** `main` stays frozen at `v17` for the 36
   machines: bugfixes only, tagged as before. The refactor happens on `refactor`
   and merges into `main` only after the batch is done and a VM end-to-end test has
   passed.
2. **The "before" is kept:** the `before-refactor` tag (v17 + 4 laptop-script
   commits).
3. **One PR per step**, from `step/NN-<topic>` into `refactor`. (Git can't have both a
   `refactor` branch and `refactor/<x>` branches.) Each PR has a why / what /
   how-checked description and a green CI. Merge with **rebase or merge, not
   squash**: the red-then-green history is part of what the project shows.
4. **Behaviour stays the same** unless the PR says otherwise. Script refactors are
   checked against golden outputs from v17.
5. **Public repo:** secret and internal-hostname check before every commit, plus
   gitleaks in CI. `docs/todo.md` stays local.
6. **Exercises (threat model, data protection):** James writes the analysis and the
   decisions. Claude provides the structure and verified facts (marked *(facts)*,
   with sources), then reviews.

## Languages

| Content | Language |
|---|---|
| `README.md` | English, linking to `README.fr.md` |
| `README.fr.md` | French (short, same content) |
| `docs/fr/` runbook and IT handover | French only |
| Technical docs, ADRs, code comments | English |
| Final case study | English and French |

Only the READMEs and the case study exist in both languages, so no two copies drift
apart.

## Steps

1. **CI.** shellcheck, PSScriptAnalyzer and gitleaks on `ubuntu-26.04` (the same
   release as the Ubuntu Live 26.04.1 on the targets), with actions pinned by SHA.
2. **Dev container, with Claude Code inside.** Built from the requirements of a
   **threat model** and a **data-protection (nLPD) analysis** that come first
   (`docs/security/`). It's an unprivileged, rootless podman container on
   `ubuntu:26.04`, with the dev tools (shellcheck, bats, pwsh, PSScriptAnalyzer,
   Pester, gitleaks) at the same versions as CI.
3. **Front door:** `README.md`, `README.fr.md`, and a French per-machine runbook
   covering the current flow only.
4. **Decision records** (`docs/decisions/`), extracted from the dated notes, and a
   cleanup of the docs' inline history and contradictions.
5. **Tests:** bats against `tests/fixtures/` (plus new HDD and multi-disk fixtures,
   captured on site), golden outputs from v17, and Pester for the Windows scripts.
6. **Script internals** (only after the tests exist): changelogs out of the comments,
   one version scheme with `toolkit_version` written to `summary.csv`, and the target
   scripts kept self-contained.
7. **AI workflow:** a cleaned-up `CLAUDE.md`, project hooks, and
   `docs/ai-workflow.md`. Feeds the debrief report for the IT manager.
8. **After the batch:** merge into `main`, VM end-to-end test, tag `v18`, then the case
   study.

Later, separate: a Python rewrite of the laptop tools (as a learning project).

## Status

| Step | State | Notes |
|---|---|---|
| 1. CI | **done** — PR #1, merged 2026-10-24 | The first run was red as intended (4 dead variables; 1 PSScriptAnalyzer Error). PSScriptAnalyzer still fails only on Error; ~100 Warnings are left for review (mostly `PSAvoidUsingWriteHost`). The plaintext password in `perf-test.ps1` is a recorded exception, and the reinstall rule it rests on is now in the script and the handoff checklist. |
| 2. Dev container | **in progress** on `step/02-devcontainer` | The templates are committed (`docs/security/threat-model.md`, `data-protection.md`). James is writing the analysis; then Claude reviews; then the container is built from threat-model section 6. That branch was started before PR #1 merged: rebase it onto `refactor` first. |
| 3–8 | not started | |

**Open points carried over:**
- Whether Anthropic is Swiss–US DPF certified (to check on dataprivacyframework.gov).
- Whether iptables works in a rootless podman container on the laptop.
- Which host credentials the devcontainer tooling forwards by default.
- The gitleaks action runs on Node 20 (deprecated): update it when a release supports
  Node 24.
- The PSScriptAnalyzer Warnings need reviewing one by one, after which that check
  tightens from Error to Warning.
- A Linux live VM for the end-to-end erase test doesn't exist yet (step 8).
