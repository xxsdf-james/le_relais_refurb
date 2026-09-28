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
scp -O -i ~/.ssh/id_ed25519_refurb <file> <user>@<target-ip>:~/
```
See the known issue below for why `scp` needs `-O`.

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

## Known issue: `scp` fails with "subsystem request failed" — use `-O`

CONFIRMED 2026-09-28, on the Ubuntu Live image used for the 002-sata-ssd
fixture capture: plain `scp` (which defaults to the SFTP protocol on
modern OpenSSH clients) fails with `subsystem request failed on channel 0`
/ `scp: Connection closed`, even after installing `openssh-sftp-server`.
Root cause not fully isolated — installing the binary alone didn't fix
it, so it's more likely a missing `Subsystem sftp ...` line in
`/etc/ssh/sshd_config` on this image than a missing binary; not
re-investigated further since the workaround is sufficient.

**Workaround (sufficient for this workflow):** always pass `-O` to `scp`,
which forces the older SCP protocol and bypasses the SFTP subsystem
entirely:
```
scp -O -i ~/.ssh/id_ed25519_refurb <src> <user>@<ip>:<dst>
```

If this needs a real fix later (e.g. for `sftp`/GUI file-browser use), the
next step would be checking `grep -n "^Subsystem" /etc/ssh/sshd_config` on
the target and adding the line if absent, then `sudo systemctl restart
ssh`.

## First-connection host key prompt

Every fresh live boot or fresh Windows install has no prior SSH host
identity, so the first connection to each machine always shows "the
authenticity of host ... can't be established, continue connecting?" —
EXPECTED every time, not an error. Safe to accept for this LAN-local,
hands-on-the-machine workflow.
