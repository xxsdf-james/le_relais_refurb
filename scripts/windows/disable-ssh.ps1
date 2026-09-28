# disable-ssh.ps1 — reverse enable-ssh.ps1. Run this before a Windows
# machine goes to its recipient, in an elevated PowerShell prompt.
#
# Why this is mandatory, not optional: enable-ssh.ps1 leaves a
# remotely-reachable SSH server on the machine, trusting a technician's
# personal key for admin access. That's fine for bench troubleshooting on
# a machine you still control; it is not something to hand to a recipient.
#
# Usage: powershell -ExecutionPolicy Bypass -File .\disable-ssh.ps1

Stop-Service sshd -ErrorAction SilentlyContinue
Remove-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0 | Out-Null
Remove-Item "$env:ProgramData\ssh\administrators_authorized_keys" -Force -ErrorAction SilentlyContinue

Write-Host "OpenSSH Server removed and administrators_authorized_keys deleted."
