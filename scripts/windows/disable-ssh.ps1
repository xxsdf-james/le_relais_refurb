<#
  disable-ssh.ps1 - reverse enable-ssh.ps1. Run this before a Windows machine
  goes to its recipient, in an elevated PowerShell prompt:

    powershell -NoProfile -ExecutionPolicy Bypass -File .\disable-ssh.ps1

  Why this is mandatory, not optional: enable-ssh.ps1 leaves a
  remotely-reachable SSH server on the machine, trusting a technician's
  personal key for admin access. That's fine for bench troubleshooting on a
  machine you still control; it is not something to hand to a recipient.

  Removes the OpenSSH Server capability, the OpenSSH-Server-In-TCP firewall
  rule, and all of C:\ProgramData\ssh. Removing the capability alone leaves
  that folder behind with the host private keys, sshd_config and the
  connection logs (seen on a Lenovo at Le Relais, 2026-10-20).

  Then checks that each one is gone and that nothing listens on port 22.
  Exit 0 = all clean; exit 1 = at least one FAIL line, fix it before handoff.

  KEEP THIS FILE ASCII-ONLY: Windows PowerShell 5.1 reads BOM-less files as
  ANSI, so accented characters would be mangled.
#>

$ErrorActionPreference = 'Stop'
$Capability = 'OpenSSH.Server~~~~0.0.1.0'
$RuleName   = 'OpenSSH-Server-In-TCP'
$SshDir     = "$env:ProgramData\ssh"

# 1. Elevated?
$id = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not (New-Object Security.Principal.WindowsPrincipal $id).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host 'FAILED: not elevated - reopen PowerShell as Administrator' -ForegroundColor Red
    exit 1
}

# 2. Remove. Each step carries on if the item is already gone, so the script
#    can be re-run after a partial failure.
Stop-Service sshd -ErrorAction SilentlyContinue
$restart = $false
if ((Get-WindowsCapability -Online -Name $Capability).State -ne 'NotPresent') {
    Write-Host 'Removing OpenSSH Server (may take a minute)...'
    try { $restart = (Remove-WindowsCapability -Online -Name $Capability).RestartNeeded }
    catch { Write-Host "Remove-WindowsCapability: $($_.Exception.Message)" -ForegroundColor Red }
}
Get-NetFirewallRule -Name $RuleName -ErrorAction SilentlyContinue | Remove-NetFirewallRule
if (Test-Path $SshDir) {
    try { Remove-Item $SshDir -Recurse -Force }
    catch { Write-Host "Removing ${SshDir}: $($_.Exception.Message)" -ForegroundColor Red }
}

# 3. Verify.
$failed = $false
function Check([bool]$clean, [string]$what) {
    if ($clean) { Write-Host "OK:   $what" }
    else        { Write-Host "FAIL: $what" -ForegroundColor Red; $script:failed = $true }
}
Check ((Get-WindowsCapability -Online -Name $Capability).State -eq 'NotPresent') 'OpenSSH Server capability removed'
Check (-not (Get-Service sshd -ErrorAction SilentlyContinue)) 'sshd service gone'
Check (-not (Get-NetFirewallRule -Name $RuleName -ErrorAction SilentlyContinue)) "firewall rule $RuleName gone"
Check (-not (Test-Path $SshDir)) "$SshDir gone"
Check (-not (Get-NetTCPConnection -LocalPort 22 -State Listen -ErrorAction SilentlyContinue)) 'nothing listening on port 22'

if ($restart) { Write-Host 'Windows asks for a restart to finish removing the capability.' -ForegroundColor Yellow }
if ($failed) {
    Write-Host 'NOT CLEAN - fix the FAIL lines before this machine is handed over.' -ForegroundColor Red
    exit 1
}
Write-Host 'Clean: no SSH server, rule, keys or logs left.'
