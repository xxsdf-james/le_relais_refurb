# enable-ssh.ps1 — turn on key-only OpenSSH Server access on a target Windows
# machine, authorized against a GitHub account's public keys
# (https://github.com/<user>.keys). Installs the OpenSSH Server capability
# and starts sshd. No other changes.
#
# Run this ON THE TARGET MACHINE, in an elevated PowerShell prompt.
#
# MANDATORY: run disable-ssh.ps1 before this machine goes to its recipient.
# Unlike a Linux live session (wiped and reinstalled regardless), this
# server persists on the actual install unless explicitly removed. See
# docs/ssh-access.md.
#
# Usage: powershell -ExecutionPolicy Bypass -File .\enable-ssh.ps1 <github-username>

param(
    [Parameter(Mandatory = $true)]
    [string]$GitHubUser
)

Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0 | Out-Null
Start-Service sshd
Set-Service -Name sshd -StartupType Automatic

# Admin accounts use a separate, tightly-permissioned key file — sshd
# ignores the normal per-user authorized_keys for them. This is the
# account you're using on a freshly imaged machine, so this applies.
$authorizedKeysPath = "$env:ProgramData\ssh\administrators_authorized_keys"
Invoke-WebRequest -Uri "https://github.com/$GitHubUser.keys" -OutFile $authorizedKeysPath
icacls.exe $authorizedKeysPath /inheritance:r /grant "Administrators:F" /grant "SYSTEM:F" | Out-Null

$targetIp = (Get-NetIPAddress -AddressFamily IPv4 |
    Where-Object { $_.InterfaceAlias -notmatch 'Loopback' } |
    Select-Object -First 1).IPAddress

Write-Host ""
Write-Host "Done. From the laptop:"
Write-Host "  ssh -i ~/.ssh/id_ed25519_refurb $env:USERNAME@$targetIp"
Write-Host ""
Write-Host "REMINDER: run disable-ssh.ps1 before this machine goes to its recipient." -ForegroundColor Yellow
