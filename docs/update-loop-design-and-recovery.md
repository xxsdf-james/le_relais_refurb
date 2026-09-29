# Windows Update stage: design notes and manual recovery

Scripts: `update-loop.ps1`, `register-update-loop.ps1`, `check-update-status.ps1`.
Status: **built and logic-tested off-Windows only** (parsed with PowerShell 7.4; every exit path exercised against stubbed Windows cmdlets). Not yet run on a Le Relais machine. See "Verify on the next machine" at the bottom. This now includes the 2026-09-29 PSWindowsUpdate -> COM API rewrite below, which is *additionally* unverified against real hardware in its own right (the WUA COM sequence has been checked against Microsoft's own API docs and community examples, not run end-to-end yet).

## Fetching the scripts

No Toolbox USB layout any more (retired — see CLAUDE.md). Fetch each script
individually per CLAUDE.md's "Delivery to target machines", into the same folder:

```
Invoke-WebRequest -Uri https://raw.githubusercontent.com/xxsdf-james/le_relais_refurb/refs/tags/<tag>/scripts/windows/register-update-loop.ps1 -OutFile register-update-loop.ps1
Invoke-WebRequest -Uri https://raw.githubusercontent.com/xxsdf-james/le_relais_refurb/refs/tags/<tag>/scripts/windows/update-loop.ps1 -OutFile update-loop.ps1
Invoke-WebRequest -Uri https://raw.githubusercontent.com/xxsdf-james/le_relais_refurb/refs/tags/<tag>/scripts/windows/check-update-status.ps1 -OutFile check-update-status.ps1
Get-FileHash *.ps1 -Algorithm SHA256   # compare against the value in the Obsidian note
```

No module to fetch alongside them any more (see "PSWindowsUpdate -> COM API" below). Per machine, from an elevated Windows PowerShell in that same folder:

```
powershell -NoProfile -ExecutionPolicy Bypass -File .\register-update-loop.ps1
```

This copies the scripts into `C:\ProgramData\Refurb`, locks it down, registers the task, prints back what Windows actually stored, and starts pass 0. From there you can walk away.

---

## Design decisions (and where they differ from the brief)

### 0. PSWindowsUpdate -> COM API (2026-09-29)
`update-loop.ps1` and `register-update-loop.ps1` no longer use the `PSWindowsUpdate` PowerShell module. `update-loop.ps1` now calls the Windows Update Agent (WUA) directly through its COM API (`Microsoft.Update.Session`, `.ServiceManager`, etc.), which ships as part of Windows.

**Why:** `PSWindowsUpdate` is third-party and normally installs via `Install-Module` from PowerShellGallery.com, which CLAUDE.md already rules out on the Le Relais network. The workaround was to hand-copy the module's files onto each machine — but that assumed Toolbox-USB delivery, which has since been retired in favor of fetching scripts individually via `raw.githubusercontent.com` (see "Fetching the scripts" above). A multi-file module has no path through that one-file-at-a-time model, so `register-update-loop.ps1` could not actually complete on a machine that only received the three `.ps1` files — this was open and unresolved (`toolkit-reference.md`'s "Known gap") until this change. The COM API is part of the OS, so there's nothing left to deliver at all.

**What changed, mechanically:**
- The Microsoft Update service (drivers, Office, etc. — not just OS updates) is opted into with `Microsoft.Update.ServiceManager.AddService2("7971f918-a847-4430-9279-4a52d1efe18d", 7, "")`, Microsoft's own documented sample for this (`learn.microsoft.com/windows/win32/wua_sdk/opt-in-to-microsoft-update`). This is what `-MicrosoftUpdate` did under the hood. Idempotent: checked against the existing `ServiceManager.Services` list before adding.
- The searcher is pointed at that service explicitly (`ServerSelection = 3` [`ssOthers`], `ServiceID = <that GUID>`), rather than relying on it becoming the implicit default.
- Each pending update needs `.AcceptEula()` called once if `.EulaAccepted` is false — `-AcceptAll` doesn't exist outside PSWindowsUpdate, so this is done explicitly, per update, before it's added to the download collection.
- Download and install are now two explicit COM calls (`Session.CreateUpdateDownloader()` / `.CreateUpdateInstaller()`) instead of one `Get-WindowsUpdate -Install`. Only updates where `.IsDownloaded` came back true after the download step go into the install collection.
- `Installer.AllowSourcePrompts = $false` is set explicitly — there's no interactive session for WUA to prompt in a SYSTEM scheduled task, so this forecloses it rather than relying on it never coming up.
- `Installer.RebootRequiredBeforeInstallation` is checked and treated as an error (exit 20) if true, rather than calling `Install()` regardless. This is a new safety check that didn't exist before — the PSWindowsUpdate-based script had no equivalent, and in principle `Test-RebootPending` (checked on the "nothing found" path) should already prevent this scenario from arising, but it's a cheap belt-and-suspenders check on the path that most needs one.
- `-IgnoreReboot` had no bespoke equivalent to add: `IUpdateInstaller.Install()` never reboots the machine on its own regardless of caller — rebooting was always this script's own job via `Restart-Computer -Force`, so behavior here is unchanged.
- Per-update result logging now reads WUA's own `OperationResultCode` (`2`=Succeeded, `3`=SucceededWithErrors, `4`=Failed, `5`=Aborted) via `InstallationResult.GetUpdateResult($i)`, and `.KBArticleIDs`/`.Title` off the `IUpdate` object itself, replacing PSWindowsUpdate's `.Result`/`.KB`/`.Title` properties. Same information, different shape.
- The "confirm zero-result via WUA" double-check (old §1) and its exit code 12 are gone — see the rewritten §1 below for why that's a safe simplification, not a dropped safeguard.

**Verified vs not:** the `AddService2` GUID/flags and the overall session/searcher/downloader/installer object sequence match Microsoft's own WUA SDK documentation and multiple independent community scripts using the identical pattern under a SYSTEM scheduled task (the same execution context this project already uses, and already used for the PSWindowsUpdate version). What's *not* independently verified yet, because nothing in this stage has run on real Le Relais hardware regardless of module choice: the exact property names/behavior on this specific Windows build (26200), and whether `RebootRequiredBeforeInstallation`/`AllowSourcePrompts` behave as documented under this task's specific principal/logon-type combination. Same "verify on the next machine" caveat as the rest of this stage — see that section at the bottom, now updated.

### 1. "Found nothing" vs "check failed"
The check calls the Windows Update Agent directly (`Microsoft.Update.Session` COM API — see "PSWindowsUpdate -> COM API" below) and requires an explicit `ResultCode` of 2 (succeeded) before trusting the result at all; anything else is treated as a failed check attempt and retried. A zero-length `Updates` collection after a genuinely-succeeded search (`ResultCode = 2`) is what DONE means.

This used to need a second, independent check: when the search went through PSWindowsUpdate (a third-party wrapper), a false "nothing found" from a wrapper bug was a real risk, dangerous because it disables the task and reports success. The fix at the time was a confirmation search directly against the WUA COM API before declaring DONE, with disagreement between the two treated as ERROR (exit 12). Now that the *primary* check already **is** the WUA COM API, that whole failure mode — the wrapper's answer differing from the underlying agent's — can't occur, so the confirmation step and exit 12 were removed rather than kept as redundant belt-and-suspenders. Exit code 12 stays documented as retired (not reassigned) in case an old copy of the script is ever run by mistake.

The search criteria (`IsInstalled=0 and IsHidden=0 and BrowseOnly=0`) is unchanged from what the old confirmation step already used — `BrowseOnly=0` leaves out optional/preview items.

**Check retries.** A failed check is retried inside the same run (waits of 60/120/240 s, about 7 min total). The retries cover the network not being up yet at boot, without the script having to guess at what "network is up" means (Le Relais may use a proxy, etc.). The task trigger also has a 1-minute delay after boot.

### 2. Timestamps before risky calls
Every check attempt and the install log a `START` line before the call and an `END` line after it. The status file is rewritten with the current time when the stage changes. If you see `INSTALLING … since 10:02` at 15:00, it has been stuck for five hours, and you can tell that at a glance.

### 3. Status file
One line, overwritten each time, in a fixed format so a script can parse it:

```
STATE | pass N | since yyyy-MM-ddTHH:mm:ss | detail
```

States: `REGISTERED`, `CHECKING`, `INSTALLING`, `REBOOTING`, `DONE`, `ERROR`, `ABORTED`. The script writes it to a `.tmp` file and then renames it over the old one. A power cut mid-write therefore leaves the previous complete line, never a half-written one.

### 4. Pass cap: counted at the start, default 10
**Bug in the tested version:** the counter was incremented only *after* a successful install. A pass that hung, was killed, or lost power never incremented it, so the cap couldn't catch exactly the failures it was there for. The counter is now incremented **before** any risky call. Every run that starts uses up one pass, whatever happens after.

The cap is 10. You saw 3 passes on machine 1 and 2 on machine 2 (8 updates, then clean). 10 is more than 3× the worst case seen. A needless extra pass costs about 5–10 min, so a generous cap only delays the flag by about an hour. It's a parameter: `register-update-loop.ps1 -MaxPasses 15`.

On startup the script also checks whether the **previous** run ended mid-stage (status still `CHECKING`/`INSTALLING`). If so it logs a warning, because that means the run was killed, crashed or lost power.

### 5. `LastTaskResult`: useful to a human, not to the script itself (pushback)
Two problems with the brief as written:
- **The script can't use it on itself.** While the task is running, `LastTaskResult` reads `0x41301` ("currently running"), so the running script only sees its own run. It's useful to a human or to `check-update-status.ps1` reading it from outside. Inside the script, the equivalent check is the "previous run ended abnormally" test above.
- **Unregistering the task destroys it.** Your own log shows this: `Get-ScheduledTaskInfo : Le fichier spécifié est introuvable` came after the stage finished, because the test script unregistered the task on success. The production script **disables** the task on DONE/ABORTED instead. `LastTaskResult` stays readable, and a disabled task can't fire again. Unregistering belongs in the final hand-off cleanup (not built yet, see below).

To make `LastTaskResult` mean something, the script sets explicit exit codes:

| LastTaskResult | Meaning |
|---|---|
| `0x0` | DONE |
| `0xBC2` (3010) | Reboot requested. **If the machine is still up, the reboot didn't happen.** 3010 is Windows' own "success, reboot required" code. |
| `0xA` (10) | Update check failed after retries |
| `0xC` (12) | RETIRED — see "PSWindowsUpdate -> COM API" above |
| `0x14` (20) | Install threw |
| `0x1E` (30) | Pass cap reached (ABORTED) |
| `0x28` (40) | Another instance was already running |
| `0x1` | Unhandled PowerShell error |
| `0x41301` | Running now |
| `0x41306` | Terminated: expected when `ExecutionTimeLimit` kills it (**unverified**) |

The status file is what the script *said* it was doing. `LastTaskResult` and task `State` are what Windows *saw* happen. The last boot time shows whether a promised reboot actually happened. The three fail independently, and `check-update-status.ps1` cross-checks them:

| Status says | Windows says | Verdict |
|---|---|---|
| CHECKING / INSTALLING | task Running | In progress (flagged SUSPECT HUNG after 4 h) |
| CHECKING / INSTALLING | task **not** running | Died mid-run (time-limit kill, crash, power loss) |
| REBOOTING | last boot is *before* the status time | Reboot never happened |
| REBOOTING | booted >10 min ago, task not running | Task didn't fire after boot |
| ERROR / ABORTED | – | Needs a human (see below) |

### 6. ExecutionTimeLimit = 4 h
Your observed install took about 6 min. A cumulative update on an old HDD machine can take 1–2 h, so 4 h gives plenty of margin (`-TimeLimitHours`). Limitation: when Windows kills the run, nothing reboots the machine. It sits idle with the status still showing `INSTALLING`. The status checker reports that as "died mid-run", and the fix is a reboot. I didn't add a watchdog that reboots automatically, because it would be a second moving part to debug across 100 machines.

### 7. Failure policy: when the script reboots itself and when it stops
- **Individual updates reporting `Failed`** (no exception): logged per KB. The script reboots and continues, because a reboot is the normal fix for WU failures. The cap is what stops an update that keeps failing forever.
- **The machinery failing** (module won't load, check fails after retries, install call throws): status goes to ERROR and the machine **doesn't** reboot. It stays put, showing its error. The task **stays enabled**, so the recovery is simply rebooting it.

### Additions not in the brief
- **Transcript per pass** (`transcripts\pass-N.txt`). This captures all console output under SYSTEM, including the errors you'd otherwise only see by re-running by hand. Check it before re-running anything.
- **Single-instance mutex** (`Global\RefurbUpdateLoop`). A manual run and a task run can't overlap. The task's `MultipleInstances IgnoreNew` only protects task-vs-task.
- **Folder ACL lockdown.** SYSTEM runs whatever is in `update-loop.ps1`, so only SYSTEM and Administrators can write to `C:\ProgramData\Refurb`. Side effect: `check-update-status.ps1` needs an elevated prompt.
- **Stay awake while running** (`SetThreadExecutionState`). This isn't a persistent power-plan change: it's released automatically when the process exits. It's preventive: I haven't seen a machine sleep mid-install.
- **Pending-reboot check before DONE.** If nothing is found but a reboot is pending, the script reboots once more instead of declaring DONE, because Windows can hold back updates until the pending reboot completes.
- **ASCII-only scripts.** Windows PowerShell 5.1 reads BOM-less files as ANSI. Keep accents out of the scripts and their comments.

### Hook for the next stages
`Invoke-NextStage` is a deliberate no-op that runs after DONE. One warning for when you chain app installs in: **winget under SYSTEM isn't the same as winget in your Admin session.** It isn't on SYSTEM's PATH (App Installer is per-user), and the `msstore` source prompt in your log is the kind of thing that behaves differently there. Test it as SYSTEM on its own before wiring it in.

---

## Manual recovery procedure

Always start with an **elevated** PowerShell:

```
powershell -ExecutionPolicy Bypass -File C:\ProgramData\Refurb\check-update-status.ps1
```

It prints the status line, the task state and decoded `LastTaskResult`, the last boot time, the last 8 log lines and a VERDICT.

**Step 1: read before acting.**
- `Get-Content C:\ProgramData\Refurb\update-log.txt -Tail 30`
- Open the newest `C:\ProgramData\Refurb\transcripts\pass-N.txt`. The full error, including the WU HRESULT such as `0x8024402C`, is in there. Search for the **HRESULT**, not the French message text.

**Step 2: pick the case.**

| Verdict | Do this |
|---|---|
| ERROR, died mid-run, reboot didn't happen | **Reboot.** The task is still enabled and retries on its own. |
| Same ERROR again after a reboot | Re-run by hand (step 3) to watch it live. |
| ABORTED (cap reached) | Look in the log for a KB that appears on every pass. Fix or hide it, then reset (step 4). |
| TASK MISSING | Re-run `register-update-loop.ps1 -KeepState` from the USB. |

**Step 3: re-run by hand.** Make sure it isn't already running (`(Get-ScheduledTask RefurbWindowsUpdate).State` should not be `Running`), then:

```
powershell -NoProfile -ExecutionPolicy Bypass -File C:\ProgramData\Refurb\update-loop.ps1
```

This is the same script, the same files and the same code path. The difference is that errors print on your console instead of disappearing into session 0.

**Why the automation picks up again afterwards with no re-registration:** the script keeps no state in memory and none tied to who runs it. Everything is in the three files in `C:\ProgramData\Refurb`. If your manual run installs updates, it increments the counter and reboots. The task is still registered and enabled with its AtStartup trigger, so pass N+1 runs as SYSTEM at the next boot, exactly as if the task had done pass N. If your manual run finds nothing, it writes DONE and disables the task itself. Note that a manual run uses up a pass like any other.

**Step 4: reset after ABORTED.** The task was disabled, so reset the counter and re-enable it (again, no re-registration):

```
Set-Content C:\ProgramData\Refurb\update-pass-count.txt 0
Enable-ScheduledTask -TaskName RefurbWindowsUpdate
Restart-Computer
```

---

## Verify on the next machine (currently unknown or assumed)
1. `LastTaskResult` after a reboot pass: I expect `0xBC2`. Check it by running `Get-ScheduledTaskInfo RefurbWindowsUpdate` after the stage finishes; the last run should show `0x0`.
2. `LastTaskResult` after a time-limit kill: I expect `0x41306`, from memory, **unverified**. Optional deliberate test: `register-update-loop.ps1 -TimeLimitHours 0.02` (about 1 min) on a machine that has updates pending.
3. `AddService2`'s registration of the Microsoft Update service actually broadens the search beyond OS-only updates on this build (26200) — i.e. `-MicrosoftUpdate`'s old effect is genuinely preserved, not just that the call doesn't error. Compare update counts/titles against what Settings > Windows Update shows once, on the first real machine.
4. `GetUpdateResult($i)` lines up with the `$toReallyInstall` collection built earlier in the same pass by construction (same object, same loop order) — should hold, but confirm the first real log's `result:` lines show sensible titles/KBs, not a mismatch.
5. `RebootRequiredBeforeInstallation` and `AllowSourcePrompts` behave as documented under this specific task principal (`SYSTEM`, `ServiceAccount` logon, `Highest` run level) — no reason to expect otherwise, but this exact combination hasn't been exercised against the live WUA API before.
6. The icacls lockdown doesn't break the task (the first pass running at all confirms this).

## Not built yet
- **Hand-off cleanup** before a machine leaves: `Unregister-ScheduledTask RefurbWindowsUpdate`, remove `C:\ProgramData\Refurb`. (No module to decide about any more — nothing was installed.)
- Chaining the later stages (the hook above).

## Side notes from the machine-2 log (for when steps 3–4 get scripted)
- `WindowsProductName` says **"Windows 10 Pro"** on build 26200. This is a known registry quirk, and the machine really is running Windows 11 (build ≥ 22000 = Win 11; 26200 = 25H2). A summary column should use the build number, not the product name.
- `Get-PnpDevice -Status Error` **throws** (`ObjectNotFound`) when nothing is in error, so run unattended it would look like a failure. Use `-ErrorAction SilentlyContinue` and treat an empty result as clean.
- `Get-PhysicalDisk` includes the toolbox USB stick ("Generic Flash Disk"). Filter on `BusType -ne 'USB'`. `WriteErrorsTotal` was blank on the Samsung SSD, so "blank" has to mean "not reported", not "0".
