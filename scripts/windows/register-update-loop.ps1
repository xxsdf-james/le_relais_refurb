<#
  register-update-loop.ps1 - run ONCE per machine from the Toolbox USB, in an
  elevated Windows PowerShell:
 
    powershell -NoProfile -ExecutionPolicy Bypass -File E:\refurb\register-update-loop.ps1
 
  Expected layout next to this script on the USB:
    update-loop.ps1
    check-update-status.ps1
    modules\PSWindowsUpdate\<version>\...   (copied from a machine with internet)
 
  Switches:
    -MaxPasses N        pass cap passed to update-loop.ps1 (default 10)
    -TimeLimitHours N   ExecutionTimeLimit for a single run (default 4)
    -NoStart            register only; first pass runs at next boot
    -KeepState          don't reset counter/status (re-registering mid-stage)
 
  Safe to re-run: it replaces an existing task, but refuses while one is
  actually running. ASCII-only for the same reason as update-loop.ps1.
#>
param(
    [int]$MaxPasses = 10,
    [double]$TimeLimitHours = 4,
    [switch]$NoStart,
    [switch]$KeepState
)
 
$ErrorActionPreference = 'Stop'
$TaskName  = 'RefurbWindowsUpdate'
$Dir       = 'C:\ProgramData\Refurb'
$ModDest   = 'C:\Program Files\WindowsPowerShell\Modules\PSWindowsUpdate'
$Src       = $PSScriptRoot
 
function Fail([string]$m) { Write-Host "FAILED: $m" -ForegroundColor Red; exit 1 }
 
# 1. Elevated?
$id = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not (New-Object Security.Principal.WindowsPrincipal $id).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Fail 'not elevated - reopen PowerShell as Administrator'
}
 
# 2. Source files present on the USB?
foreach ($f in 'update-loop.ps1', 'check-update-status.ps1') {
    if (-not (Test-Path (Join-Path $Src $f))) { Fail "missing $f next to this script ($Src)" }
}
 
# 3. Refuse to pull the rug out from under a running pass.
$existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($existing -and $existing.State -eq 'Running') {
    Fail "task $TaskName is running right now - wait for it, or Stop-ScheduledTask first"
}
 
# 4. PSWindowsUpdate into the AllUsers module path (no Install-Module: the
#    Le Relais network blocks powershellgallery.com).
if (-not (Test-Path $ModDest)) {
    $modSrc = Join-Path $Src 'modules\PSWindowsUpdate'
    if (-not (Test-Path $modSrc)) { Fail "PSWindowsUpdate not installed and not found at $modSrc" }
    Copy-Item -Path $modSrc -Destination $ModDest -Recurse -Force
    Write-Host "copied PSWindowsUpdate to $ModDest"
}
# Prove it imports in a clean process - the same way the task will load it.
$modVer = & powershell.exe -NoProfile -ExecutionPolicy Bypass -Command `
    "Import-Module PSWindowsUpdate -ErrorAction Stop; (Get-Module PSWindowsUpdate).Version.ToString()" 2>&1
if ($LASTEXITCODE -ne 0) { Fail "PSWindowsUpdate does not import: $modVer" }
Write-Host "PSWindowsUpdate $modVer imports OK"
 
# 5. Working folder, locked down. SYSTEM runs whatever is in update-loop.ps1,
#    so only SYSTEM and Administrators may write here.
New-Item -ItemType Directory -Path $Dir -Force | Out-Null
& icacls.exe $Dir /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' /T /Q | Out-Null
if ($LASTEXITCODE -ne 0) { Fail "icacls failed on $Dir" }
 
Copy-Item (Join-Path $Src 'update-loop.ps1')          $Dir -Force
Copy-Item (Join-Path $Src 'check-update-status.ps1')  $Dir -Force
 
if (-not $KeepState) {
    Set-Content (Join-Path $Dir 'update-pass-count.txt') '0' -Encoding ASCII
    Set-Content (Join-Path $Dir 'update-status.txt') `
        ("REGISTERED | pass 0 | since {0} | waiting for first run" -f (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss')) -Encoding ASCII
    Add-Content (Join-Path $Dir 'update-log.txt') "$(Get-Date -Format o)  registered (MaxPasses=$MaxPasses, TimeLimit=${TimeLimitHours}h)" -Encoding UTF8
}
 
# 6. The task.
$scriptPath = Join-Path $Dir 'update-loop.ps1'
$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument (
    "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$scriptPath`" -MaxPasses $MaxPasses")
 
$trigger = New-ScheduledTaskTrigger -AtStartup
$trigger.Delay = 'PT1M'   # give the network stack a head start after boot
 
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
 
$settings = New-ScheduledTaskSettingsSet `
    -ExecutionTimeLimit (New-TimeSpan -Minutes ([int]($TimeLimitHours * 60))) `
    -MultipleInstances IgnoreNew `
    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
 
if ($existing) { Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false }
Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
    -Principal $principal -Settings $settings | Out-Null
 
# 7. Read back what Windows actually stored, rather than trusting our inputs.
$t = Get-ScheduledTask -TaskName $TaskName
Write-Host ''
Write-Host "Task        : $($t.TaskName)  [$($t.State)]"
Write-Host "Runs as     : $($t.Principal.UserId)  RunLevel=$($t.Principal.RunLevel)"
Write-Host "Action      : $($t.Actions[0].Execute) $($t.Actions[0].Arguments)"
Write-Host "Time limit  : $($t.Settings.ExecutionTimeLimit)"
Write-Host "Trigger     : AtStartup, delay $($t.Triggers[0].Delay)"
 
if (-not $NoStart) {
    Start-ScheduledTask -TaskName $TaskName
    Write-Host ''
    Write-Host 'Started. The machine will reboot on its own when a pass installs updates.'
    Write-Host "Check progress any time: powershell -ExecutionPolicy Bypass -File $Dir\check-update-status.ps1"
}
