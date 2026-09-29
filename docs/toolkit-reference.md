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
4. For the Windows 11 USB specifically: use Rufus's extended Windows 11 install options to bypass the online-Microsoft-account requirement — this leaves the local admin account with a blank password, which Le Relais IT has confirmed is intended for this batch (see the pre-handoff checklist below).
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
   it escalates per-command internally) → opening diagnostics: machine label + "before".
   Exact commands: "Diagnostics + SSH stage — full walkthrough" below.
3. Fetch and run enable-ssh.sh (`sudo bash enable-ssh.sh <github-username>`) — see
   docs/ssh-access.md. Always done, not just for ad hoc bench access: results are pulled
   and `summary.csv` updated over SSH on every machine in this batch. Exact commands:
   walkthrough below.
4. Fetch erase-partition.sh into the SAME directory as diagnostics.sh (both resolve
   results/ relative to themselves), verify its SHA-256, run it (`bash
   erase-partition.sh` — no sudo): sanitizes the drive (method by drive type,
   methodology.md §4), zaps any leftover GPT/MBR structure, leaves the disk fully
   unallocated. It does NOT partition or create an ESP — Windows Setup does that itself.
   Then, before leaving this live session, pull its results (diag_before, erase log,
   summary.csv) from the laptop with `scripts/laptop/pull-results.sh` — the Windows
   install in step 5 wipes this session, and this summary.csv row is the one closing
   diagnostics builds on in step 11. Exact commands: walkthrough below.
5. Boot Windows 11 USB → install to the unallocated space
6. ~~Set a real password on the local admin account~~ — **not applicable**: Le Relais IT
   confirmed (2026-09-29) the blank-password local admin account from Rufus's
   online-account bypass is left as-is for this batch. See the pre-handoff checklist.
7. Fetch register-update-loop.ps1, update-loop.ps1, check-update-status.ps1, verify
   checksums, run register-update-loop.ps1 elevated. It registers the Windows Update
   automation and the machine drives itself from there. Exact commands: "Windows Update
   stage — full walkthrough" below.
8. Periodically run check-update-status.ps1 (elevated) until it verdicts OK — see
   walkthrough below.
9. Verify Windows activation (see walkthrough below for the exact command — more
   reliable than Settings → System → Activation, which lagged confirmed API-level state
   in a real session, 2026-09-29). Read at the machine's own console — steps 8–9 aren't
   pulled anywhere, they're checked in place. Then, still in Windows, remove the refurb
   tooling (walkthrough step 5) — do it now so the pre-handoff checklist doesn't need
   another Windows boot after closing diagnostics.
10. ~~Fetch and run enable-ssh.ps1~~ — **currently skipped, batch-wide**: Windows-side SSH
    has open bugs, not yet root-caused/documented. Until that's fixed, Windows results
    (update-loop completion, activation) are verified manually at the console (steps
    8–9) rather than pulled over SSH; the only diagnostic file that leaves the machine
    over SSH is `diag_after`, from the Ubuntu Live closing-diagnostics boot (steps
    11–12). Don't run `enable-ssh.ps1` on these machines for now, and skip
    `disable-ssh.ps1` in the pre-handoff checklist accordingly — there's nothing to
    disable if it was never enabled.
11. Boot Ubuntu USB → Ubuntu Live again. In this order: fetch and run enable-ssh.sh
    (a fresh live boot — step 3's SSH access doesn't carry over, see
    docs/ssh-access.md); push this machine's summary.csv back from the laptop with
    `scripts/laptop/push-summary.sh`; THEN fetch and run diagnostics.sh for closing
    diagnostics (same machine label + "after"). The push has to come first: without
    the opening row in results/, diagnostics.sh inserts a fresh "before" row instead
    of updating the existing one, and the machine never reaches GREEN. Exact
    commands: walkthrough below.
12. Pull that machine's result files (diag_after, summary.csv) over SSH, from the
    laptop via `scripts/laptop/pull-results.sh` — see docs/ssh-access.md — not a
    physical USB. Exact commands: walkthrough below.
13. Work through the pre-handoff checklist below before the machine leaves
```

### Diagnostics + SSH stage — full walkthrough (steps 2–4, 11–12)

Concrete commands for the Ubuntu-Live diagnostics and SSH-results-pull portions of the
workflow above — both the opening pass (steps 2–3) and the closing pass (steps 11–12)
use the same fetch → verify → run pattern (CLAUDE.md, "Delivery to target machines").

**Opening diagnostics (step 2), from the Ubuntu Live session:**
```
wget -O diagnostics.sh https://raw.githubusercontent.com/xxsdf-james/le_relais_refurb/refs/tags/<tag>/scripts/linux/diagnostics.sh
sha256sum diagnostics.sh      # compare with the value in the Obsidian note
bash diagnostics.sh           # no sudo — it escalates per-command internally
```
Fetch it into the home directory (where the terminal opens) — `push-summary.sh`
assumes `~/results/` in the closing pass. It prompts for:
- **Machine ID/label** — use the same label you'll give `pull-results.sh`/
  `push-summary.sh` later (it's the laptop folder name: one folder = one machine).
- **CIAD number** — from the asset sticker.
- **Stage** — `before` here, `after` in step 11. Anything else is refused and asked
  again.

**Enable SSH (step 3), same session:**
```
wget -O enable-ssh.sh https://raw.githubusercontent.com/xxsdf-james/le_relais_refurb/refs/tags/<tag>/scripts/linux/enable-ssh.sh
sha256sum enable-ssh.sh       # compare with the value in the Obsidian note
sudo bash enable-ssh.sh <your-github-username>
```
Prints the connect command (with this session's IP) at the end. If an SSH connection
or `scp` fails ("subsystem request failed", "REMOTE HOST IDENTIFICATION HAS CHANGED",
"Host key verification failed"), see docs/ssh-access.md — each has its own section.

**Sanitize the drive (step 4), same session, same directory as diagnostics.sh:**
```
wget -O erase-partition.sh https://raw.githubusercontent.com/xxsdf-james/le_relais_refurb/refs/tags/<tag>/scripts/linux/erase-partition.sh
sha256sum erase-partition.sh  # compare with the value in the Obsidian note
bash erase-partition.sh       # no sudo — it escalates per-command internally
```
What to expect:
- Prompts for **Machine ID/label** and **CIAD number** (same values as step 2), then
  shows the detected drive and asks you to type the **last 4+ characters of its
  serial**. That's the point of no return — check the model/capacity shown match
  this machine before typing.
- **Duration depends on the method it picks.** NVMe crypto-erase and SATA SSD secure
  erase take seconds to minutes. An HDD, or an NVMe drive that falls back to the
  Clear-tier overwrite, runs `nwipe` over the whole disk: can be hours, and prints
  nothing between its start and end lines — that's normal, not a hang. To check
  progress from a second terminal, see the "Manual progress check" comment block in
  `erase-partition.sh` (reads `write_bytes` from `/proc/<pid>/io`).
- If a previous run on this drive was interrupted after the erase or verify stage,
  it offers to **resume** instead of re-erasing. Answer Y unless you have a reason to
  re-sanitize.
- **"Drive reports security state FROZEN"** (SATA SSD): nothing was erased. Suspend
  the machine — top-right system menu → Power → Suspend — wake it with the power
  button, then run `bash erase-partition.sh` again. Don't power-cycle instead: the
  BIOS re-freezes the drive on every boot (see the script's v9 changelog).
- Any other **ABORTED** message says what it found and what to do; nothing is erased
  by an abort before the serial confirmation. For the ones with history — "no
  matching 'before' row"/missing `drive_serial`, NVMe "Invalid Command Opcode",
  verification failing after a secure erase — see known-issues.md, "Diagnostics /
  erase workflow".
- The end of the run prints `Erase status: exit=…, verify=…, partition=…`. All three
  need to read success (`exit=0`, `verify=pass`, `partition=ok`) before moving on.

**Pull opening results (end of step 4), from the laptop, before rebooting into the
Windows installer:**
```
scripts/laptop/pull-results.sh <target-ip> <machine-label>
```
Handles the stale-host-key problem itself (`ssh-keygen -R` + `ssh-keyscan`,
non-interactive) before pulling `diag_*.txt`, `erase_*.txt`, and `summary.csv` into
`<repo-parent>/le_relais_refurb_results/<machine-label>/` — see docs/ssh-access.md and
`scripts/laptop/pull-results.sh`'s own usage text for the optional
`remote-user`/`remote-results-dir` arguments. Use the same `<machine-label>` for every
pull and push of a given machine: it's the folder name, and one folder = one machine.

*(Steps 5–10 — Windows install, Windows Update — happen in between; see the "Windows
Update stage" walkthrough below.)*

**Closing diagnostics (step 11), fresh Ubuntu Live boot — order matters:**

1. Enable SSH — same enable-ssh.sh commands as step 3 above. This is a *new* live
   session: the host key and `authorized_keys` from the opening pass don't persist
   (docs/ssh-access.md, "REMOTE HOST IDENTIFICATION HAS CHANGED").
2. From the laptop, push this machine's summary.csv back:
   ```
   scripts/laptop/push-summary.sh <target-ip> <machine-label>
   ```
   Typing the label is the confirmation of which file goes out; the script also
   refuses unless the target's chassis serial matches that file's `machine_serial`
   (catches a wrong IP), the file has exactly one row, and there's no summary.csv on
   the target yet. It pushes to `~/results/`, so fetch diagnostics.sh into the home
   directory in the next step (same as the opening pass).
3. Fetch and run diagnostics.sh — same commands as step 2 above, "after" instead of
   "before". It finds the pushed row and updates it in place: `windows_verified`, and
   status → GREEN if the Windows Boot Manager check passes.

**Pull closing results (step 12), from the laptop:** same `pull-results.sh` command as
above. The existing `summary.csv` is copied to `summary.csv.<timestamp>.bak` first,
then replaced by the closing copy (a superset of the opening one). It prints the row's
status at the end, and warns (without failing) if the pulled copy is identical to the
one it replaced — i.e. closing diagnostics didn't run after the push — or if a
`diag_*_after.txt` is present but status isn't GREEN. Either warning means: fix it now,
while that live session is still up.

**Building the single deliverable, from the laptop (once machines are done):**
```
scripts/laptop/combine-summary.sh
```
Stacks every `<machine-label>/summary.csv` into
`le_relais_refurb_results/summary-combined.csv` — one header, one row per machine.
Writes nothing and lists the problems if any machine's file has the wrong header or
more/fewer than one row, or if the same `machine_serial` shows up under two labels.

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

**Known bug — run this fix before EVERY check in step 3 (and before reading any file
in `C:\ProgramData\Refurb` by hand)**: files created under `C:\ProgramData\Refurb`
don't inherit the folder's ACL, so reading any of them back (even from a fully
elevated Administrator session) fails with Access Denied — this includes
`check-update-status.ps1` itself. See `known-issues.md`, "Windows Update stage" for the
full diagnosis. One recursive sweep fixes the whole folder at once:
```
takeown /F C:\ProgramData\Refurb /R /D Y
icacls C:\ProgramData\Refurb /grant:r "*S-1-5-32-544:(OI)(CI)F" "*S-1-5-18:(OI)(CI)F" /T /Q
```
Why every time, not once: the update loop keeps creating new files after the sweep —
`update-status.txt` is replaced with a fresh file on every state change, plus a new
transcript each pass — and nothing yet confirms those inherit correctly. If they
don't, `check-update-status.ps1` can't read the status file and misreports `NO STATUS
FILE`. The sweep is harmless to repeat.

**3. Check progress periodically, until VERDICT reads `OK - updates complete`:**

```
powershell -ExecutionPolicy Bypass -File C:\ProgramData\Refurb\check-update-status.ps1
```

If it reads `IN PROGRESS - ...`, wait and check again later. Don't run other
DISM/CBS-touching commands (`Add-WindowsCapability`, `Add-WindowsPackage`, etc.) on the
same machine while this is active — they can lock-contend with the live install.

Any other verdict (`NEEDS HUMAN`, `DIED MID-RUN`, `REBOOT DID NOT HAPPEN`, `TASK
MISSING`, `SUSPECT HUNG`, ...): follow `docs/update-loop-design-and-recovery.md`,
"Manual recovery procedure" — most cases are just a reboot. `NO STATUS FILE` right
after registering usually means the sweep above wasn't run first.

**4. Once VERDICT is `OK - updates complete`, verify:**

```
# Activation — checked by hand for now (no script does it yet; see Open items)
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

**If activation doesn't read `1`:** the product keys are embedded in these machines'
BIOS, so activation normally happens on its own once online. There's no agreed
procedure yet for when it doesn't — set the machine aside, note it, and ask; see
`open-questions.md`, "Activation failure".

**5. Clean up the refurb tooling — do this now, before leaving Windows for closing
diagnostics (per-machine step 9)** — save anything you need from `update-log.txt`
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
  key for admin access on someone's low-budget PC. See `docs/ssh-access.md`. Currently
  a no-op for this batch — step 10 above has `enable-ssh.ps1` skipped batch-wide (open
  bugs), so there's nothing to disable unless it was run ad hoc for troubleshooting.
- [ ] ~~Set a real password on the local admin account~~ — **not applicable, per Le
  Relais IT (confirmed 2026-09-29):** this batch is delivered with the Rufus-bypass
  blank-password local admin account left as-is, intentionally. This was flagged
  directly as a real security exposure (anyone with physical access gets unauthenticated
  admin) before being confirmed as deliberate IT policy rather than an oversight — noted
  here so a future session doesn't re-raise it as a gap.
- [ ] **Windows activation verified and the Update stage reached DONE** — done in
  Windows at per-machine step 9 (commands: "Windows Update stage — full walkthrough"
  above, step 4). Here, just confirm it was done — not by Settings → Windows Update /
  Activation, which lagged confirmed API-level state in a real session (2026-09-29).
- [ ] **Refurb tooling removed from the machine** — also done at step 9 (walkthrough
  step 5), so no extra Windows boot is needed after closing diagnostics.
- [ ] **Closing pull showed status GREEN** with no warnings from `pull-results.sh`.

## Open items / TODO

- `diagnostics.sh` v0.7 now does drive-type detection, machine-identity fields
  (chassis + drive serial, CIAD number), and Windows Boot Manager verification — the
  rewrite this item used to describe is mostly done. Windows activation can't be
  checked from Ubuntu Live; it's checked by hand at the Windows console with the
  `Get-CimInstance ... LicenseStatus` one-liner (Windows Update walkthrough, step 4).
  Possible improvement, not scheduled: fold that check into the Windows scripts
  (e.g. `check-update-status.ps1`).
  Dual-boot suitability evaluation was dropped from the script for the current
  Windows-only batch (see diagnostics.sh's own v0.7 changelog) — needs reinstating when
  the dual-boot phase resumes, not re-derived from scratch.
- ~~`register-update-loop.ps1`'s dependency on the `PSWindowsUpdate` module (many files,
  not one) has no delivery mechanism under the current per-file wget/Invoke-WebRequest
  model~~ — resolved 2026-09-29 by dropping the module; see "Script delivery (current)"
  above.
- Criteria for falling back from Mint Cinnamon to Mint Xfce not yet defined (likely tied to the same hardware triage thresholds as the dual-boot decision — see methodology.md §5). Deferred along with the rest of the dual-boot phase.
- Confirm whether Rufus's default local account naming behavior needs a standard username set explicitly per install, rather than relying on whatever default it falls back to.
