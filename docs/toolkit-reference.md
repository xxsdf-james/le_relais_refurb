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
SHA-256 value printed on a card — see CLAUDE.md, "Delivery to target machines," for
the exact `wget`/`sha256sum` (Linux) and `Invoke-WebRequest`/`Get-FileHash` (Windows)
commands. Diagnostic/erase results and logs leave the machine over SSH instead of a
physical USB — see `docs/ssh-access.md`.

**Known gap**: `register-update-loop.ps1` (Windows Update automation, below) also needs
the `PSWindowsUpdate` PowerShell module — many files, not one — sitting next to it on
the target, and the per-file fetch pattern above doesn't cover that yet. Not yet
resolved; see "Open items / TODO".

## Per-machine workflow — Windows-only batch (current)

Covers the current 36-machine Windows-only priority (CLAUDE.md): activated, fully
updated, no open-source apps. The dual-boot/Mint workflow further below is not part of
this — it's kept for when that phase resumes.

```
1. Boot Ubuntu USB → Ubuntu Live
2. Fetch diagnostics.sh, verify its SHA-256, run it (`bash diagnostics.sh` — no sudo,
   it escalates per-command internally) → opening diagnostics: machine label + "before"
3. If bench access or a results pull is needed now: fetch and run enable-ssh.sh
   (`sudo bash enable-ssh.sh <github-username>`) — see docs/ssh-access.md
4. Fetch erase-partition.sh into the SAME directory as diagnostics.sh (both resolve
   results/ relative to themselves), verify its SHA-256, run it (`bash
   erase-partition.sh` — no sudo): sanitizes the drive (method by drive type,
   methodology.md §4), zaps any leftover GPT/MBR structure, leaves the disk fully
   unallocated. It does NOT partition or create an ESP — Windows Setup does that itself.
5. Boot Windows 11 USB → install to the unallocated space
6. Set a real password on the local admin account (Rufus's online-account bypass — see
   "Building each Rufus USB" above — leaves it blank)
7. Fetch register-update-loop.ps1, update-loop.ps1, check-update-status.ps1 (+ the
   PSWindowsUpdate module — see the delivery gap above), verify checksums, run
   register-update-loop.ps1 elevated. It registers the Windows Update automation and
   the machine drives itself from there.
8. Periodically run check-update-status.ps1 (elevated) until it verdicts OK
9. Verify Windows activation manually (Settings → System → Activation) — no script
   checks this yet
10. If bench access or a results pull is needed: fetch and run enable-ssh.ps1
11. Boot Ubuntu USB → Ubuntu Live again, fetch diagnostics.sh again, run it for closing
    diagnostics (same machine label + "after")
12. Pull that machine's result files (diagnostic .txt logs, summary.csv) over SSH — see
    docs/ssh-access.md — not a physical USB
13. Work through the pre-handoff checklist above before the machine leaves
```

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
- [ ] **Set a real password on the local admin account.** The Rufus bypass used to
  skip the online-Microsoft-account requirement (see "Building each Rufus USB" above)
  creates a blank-password local admin account. (Note: this doc's own line above cites
  `known-issues.md` for the detail on this — that entry doesn't actually exist there;
  broken cross-reference, not re-derived here.)
- [ ] **Verify Windows activation** (Settings → System → Activation). No script checks
  this yet — see "Open items / TODO" below.
- [ ] **Confirm the Windows Update stage reached DONE**, via `check-update-status.ps1`
  (`scripts/windows/`), rather than assuming a quiet machine is finished.

## Open items / TODO

- `diagnostics.sh` v0.7 now does drive-type detection, machine-identity fields
  (chassis + drive serial, CIAD number), and Windows Boot Manager verification — the
  rewrite this item used to describe is mostly done. Windows activation check is the
  one piece still missing (no script checks it; see the pre-handoff checklist above).
  Dual-boot suitability evaluation was dropped from the script for the current
  Windows-only batch (see diagnostics.sh's own v0.7 changelog) — needs reinstating when
  the dual-boot phase resumes, not re-derived from scratch.
- `register-update-loop.ps1`'s dependency on the `PSWindowsUpdate` module (many files,
  not one) has no delivery mechanism under the current per-file wget/Invoke-WebRequest
  model — see "Script delivery (current)" above. Unresolved.
- Criteria for falling back from Mint Cinnamon to Mint Xfce not yet defined (likely tied to the same hardware triage thresholds as the dual-boot decision — see methodology.md §5). Deferred along with the rest of the dual-boot phase.
- Confirm whether Rufus's default local account naming behavior needs a standard username set explicitly per install, rather than relying on whatever default it falls back to.
