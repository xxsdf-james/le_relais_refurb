<#
  check-update-status.ps1 - one-screen verdict for the Windows Update stage.
  Read-only; changes nothing. Run elevated:
 
    powershell -ExecutionPolicy Bypass -File C:\ProgramData\Refurb\check-update-status.ps1
 
  Combines three sources that fail independently:
    - our status file (what the script last SAID it was doing)
    - the task's State / LastTaskResult (what Windows SAW happen)
    - last boot time (whether a promised reboot actually happened)
#>
$ErrorActionPreference = 'Continue'
$TaskName   = 'RefurbWindowsUpdate'
$Dir        = 'C:\ProgramData\Refurb'
$StaleHours = 4    # keep in line with the task's ExecutionTimeLimit
 
# Keyed by unsigned hex string: LastTaskResult is a UInt32 and task
# Scheduler codes like 0x8004131F don't fit a signed [int].
$codes = @{
    '0x0'        = 'our exit 0: DONE'
    '0xBC2'      = 'our exit 3010: reboot requested'
    '0xA'        = 'our exit 10: update check failed'
    '0xC'        = 'our exit 12: check results disagree'
    '0x14'       = 'our exit 20: install threw'
    '0x1E'       = 'our exit 30: pass cap reached'
    '0x28'       = 'our exit 40: another instance was running'
    '0x1'        = 'exit 1: unhandled PowerShell error'
    '0x41301'    = 'task is currently running'
    '0x41303'    = 'task has not yet run'
    '0x41306'    = 'task was terminated (time limit or manual stop)'
    '0x8004131F' = 'an instance was already running'
}
 
# --- our status file
$line = if (Test-Path "$Dir\update-status.txt") { Get-Content "$Dir\update-status.txt" -TotalCount 1 } else { $null }
$state = $null; $since = $null
if ($line) {
    $parts = $line -split '\|'
    $state = $parts[0].Trim()
    if ($parts.Count -ge 3) { $since = [datetime]::ParseExact(($parts[2] -replace 'since', '').Trim(), 'yyyy-MM-ddTHH:mm:ss', $null) }
}
 
# --- Windows' view
$task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
$info = if ($task) { Get-ScheduledTaskInfo -TaskName $TaskName } else { $null }
$boot = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
$now  = Get-Date
 
Write-Host "Status file : $line"
if ($task) {
    $r = [int64]$info.LastTaskResult
    if ($r -lt 0) { $r += 4294967296 }
    $hex = '0x{0:X}' -f $r
    $meaning = if ($codes.ContainsKey($hex)) { $codes[$hex] } else { 'unknown - search the hex code' }
    Write-Host ("Task        : {0}, last run {1}, LastTaskResult {2} = {3}" -f
                $task.State, $info.LastRunTime, $hex, $meaning)
} else {
    Write-Host 'Task        : NOT REGISTERED'
}
Write-Host "Last boot   : $boot"
Write-Host "Pass count  : $(Get-Content "$Dir\update-pass-count.txt" -ErrorAction SilentlyContinue)"
Write-Host ''
Write-Host '--- last 8 log lines'
Get-Content "$Dir\update-log.txt" -Tail 8 -ErrorAction SilentlyContinue
Write-Host ''
 
# --- verdict
$v =
    if (-not $line)                    { 'NO STATUS FILE - stage never ran here, or folder was cleaned up' }
    elseif (-not $task -and $state -ne 'DONE') { 'TASK MISSING but stage not DONE - re-run register-update-loop.ps1 -KeepState' }
    elseif ($state -eq 'DONE')         { 'OK - updates complete' }
    elseif ($state -eq 'ABORTED')      { 'NEEDS HUMAN - pass cap reached. Read the log for a KB that keeps reappearing.' }
    elseif ($state -eq 'ERROR')        { 'NEEDS HUMAN - see detail in status line; a plain reboot retries automatically' }
    elseif ($state -in 'CHECKING','INSTALLING') {
        if ($task.State -eq 'Running') {
            $h = [math]::Round(($now - $since).TotalHours, 1)
            if (($now - $since).TotalHours -gt $StaleHours) { "SUSPECT HUNG - $state for ${h}h, still running (time limit should kill it soon)" }
            else { "IN PROGRESS - $state for ${h}h" }
        } else { "DIED MID-RUN - status says $state but task is not running (killed by time limit, crash, or power loss). Reboot to retry." }
    }
    elseif ($state -eq 'REBOOTING') {
        if ($since -and $boot -lt $since) { 'REBOOT DID NOT HAPPEN - status says rebooting but no boot since then. Reboot manually.' }
        elseif ($task.State -eq 'Running') { 'IN PROGRESS - rebooted, next pass starting' }
        elseif (($now - $boot).TotalMinutes -gt 10) { 'TASK DID NOT FIRE AFTER REBOOT - check task is Enabled (Get-ScheduledTask)' }
        else { 'IN PROGRESS - rebooted recently, task starts ~1 min after boot' }
    }
    elseif ($state -eq 'REGISTERED')   { if ($task.State -eq 'Running') { 'IN PROGRESS - first pass' } else { 'WAITING - registered, not started yet (reboot or Start-ScheduledTask)' } }
    else                               { "UNRECOGNISED STATE '$state'" }
 
Write-Host "VERDICT     : $v"
