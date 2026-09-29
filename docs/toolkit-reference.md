# Toolkit Reference — Le Relais PC Refurbishment

*Living document — describes the current working setup. Update this whenever the toolkit itself changes, so a new conversation can execute the workflow without re-deriving it.*

## Physical media: bootable USBs, one job each

Each drive has exactly one purpose. Don't combine roles — see `known-issues.md` and the earlier methodology discussion for why (a boot drive being read from live-locks it; a working-data drive needs to never be a boot dependency).

The **Toolbox USB is retired** (CLAUDE.md, "Out of scope / superseded") — scripts and results no longer travel by physical USB at all. See "Script delivery (current)" below.

| USB | Contents | Purpose |
|---|---|---|
| **Windows 11 USB** | Windows 11 multi-edition ISO, written via Rufus | Boots and installs Windows 11. Multi-edition ISO auto-matches the firmware-embedded OEM edition (see known-issues). |
| **Ubuntu USB** | Ubuntu Desktop ISO, written via Rufus | Boots Ubuntu Live — used for opening/closing diagnostics, disk wiping, and any manual repair work. |
| **Mint USB** | Linux Mint ISO, written via Rufus | Deferred — not used in the current Windows-only batch (CLAUDE.md: dual-boot "comes later"). Kept here for when that phase resumes. |

## Building each Rufus USB

1. Download the correct ISO (see below for sources).
2. Open Rufus, select the target USB, select the ISO.
3. Partition scheme: **GPT**, target: **UEFI (non-CSM)**.
4. For the Windows 11 USB specifically: use Rufus's extended Windows 11 install options to bypass the online-Microsoft-account requirement — but see `known-issues.md` regarding the blank-password local admin account this creates, and set a real password immediately after every install.
5. Rufus's "UEFI:NTFS" / media-validation option is **deliberately left off**. Integrity is instead checked periodically by hashing a key file on each USB and re-verifying every 15-20 installs:
   - Windows: `certutil -hashfile E:\sources\install.wim SHA256`
   - Mint: `certutil -hashfile E:\casper\filesystem.squashfs SHA256`
   Record the known-good hash the first time, then re-run periodically and compare — a mismatch means re-create the USB from scratch rather than trying to repair it.

## ISO sources

- **Ubuntu Desktop**: `ubuntu.com/download/desktop` — direct download, current LTS. Verify with `sha256sum` against the SHA256SUMS file linked on the same page before use.
- **Windows 11**: `microsoft.com/software-download/windows11` — official page only, multi-edition ISO, French language selected. No official checksum provided by Microsoft; sourcing from this exact URL is the safeguard.
- **Linux Mint**: 22.3 Cinnamon (primary edition), with a fallback to the Xfce edition for machines where Cinnamon isn't suitable — fallback criteria not yet defined.

## Script delivery (current)

The Toolbox USB is retired. Scripts are fetched directly on the target machine from
this repo via `raw.githubusercontent.com`, pinned to a tag, and checked against a
SHA-256 value kept in Hamish's Obsidian note — see CLAUDE.md, "Delivery to target machines," for
the exact `wget`/`sha256sum` (Linux) and `Invoke-WebRequest`/`Get-FileHash` (Windows)
commands. Diagnostic/erase results and logs leave the machine over SSH instead of a
physical USB — see `docs/ssh-access.md`.

**Resolved (2026-09-29)**: `register-update-loop.ps1` (Windows Update automation, below)
used to need the `PSWindowsUpdate` PowerShell module — many files, not one — sitting
next to it on the target, which the per-file fetch pattern above couldn't cover. Fixed
by dropping PSWindowsUpdate: `update-loop.ps1` now talks to the Windows Update Agent
directly via its COM API (`Microsoft.Update.Session` etc.), which ships with Windows —
nothing extra to deliver. See `update-loop.ps1`'s own header and
`docs/update-loop-design-and-recovery.md` for the how/why. Not yet run on real hardware
(same caveat as before this change — see that doc's status line).

## Per-machine workflow — Windows-only batch (current)

Covers the current 36-machine Windows-only priority (CLAUDE.md): activated, fully
updated, no open-source apps. The dual-boot/Mint workflow further below is not part of
this — it's kept for when that phase resumes.

```
1. Boot Ubuntu USB → Ubuntu Live
2. Fetch diagnostics.sh, verify its SHA-256, run it (`bash diagnostics.sh` — no sudo,
   it escalates per-command internally) → opening diagnostics: machine label + "before"
3. Fetch and run enable-ssh.sh (`sudo bash enable-ssh.sh <github-username>`) — see
   docs/ssh-access.md. Always done, not just for ad hoc bench access: results are pulled
   and `summary.csv` updated over SSH on every machine in this batch.
4. Fetch erase-partition.sh into the SAME directory as diagnostics.sh (both resolve
   results/ relative to themselves), verify its SHA-256, run it (`bash
   erase-partition.sh` — no sudo): sanitizes the drive (method by drive type,
   methodology.md §4), zaps any leftover GPT/MBR structure, leaves the disk fully
   unallocated. It does NOT partition or create an ESP — Windows Setup does that itself.
5. Boot Windows 11 USB → install to the unallocated space
6. Set a real password on the local admin account (Rufus's online-account bypass — see
   "Building each Rufus USB" above — leaves it blank)
7. Fetch register-update-loop.ps1, update-loop.ps1, check-update-status.ps1, verify
   checksums, run register-update-loop.ps1 elevated. It registers the Windows Update
   automation and the machine drives itself from there. Exact commands: "Windows Update
   stage — full walkthrough" below.
8. Periodically run check-update-status.ps1 (elevated) until it verdicts OK — see
   walkthrough below.
9. Verify Windows activation (see walkthrough below for the exact command — more
   reliable than Settings → System → Activation, which lagged confirmed API-level state
   in a real session, 2026-09-29).
10. Fetch and run enable-ssh.ps1 — same as step 3: always done, not conditional, for the
    results pull and summary.csv update
11. Boot Ubuntu USB → Ubuntu Live again, fetch diagnostics.sh again, run it for closing
    diagnostics (same machine label + "after")
12. Pull that machine's result files (diagnostic .txt logs, summary.csv) over SSH — see
    docs/ssh-access.md — not a physical USB
13. Work through the pre-handoff checklist above before the machine leaves
```

### Windows Update stage — full walkthrough (steps 7–9, plus cleanup)

Concrete commands for the fetch → register → poll → verify → clean-up portion of the
workflow above, confirmed against the first real-hardware run of the v4 COM-API rewrite
(2026-09-29). Run all of this from an elevated Windows PowerShell console, staying in the
same folder throughout (wherever the console starts — e.g. `C:\Users\Admin`).

**1. Fetch the three scripts, pinned to a tag, and verify checksums** (see CLAUDE.md,
"Delivery to target machines" — never pipe a download into a shell):

```
Invoke-WebRequest -Uri https://raw.githubusercontent.com/xxsdf-james/le_relais_refurb/refs/tags/<tag>/scripts/windows/register-update-loop.ps1 -OutFile register-update-loop.ps1
Invoke-WebRequest -Uri https://raw.githubusercontent.com/xxsdf-james/le_relais_refurb/refs/tags/<tag>/scripts/windows/update-loop.ps1 -OutFile update-loop.ps1
Invoke-WebRequest -Uri https://raw.githubusercontent.com/xxsdf-james/le_relais_refurb/refs/tags/<tag>/scripts/windows/check-update-status.ps1 -OutFile check-update-status.ps1
Get-FileHash *.ps1 -Algorithm SHA256
```

Compare each hash against the value in the Obsidian note before running anything.

**2. Register and start the update loop:**

```
powershell -NoProfile -ExecutionPolicy Bypass -File .\register-update-loop.ps1
```

This copies the three scripts into `C:\ProgramData\Refurb`, registers the
`RefurbWindowsUpdate` scheduled task, and starts pass 0. The machine drives itself from
here, rebooting automatically between passes as needed — you can walk away.

**3. Check progress periodically, until VERDICT reads `OK - updates complete`:**

```
powershell -ExecutionPolicy Bypass -File C:\ProgramData\Refurb\check-update-status.ps1
```

If it instead reads `IN PROGRESS - INSTALLING for <N>h`, wait and check again later.
Don't run other DISM/CBS-touching commands (`Add-WindowsCapability`,
`Add-WindowsPackage`, etc.) on the same machine while this is active — they can
lock-contend with the live install.

**4. Once VERDICT is `OK - updates complete`, verify:**

```
# Activation
(Get-CimInstance -ClassName SoftwareLicensingProduct -Filter "PartialProductKey IS NOT NULL").LicenseStatus
# 1 = licensed

# Task completed cleanly and turned itself off
Get-ScheduledTaskInfo -TaskName RefurbWindowsUpdate                    # LastTaskResult should be 0
Get-ScheduledTask -TaskName RefurbWindowsUpdate | Select-Object State  # should read Disabled

# Every installed update looks sane
Get-Content C:\ProgramData\Refurb\update-log.txt | Select-String "result:"

# Cross-check against Windows' own update history
(New-Object -ComObject Microsoft.Update.Session).CreateUpdateSearcher().QueryHistory(0,50) |
    Select-Object Title, ResultCode, Date
```

Don't trust Settings → Windows Update as real-time truth for any of this — it lagged
confirmed API-level state in this session. The update-history count can legitimately
come out higher than `update-log.txt`'s own count: Windows' own default Automatic
Updates can install some items (Store/AppX packages especially) independently of
`update-loop.ps1`, before the task ever runs — confirmed once (2026-09-29), not itself a
failure.

**5. Clean up the refurb tooling** — save anything you need from `update-log.txt`
first, this can't be undone:

```
Unregister-ScheduledTask -TaskName "RefurbWindowsUpdate" -Confirm:$false -ErrorAction SilentlyContinue
Remove-Item -Path "C:\ProgramData\Refurb" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -Path "$env:USERPROFILE\*.ps1" -Force -ErrorAction SilentlyContinue
```

Doesn't touch Windows Event Logs or PowerShell history — only removes what this project
put on the machine, not the system's own normal operational record.

## Dual-boot / Mint workflow (deferred — not part of the current batch)

Kept for when the dual-boot/Mint phase resumes (CLAUDE.md: "comes later"). Predates the
Windows-only pivot — needs re-validation against the current script-delivery/SSH-results
model (above) before reuse, not just a straight resume as written.

```
1. Boot Ubuntu USB → Ubuntu Live
2. Fetch and run diagnostics.sh → opening diagnostics (machine label + "before")
3. Wipe disk — method depends on drive type (see methodology.md §4)
4. Partition per triage outcome (dual-boot / Windows-only / Mint-only) — NOTE: the
   current erase-partition.sh (v8) no longer creates a shared ESP itself (see its own
   changelog); this step needs updating for whatever the dual-boot partitioning
   approach ends up being when this phase resumes.
5. Boot Windows 11 USB → install
   - Windows Update
   - Install Firefox, Thunderbird, VLC, LibreOffice
   - Verify drivers, verify install, confirm activation
6. If dual-boot or Mint-only: boot Mint USB → install
   - Updates
   - Verify Firefox/Thunderbird/VLC/LibreOffice presence/version
7. Boot Ubuntu USB again → Ubuntu Live
8. Fetch and run diagnostics.sh again → closing diagnostics (same machine label +
   "after"): confirm wipe verification, both installs, bootloader
9. Pull that machine's result files over SSH (see docs/ssh-access.md)
```

### Known gotcha specific to the dual-boot sequence

If Windows 11 was installed in step 5 and you need to boot the Mint USB in step 6, the boot-menu hotkey may no longer respond due to Windows 11's Fast Startup (see `known-issues.md`). Use **Settings → System → Recovery → Advanced startup → Restart now → Use a device** rather than troubleshooting the hotkey.

## Pre-handoff checklist — Windows-only batch (36 machines, IT dept priority)

Before a machine leaves for its recipient:

- [ ] **Run `disable-ssh.ps1`** if `enable-ssh.ps1` was used for bench access on this
  machine. Mandatory, not optional: unlike the Linux live session (wiped and
  reinstalled regardless), this OpenSSH server persists on the actual install —
  skipping it leaves a remotely-reachable SSH server trusting a technician's personal
  key for admin access on someone's low-budget PC. See `docs/ssh-access.md`.
- [ ] ~~Set a real password on the local admin account~~ — **not applicable, per Le
  Relais IT (confirmed 2026-09-29):** this batch is delivered with the Rufus-bypass
  blank-password local admin account left as-is, intentionally. This was flagged
  directly as a real security exposure (anyone with physical access gets unauthenticated
  admin) before being confirmed as deliberate IT policy rather than an oversight — noted
  here so a future session doesn't re-raise it as a gap.
- [ ] **Verify Windows activation and that the Update stage reached DONE** — exact
  commands in "Windows Update stage — full walkthrough" above (step 4). Don't trust
  Settings → Windows Update / Activation as real-time truth — it lagged confirmed
  API-level state in a real session (2026-09-29).
- [ ] **Remove the refurb tooling from the machine** — exact commands in "Windows
  Update stage — full walkthrough" above (step 5). Save anything you need from
  `update-log.txt` first, this can't be undone.

## Open items / TODO

- `diagnostics.sh` v0.7 now does drive-type detection, machine-identity fields
  (chassis + drive serial, CIAD number), and Windows Boot Manager verification — the
  rewrite this item used to describe is mostly done. Windows activation check is the
  one piece still missing (no script checks it; see the pre-handoff checklist above).
  Dual-boot suitability evaluation was dropped from the script for the current
  Windows-only batch (see diagnostics.sh's own v0.7 changelog) — needs reinstating when
  the dual-boot phase resumes, not re-derived from scratch.
- ~~`register-update-loop.ps1`'s dependency on the `PSWindowsUpdate` module (many files,
  not one) has no delivery mechanism under the current per-file wget/Invoke-WebRequest
  model~~ — resolved 2026-09-29 by dropping the module; see "Script delivery (current)"
  above.
- Criteria for falling back from Mint Cinnamon to Mint Xfce not yet defined (likely tied to the same hardware triage thresholds as the dual-boot decision — see methodology.md §5). Deferred along with the rest of the dual-boot phase.
- Confirm whether Rufus's default local account naming behavior needs a standard username set explicitly per install, rather than relying on whatever default it falls back to.
