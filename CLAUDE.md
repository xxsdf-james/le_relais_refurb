# CLAUDE.md — Le Relais PC Refurbishment (DRAFT, 2026-09-28)

## Context

Refurbishing retired PCs for Fondation Le Relais, as part of Hamish's ELAN professional
reintegration internship. Le Relais moved its fleet to Windows 11 and retired 100+ machines
that are not officially supported for Windows 11. They are wiped, reinstalled, and passed
on to people with low budgets, with a clear disclosure of the security/support caveat of
running Windows 11 on unsupported hardware.

- One-time batch effort, not a recurring service.
- Current priority: 36 machines as Windows-only (activated, fully updated, no open-source
  apps), via a mostly scripted workflow. Dual-boot with Linux (Mint under consideration,
  not final) comes later.
- Printers and monitors are out of scope unless Hamish says otherwise.
- Audience: Hamish, occasionally the main IT person at Le Relais. Nothing more formal.

## Repo layout

```
scripts/linux/     diagnostics.sh, erase-partition.sh, enable-ssh.sh
scripts/windows/   *.ps1 (update loop, etc.)
docs/              methodology.md, known-issues.md, toolkit-reference.md, open-questions.md,
                   ssh-access.md
tests/fixtures/    raw hardware output captured from real machines (001 NVMe, 002 SATA SSD)
```

Real results (`summary.csv`, per-machine `.txt` logs) never go in the repo.

## Status of the docs

`docs/` are living documents, not authoritative. They are the best current record of what
has been learned, but if a doc conflicts with a new symptom or test result, say so and
investigate rather than deferring to the doc.

## How to work

- Evidence-based, mechanistic troubleshooting. Verify claims, including your own, before
  asserting them. Search the web for anything version-specific or likely to have changed.
- When giving a fix or workflow step, say briefly why it works.
- Push back directly on risky proposals, including Hamish's. Name the actual risk.
- Ask when an ambiguity would change the answer: decisions here apply to ~100 machines.
- Don't promote any doc to "final" unless Hamish says so.

## Safety rules (hard)

- **Never execute** `diagnostics.sh`, `erase-partition.sh`, or any sanitization command
  (`nvme format`, `hdparm --security-erase`, `blkdiscard`, `nwipe`, `dd` to a device) on this
  laptop. They are meant for target machines booted from live media.
- Don't run `sudo`. Test parsing logic against `tests/fixtures/` instead.
- `diagnostics.sh` only *recommends* a sanitization command and never runs one. Keep it that way.
- Edit files in place; don't regenerate whole files. Show the diff before committing.
- **This repo is public.** Never commit product keys, passwords, tokens, or Le Relais-internal
  hostnames/IPs. Check `git diff --staged` for them before every commit.

## Delivery to target machines

The Le Relais network intercepts HTTPS to some hosts with a certificate that fresh machines
don't trust (confirmed for powershellgallery.com and gist.githubusercontent.com).
`github.com` and `raw.githubusercontent.com` pass through untouched (confirmed 2026-09-28).

Scripts are fetched from this repo via `raw.githubusercontent.com`, pinned to a tag, and
checked against a SHA-256 value printed on a card that Hamish carries. Never pipe a
download into a shell.

```
# Linux live session
wget -O diagnostics.sh https://raw.githubusercontent.com/<user>/<repo>/refs/tags/<tag>/scripts/linux/diagnostics.sh
sha256sum diagnostics.sh      # compare with the printed card, then:
sudo bash diagnostics.sh
```

```
# Windows (built-in PowerShell 5.1)
Invoke-WebRequest -Uri https://raw.githubusercontent.com/<user>/<repo>/refs/tags/<tag>/scripts/windows/<file>.ps1 -OutFile <file>.ps1
Get-FileHash <file>.ps1 -Algorithm SHA256    # compare with the printed card
powershell -ExecutionPolicy Bypass -File .\<file>.ps1
```

Publishing: commit, tag, push, then print the new checksums. Only Hamish publishes.

## Out of scope / superseded

- Ventoy: not used. One dedicated USB per install ISO.
- Toolbox USB: dropped. Scripts come from this repo over the network.
- GitHub Gists: dropped (intercepted on the Le Relais network).
- dontpad.com / any public pastebin: dropped (unauthenticated, no integrity check). SSH
  (`docs/ssh-access.md`) replaces it for ad hoc commands/log transfer.
- `curl | bash` or any download-and-execute pipe: never.
- PowerShell Gallery: intercepted on the Le Relais network, so Windows automation must not
  depend on it (e.g. `Install-Module PSWindowsUpdate`) unless run off that network.

## Open items

- Where diagnostic results go now that the Toolbox USB is gone (blocks the `diagnostics.sh` rewrite).
  SSH (`docs/ssh-access.md`) is CONFIRMED working for ad hoc/troubleshooting transfer as of
  2026-09-28; whether it becomes the standard mechanism for routine `diagnostics.sh` results
  across all ~100 machines is still open — Hamish's call.
- How activation keys reach Windows machines without being in this repo.
- Internal asset-labeling scheme: unresolved at Le Relais. Don't invent one.
