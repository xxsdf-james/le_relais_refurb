<#
  update-loop.ps1 - Le Relais PC refurbishment, Windows Update stage.
 
  Runs as SYSTEM from the "RefurbWindowsUpdate" scheduled task (AtStartup).
  Each run = one "pass": check -> install -> reboot, or check -> DONE.
  All state lives in files under C:\ProgramData\Refurb, so it can also be
  run by hand from an elevated prompt and the task carries on afterwards.

  Talks to the Windows Update Agent directly via its COM API
  (Microsoft.Update.Session and friends) - no PSWindowsUpdate module.
  That module has no delivery path under the current per-file
  raw.githubusercontent.com fetch model (it's many files, not one; see
  toolkit-reference.md's now-resolved "Known gap"), and the COM API is
  part of Windows itself, so there's nothing left to deliver. The
  Microsoft Update service (drivers/Office/etc, not just OS updates -
  what PSWindowsUpdate's -MicrosoftUpdate switch did) is opted into via
  Microsoft.Update.ServiceManager.AddService2, Microsoft's own documented
  method (learn.microsoft.com/windows/win32/wua_sdk/opt-in-to-microsoft-update).

  Files:
    update-status.txt      one line, overwritten: STATE | pass | since | detail
    update-log.txt         append-only history
    update-pass-count.txt  number of passes STARTED (incremented before work)
    transcripts\pass-N.txt full console output of each pass
 
  Exit codes (these become the task's LastTaskResult):
       0  DONE - no updates remaining, task disabled
    3010  reboot requested (if you ever SEE this with the machine still up,
          the reboot didn't happen)
      10  update check failed after all retries (task left enabled)
      12  RETIRED - was "PSWindowsUpdate said nothing but direct WU API
          disagreed"; the check IS the WU API now, so the two can't disagree.
          Kept out of use rather than reassigned, in case an old disk copy
          of this script is ever run by mistake.
      20  install call threw (task left enabled)
      30  pass cap exceeded - ABORTED, task disabled, needs a human
      40  another instance already running
       1  unhandled error (PowerShell's own code for an uncaught throw)
 
  KEEP THIS FILE ASCII-ONLY: Windows PowerShell 5.1 reads BOM-less files
  as ANSI, so accented characters would be mangled.
#>
 
param(
    [int]$MaxPasses = 10,               # ~2-3 observed as normal; see notes
    [int[]]$CheckRetryDelaysSec = @(60, 120, 240)   # waits between check attempts
)
 
$ErrorActionPreference = 'Stop'
$TaskName    = 'RefurbWindowsUpdate'
$Dir         = 'C:\ProgramData\Refurb'
$LogFile     = Join-Path $Dir 'update-log.txt'
$StatusFile  = Join-Path $Dir 'update-status.txt'
$CounterFile = Join-Path $Dir 'update-pass-count.txt'
$TransDir    = Join-Path $Dir 'transcripts'
 
New-Item -ItemType Directory -Path $Dir, $TransDir -Force | Out-Null
 
# ---------------------------------------------------------------- helpers
function Write-Log([string]$msg) {
    Add-Content -Path $LogFile -Value "$(Get-Date -Format o)  $msg" -Encoding UTF8
}
 
# Status is written to a temp file then renamed over the old one, so a power
# cut mid-write leaves the previous complete line rather than a truncated one.
function Set-Status([string]$state, [string]$detail) {
    $line = '{0} | pass {1} | since {2} | {3}' -f $state, $script:Pass,
            (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss'), $detail
    $tmp = "$StatusFile.tmp"
    Set-Content -Path $tmp -Value $line -Encoding ASCII
    Move-Item -Path $tmp -Destination $StatusFile -Force
}
 
# Message and HRESULT kept separate: messages here are in French and can
# contain braces, and HRESULTs are what to search for, not the text.
function Format-Err($e) {
    return ('{0} [HRESULT 0x{1:X8}]' -f $e.Exception.Message, $e.Exception.HResult)
}

# The well-known Microsoft Update service ID, straight from Microsoft's own
# opt-in sample (learn.microsoft.com/windows/win32/wua_sdk/opt-in-to-microsoft-update).
# Registering it is what -MicrosoftUpdate used to do: without it, the searcher
# below only sees OS updates, not drivers/Office/etc.
$script:MuServiceId = '7971f918-a847-4430-9279-4a52d1efe18d'

function Register-MicrosoftUpdateService {
    $sm = New-Object -ComObject Microsoft.Update.ServiceManager
    foreach ($svc in $sm.Services) {
        if ($svc.ServiceID -eq $script:MuServiceId) { return }   # already opted in
    }
    $sm.ClientApplicationID = 'Le Relais Refurb'
    $sm.AddService2($script:MuServiceId, 7, '') | Out-Null
}

# One searcher per check attempt (cheap; avoids reusing a COM object across
# a retry that may have failed partway through).
function New-UpdateSearcher {
    Register-MicrosoftUpdateService
    $searcher = (New-Object -ComObject Microsoft.Update.Session).CreateUpdateSearcher()
    $searcher.ServerSelection = 3        # ssOthers: search the service named below,
    $searcher.ServiceID = $script:MuServiceId   # not just plain Windows Update
    return $searcher
}

function Get-PreviousState {
    if (Test-Path $StatusFile) {
        $raw = (Get-Content $StatusFile -TotalCount 1)
        if ($raw) { return ($raw -split '\|')[0].Trim() }
    }
    return $null
}
 
# Disable (not unregister) so Get-ScheduledTaskInfo / LastTaskResult stays
# readable afterwards. Unregistering is a separate hand-off cleanup step.
function Disable-RefurbTask {
    try { Disable-ScheduledTask -TaskName $TaskName -ErrorAction Stop | Out-Null }
    catch { Write-Log "WARNING could not disable task (manual run with no task registered?): $($_.Exception.Message)" }
}
 
function Test-RebootPending {
    # Independent of PSWindowsUpdate: WU agent's own flag + the CBS/WU keys.
    try { if ((New-Object -ComObject Microsoft.Update.SystemInfo).RebootRequired) { return $true } } catch { }
    foreach ($k in 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending',
                   'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') {
        if (Test-Path $k) { return $true }
    }
    return $false
}
 
# Hook for later stages (disk/activation/driver checks, app installs).
# Deliberately a no-op for now: see notes on winget under SYSTEM.
function Invoke-NextStage { }
 
# Keep the machine awake only while this process runs (no persistent
# power-plan change). ES_CONTINUOUS | ES_SYSTEM_REQUIRED.
try {
    Add-Type -Namespace Refurb -Name Power -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("kernel32.dll")]
public static extern uint SetThreadExecutionState(uint esFlags);
'@
    [void][Refurb.Power]::SetThreadExecutionState([uint32]'0x80000001')
} catch { }
 
# ------------------------------------------------------ single-instance lock
# Global\ so a SYSTEM task run and a manual admin run see the same mutex.
$mutex = New-Object System.Threading.Mutex($false, 'Global\RefurbUpdateLoop')
$haveLock = $false
try { $haveLock = $mutex.WaitOne(0) }
catch [System.Threading.AbandonedMutexException] { $haveLock = $true }  # previous holder died
if (-not $haveLock) {
    Write-Log "another instance is already running - exiting without touching state"
    exit 40
}
 
# ----------------------------------------------------------- pass counting
# Counted at START, before any risky call: a pass that hangs, gets killed by
# ExecutionTimeLimit, or loses power still consumes one pass, so no failure
# mode can loop without ever reaching the cap.
if (-not (Test-Path $CounterFile)) { Set-Content $CounterFile '0' -Encoding ASCII }
$script:Pass = 0
[void][int]::TryParse(((Get-Content $CounterFile -TotalCount 1) -as [string]).Trim(), [ref]$script:Pass)
 
$prev = Get-PreviousState
Set-Content $CounterFile ($script:Pass + 1) -Encoding ASCII
 
Start-Transcript -Path (Join-Path $TransDir "pass-$($script:Pass).txt") -Append | Out-Null
 
try {
    if ($prev -in 'CHECKING', 'INSTALLING') {
        # The previous run never reached a terminal state: killed by the task
        # time limit, power loss, or a crash that skipped our catch blocks.
        Write-Log "WARNING previous run ended abnormally while $prev (see its transcript)"
    }
 
    if ($script:Pass -ge $MaxPasses) {
        Write-Log "ABORTED - pass $($script:Pass) reached cap of $MaxPasses, needs manual review"
        Set-Status 'ABORTED' "reached pass cap ($MaxPasses) - see update-log.txt"
        Disable-RefurbTask
        exit 30
    }
 
    Write-Log "pass $($script:Pass) starting (run as $([Environment]::UserName))"
 
    # ------------------------------------------------------------- check
    $pending = $null
    $checkOk = $false
    $attempt = 0
    $lastErr = ''
    while (-not $checkOk) {
        $attempt++
        Set-Status 'CHECKING' "attempt $attempt"
        Write-Log "pass $($script:Pass) check attempt $attempt START"
        try {
            $searcher = New-UpdateSearcher
            $search = $searcher.Search('IsInstalled=0 and IsHidden=0 and BrowseOnly=0')
            if ([int]$search.ResultCode -ne 2) {
                # 2 = orcSucceeded. Anything else means the search itself did
                # not genuinely complete, even though it didn't throw.
                throw "search returned ResultCode=$([int]$search.ResultCode) (2=succeeded expected)"
            }
            $pending = @()
            foreach ($u in $search.Updates) { $pending += $u }
            $checkOk = $true
        } catch {
            $lastErr = (Format-Err $_)
            Write-Log "pass $($script:Pass) check attempt $attempt FAILED: $lastErr"
            if ($attempt -gt $CheckRetryDelaysSec.Count) { break }
            $wait = $CheckRetryDelaysSec[$attempt - 1]
            Set-Status 'CHECKING' "attempt $attempt failed, retrying in ${wait}s"
            Start-Sleep -Seconds $wait
        }
    }
 
    if (-not $checkOk) {
        # NOT a clean finish: task stays enabled so a plain reboot retries.
        Set-Status 'ERROR' "update check failed x$attempt : $lastErr"
        exit 10
    }
 
    Write-Log "pass $($script:Pass) check END - $($pending.Count) update(s) found"
 
    # ----------------------------------------------------- nothing found
    if ($pending.Count -eq 0) {
        if (Test-RebootPending) {
            # Updates can be hidden from search until a pending reboot
            # completes; don't call it done while one is outstanding.
            Write-Log "pass $($script:Pass) nothing found but a reboot is pending - rebooting"
            Set-Status 'REBOOTING' 'nothing found but reboot pending'
            Restart-Computer -Force
            exit 3010
        }

        # No separate confirmation search needed: the check above already
        # IS the Windows Update Agent (ResultCode 2 = genuinely succeeded),
        # not a third-party wrapper that might disagree with it.
        Write-Log "pass $($script:Pass) no updates found - stage complete"
        Set-Status 'DONE' 'no updates remaining'
        Disable-RefurbTask
        Invoke-NextStage
        exit 0
    }
 
    # ----------------------------------------------------------- install
    foreach ($u in $pending) { Write-Log "pass $($script:Pass)   pending: $($u.KBArticleIDs -join ',') $($u.Title)" }
    Set-Status 'INSTALLING' "$($pending.Count) update(s)"
    Write-Log "pass $($script:Pass) install START ($($pending.Count) update(s))"
    try {
        $toInstall = New-Object -ComObject Microsoft.Update.UpdateColl
        foreach ($u in $pending) {
            if (-not $u.EulaAccepted) { $u.AcceptEula() | Out-Null }
            [void]$toInstall.Add($u)
        }

        $session = New-Object -ComObject Microsoft.Update.Session
        $downloader = $session.CreateUpdateDownloader()
        $downloader.Updates = $toInstall
        $downloadResult = $downloader.Download()
        if ([int]$downloadResult.ResultCode -notin 2, 3) {   # 2=succeeded, 3=succeeded with errors
            throw "download returned ResultCode=$([int]$downloadResult.ResultCode)"
        }

        $toReallyInstall = New-Object -ComObject Microsoft.Update.UpdateColl
        foreach ($u in $toInstall) { if ($u.IsDownloaded) { [void]$toReallyInstall.Add($u) } }
        if ($toReallyInstall.Count -eq 0) {
            throw "none of $($toInstall.Count) update(s) downloaded successfully"
        }

        $installer = $session.CreateUpdateInstaller()
        $installer.ClientApplicationID = 'Le Relais Refurb'
        $installer.AllowSourcePrompts = $false   # no interactive session to prompt
        if ($installer.RebootRequiredBeforeInstallation) {
            throw 'a reboot is required before install can proceed (unexpected here - Test-RebootPending should have caught this on a prior pass)'
        }
        $installer.Updates = $toReallyInstall
        $installResult = $installer.Install()
    } catch {
        $msg = (Format-Err $_)
        Write-Log "pass $($script:Pass) install THREW: $msg"
        # Task stays enabled; machine does not reboot on its own. A reboot
        # (by a human) retries, bounded by the pass cap.
        Set-Status 'ERROR' "install failed: $msg"
        exit 20
    }

    # Per-update results. A few individual failures are normal WU churn and
    # a reboot is the standard remedy, so we log them and keep looping; the
    # pass cap is what stops an update that fails forever.
    # OperationResultCode: 2=Succeeded, 3=SucceededWithErrors, 4=Failed, 5=Aborted.
    $failed = 0
    for ($i = 0; $i -lt $toReallyInstall.Count; $i++) {
        $u = $toReallyInstall.Item($i)
        $rc = [int]($installResult.GetUpdateResult($i).ResultCode)
        $verdict = switch ($rc) {
            2 { 'Succeeded' }; 3 { 'SucceededWithErrors' }; 4 { 'Failed' }; 5 { 'Aborted' }
            default { "Unknown($rc)" }
        }
        Write-Log "pass $($script:Pass)   result: $verdict $($u.KBArticleIDs -join ',') $($u.Title)"
        if ($rc -in 4, 5) { $failed++ }
    }
    Write-Log "pass $($script:Pass) install END - $failed failed"
 
    Set-Status 'REBOOTING' "pass complete, $failed update(s) reported failed"
    Write-Log "pass $($script:Pass) rebooting"
    Restart-Computer -Force
    exit 3010
}
catch {
    # Anything not handled above (module missing, file permissions, ...).
    $msg = (Format-Err $_)
    try { Write-Log "pass $($script:Pass) UNHANDLED: $msg" } catch { }
    try { Set-Status 'ERROR' "unhandled: $msg" } catch { }
    exit 1
}
finally {
    try { Stop-Transcript | Out-Null } catch { }
    if ($haveLock) { try { $mutex.ReleaseMutex() } catch { } }
}
 
