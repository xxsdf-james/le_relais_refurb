# SSH access for bench troubleshooting

*Living document — see CLAUDE.md, "Status of the docs."*

## Purpose

Replaces ad hoc text-sharing (previously dontpad.com, a public unauthenticated
pastebin — dropped 2026-09-28) for two things during live bench troubleshooting:
sending one-off test/troubleshooting commands or small scripts to a target
machine, and pulling logs or captured results back. This is separate from —
and doesn't replace — the formal script delivery path in CLAUDE.md
(`raw.githubusercontent.com` + SHA-256 checksum), which is for the real
toolkit scripts (`diagnostics.sh`, etc.), not ad hoc one-liners.

This also answers the open item "where diagnostic results go without the
Toolbox USB" (see the repo-migration handoff) for anything moved this way.

## One-time setup — your laptop

You're always the client, initiating the connection outward, so the laptop
only needs a keypair and that key registered with GitHub — no server runs
here.

```
ssh-keygen -t ed25519 -C "<label>" -N "" -f ~/.ssh/id_ed25519_refurb
```

`-N ""` skips setting a passphrase — acceptable for this specific case
because the private key never leaves the laptop and every machine it
unlocks is either an ephemeral live session or a machine still under your
control pre-handoff, not a general-purpose credential. Add the printed
`.pub` line to your GitHub account under **Settings → SSH and GPG keys**
(the SSH section — this is not a GPG key, don't add it there).

Why GitHub: it publishes a user's public keys, unauthenticated, at
`https://github.com/<username>.keys`. `github.com` already passes through
the Le Relais network's HTTPS interception untouched (CONFIRMED
2026-09-28), so this works from any target machine with basic internet
access — no separate credential distribution needed.

## Per machine — Linux (Ubuntu Live)

On the target, from the live session:
```
sudo bash scripts/linux/enable-ssh.sh <your-github-username>
```
(fetched via the usual delivery path once this repo is public; for now,
copy it over some other way). It installs `openssh-server`, writes your
key into the live user's `authorized_keys`, and starts `ssh`. It prints the
connect command at the end.

From the laptop:
```
ssh -i ~/.ssh/id_ed25519_refurb <user>@<target-ip>
scp -i ~/.ssh/id_ed25519_refurb <file> <user>@<target-ip>:~/
```

No cleanup needed afterward — the live session is inherently ephemeral,
and the drive gets wiped and reinstalled regardless.

## Per machine — Windows

In an elevated PowerShell prompt on the target:
```
powershell -ExecutionPolicy Bypass -File .\enable-ssh.ps1 <your-github-username>
```

**Mandatory, before this machine goes to its recipient:**
```
powershell -ExecutionPolicy Bypass -File .\disable-ssh.ps1
```
Unlike the Linux live session, this OpenSSH Server runs on the actual
persistent install — skipping cleanup leaves a remotely-reachable SSH
server trusting a technician's personal key for admin access on someone's
low-budget PC. Add this to the end-of-workflow checklist for the 36
Windows-only machines; don't rely on remembering it ad hoc.

## Resolved: `scp` "subsystem request failed" — missing `Subsystem sftp` line

CONFIRMED 2026-09-28, on the Ubuntu Live image used for the 002-sata-ssd
fixture capture: plain `scp` (which defaults to the SFTP protocol on
modern OpenSSH clients) failed with `subsystem request failed on channel
0` / `scp: Connection closed`. Root cause, confirmed 2026-09-28: this live
image ships a pre-modified `/etc/ssh/sshd_config` that lacks a `Subsystem
sftp ...` line; the `openssh-server` package's own default config has it.
Installing the package over the pre-existing file triggers a dpkg
conffile prompt ("Configuration file '/etc/ssh/sshd_config' ... modified
since installation") — taking the package maintainer's version restores
the `Subsystem sftp` line and fixes plain `scp`, no `-O` needed.

`enable-ssh.sh` now passes `--force-confnew` to `apt install`
(`scripts/linux/enable-ssh.sh`) so this is applied automatically and the
prompt no longer appears. If you hit "subsystem request failed" again
(e.g. running an older copy of the script, or installing
`openssh-server` by hand), either re-pull the script or answer the
conffile prompt with the package maintainer's version, then retry `scp`.

## First-connection host key prompt

Every fresh live boot or fresh Windows install has no prior SSH host
identity, so the first connection to each machine always shows "the
authenticity of host ... can't be established, continue connecting?" —
EXPECTED every time, not an error. Safe to accept for this LAN-local,
hands-on-the-machine workflow.

## "REMOTE HOST IDENTIFICATION HAS CHANGED" on reconnect

EXPECTED, not a MITM signal, for this workflow specifically. Cause: each
`enable-ssh.sh` run installs `openssh-server` fresh into that live
session; the package install generates a new host key on the spot, and
the Live filesystem doesn't persist it. So a *different* live boot of the
*same* machine — e.g. the opening-diagnostics boot vs. the
closing-diagnostics boot later in `toolkit-reference.md`'s per-machine
workflow — always presents a different host key at the same IP. DHCP
handing that IP to a *different* bench machine between sessions triggers
the identical warning. There's no host-key pinning in this design to
check the new key against (the GitHub-published-key model above
authenticates you to the target, not the target's identity to you) — the
real trust boundary is physical: you're at the bench, you just watched
`enable-ssh.sh` print that connect command.

Fix — remove only the stale entry, then reconnect and accept the new key:
```
ssh-keygen -R <target-ip>
```
Don't disable `StrictHostKeyChecking` globally to work around this; it's
still meaningful for anything outside this specific ephemeral-live-session
case (e.g. non-LAN-local connections).
