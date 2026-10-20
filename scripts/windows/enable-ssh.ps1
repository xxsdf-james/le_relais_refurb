<#
  enable-ssh.ps1 - turn on key-only OpenSSH Server access on a target Windows
  machine, authorized against a GitHub account's public keys
  (https://github.com/<user>.keys).

  Run this ON THE TARGET MACHINE, in an elevated PowerShell prompt:

    powershell -NoProfile -ExecutionPolicy Bypass -File .\enable-ssh.ps1 <github-username>

  What it changes:
    - installs the OpenSSH Server capability, starts sshd, sets it Automatic
    - firewall rule OpenSSH-Server-In-TCP: all network profiles, but only
      from the local subnet (see below)
    - C:\ProgramData\ssh\administrators_authorized_keys: the GitHub keys,
      readable by Administrators and SYSTEM only

  Firewall: the rule the capability creates is enabled for the Private
  profile only, and Windows puts a new network in Public when setup skips the
  question, so connections time out (confirmed on a Lenovo at Le Relais,
  2026-10-20; docs/known-issues.md). The rule is opened for every profile but
  limited to RemoteAddress LocalSubnet, rather than switching the network to
  Private, which would also open file sharing and discovery.

  Key file ACL: set by SID (S-1-5-32-544 Administrators, S-1-5-18 SYSTEM),
  because group names are translated on French Windows and icacls fails on
  "Administrators" (exit 1332).

  Every step is checked; the script stops at the first failure.

  MANDATORY: run disable-ssh.ps1 before this machine goes to its recipient.
  Unlike a Linux live session (wiped and reinstalled regardless), this server
  persists on the actual install unless explicitly removed. See
  docs/ssh-access.md.

  KEEP THIS FILE ASCII-ONLY: Windows PowerShell 5.1 reads BOM-less files as
  ANSI, so accented characters would be mangled.
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$GitHubUser
)

$ErrorActionPreference = 'Stop'
$Capability = 'OpenSSH.Server~~~~0.0.1.0'
$RuleName   = 'OpenSSH-Server-In-TCP'
$SshDir     = "$env:ProgramData\ssh"
$KeysPath   = Join-Path $SshDir 'administrators_authorized_keys'
$AdminsSid  = 'S-1-5-32-544'
$SystemSid  = 'S-1-5-18'

function Fail([string]$m) { Write-Host "FAILED: $m" -ForegroundColor Red; exit 1 }
function Ok([string]$m)   { Write-Host "OK: $m" }

# 1. Elevated?
$id = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not (New-Object Security.Principal.WindowsPrincipal $id).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Fail 'not elevated - reopen PowerShell as Administrator'
}

# 2. OpenSSH Server capability. Downloads from Windows Update: a few minutes
#    with no output is normal.
Write-Host 'Installing OpenSSH Server (a few minutes, no output)...'
try { Add-WindowsCapability -Online -Name $Capability | Out-Null }
catch { Fail "Add-WindowsCapability: $($_.Exception.Message)" }
$state = (Get-WindowsCapability -Online -Name $Capability).State
if ($state -ne 'Installed') { Fail "capability state is '$state', expected Installed" }
Ok 'OpenSSH Server installed'

# 3. sshd running and Automatic. The first start creates C:\ProgramData\ssh
#    and the host keys.
try {
    Set-Service -Name sshd -StartupType Automatic
    Start-Service sshd
} catch { Fail "sshd: $($_.Exception.Message)" }
if ((Get-Service sshd).Status -ne 'Running') { Fail 'sshd is not running' }
Ok 'sshd running, Automatic'

# 4. Firewall: every profile, local subnet only. Create the rule if the
#    capability didn't.
try {
    if (Get-NetFirewallRule -Name $RuleName -ErrorAction SilentlyContinue) {
        Set-NetFirewallRule -Name $RuleName -Enabled True -Profile Any -RemoteAddress LocalSubnet
    } else {
        New-NetFirewallRule -Name $RuleName -DisplayName 'OpenSSH Server (sshd)' `
            -Direction Inbound -Protocol TCP -LocalPort 22 -Action Allow `
            -Profile Any -RemoteAddress LocalSubnet | Out-Null
    }
} catch { Fail "firewall rule: $($_.Exception.Message)" }
$rule   = Get-NetFirewallRule -Name $RuleName
$remote = ($rule | Get-NetFirewallAddressFilter).RemoteAddress
if ($rule.Profile -ne 'Any' -or "$remote" -ne 'LocalSubnet' -or $rule.Enabled -ne 'True') {
    Fail "firewall rule is Profile=$($rule.Profile) RemoteAddress=$remote Enabled=$($rule.Enabled)"
}
Ok 'firewall rule: all profiles, LocalSubnet'

# 5. Keys from GitHub. Admin accounts use this separate file; sshd ignores
#    the per-user authorized_keys for them.
try { $keys = (Invoke-WebRequest -Uri "https://github.com/$GitHubUser.keys" -UseBasicParsing).Content }
catch { Fail "downloading https://github.com/$GitHubUser.keys: $($_.Exception.Message)" }
if ($keys -is [byte[]]) { $keys = [Text.Encoding]::ASCII.GetString($keys) }
$keyLines = @($keys -split "`n" | Where-Object { $_ -match '^(ssh-|ecdsa-|sk-)' })
if ($keyLines.Count -eq 0) { Fail "no SSH keys published for GitHub user '$GitHubUser'" }
[IO.File]::WriteAllText($KeysPath, (($keyLines | ForEach-Object { $_.Trim() }) -join "`n") + "`n")
Ok "$($keyLines.Count) key(s) written to $KeysPath"

# 6. Key file ACL: Administrators and SYSTEM only, no inheritance.
& icacls.exe $KeysPath /inheritance:r /grant "*${AdminsSid}:F" /grant "*${SystemSid}:F" | Out-Null
if ($LASTEXITCODE -ne 0) { Fail "icacls exited with $LASTEXITCODE" }
$acl  = Get-Acl $KeysPath
$sids = @($acl.Access | ForEach-Object {
    $_.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value })
$extra = @($sids | Where-Object { $_ -ne $AdminsSid -and $_ -ne $SystemSid })
if (-not $acl.AreAccessRulesProtected -or $extra.Count -gt 0) {
    Fail "key file ACL still has inherited or extra entries: $($sids -join ', ')"
}
Ok 'key file readable by Administrators and SYSTEM only'

# 7. How to connect. Only adapters with a default gateway: a disconnected
#    Wi-Fi or Bluetooth adapter has a useless 169.254.x.x address.
$ips = @(Get-NetIPConfiguration |
    Where-Object { $_.IPv4DefaultGateway -and $_.NetAdapter.Status -eq 'Up' } |
    ForEach-Object { $_.IPv4Address.IPAddress })
if ($ips.Count -eq 0) { $ips = @('<ip-not-found>') }
$keygen = "$env:WINDIR\System32\OpenSSH\ssh-keygen.exe"
$fingerprint = if (Test-Path $keygen) {
    & $keygen -lf (Join-Path $SshDir 'ssh_host_ed25519_key.pub')
} else { '(ssh-keygen not found)' }

Write-Host ''
Write-Host 'Done. Host key, to compare with what the laptop is shown:'
Write-Host "  $fingerprint"
Write-Host 'From the laptop:'
foreach ($ip in $ips) {
    Write-Host "  ssh -o IdentitiesOnly=yes -i ~/.ssh/id_ed25519_refurb $env:USERNAME@$ip"
}
Write-Host ''
Write-Host 'REMINDER: run disable-ssh.ps1 before this machine goes to its recipient.' -ForegroundColor Yellow
