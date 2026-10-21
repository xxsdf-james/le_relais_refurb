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

On the target, from the live session — fetch, verify, run (CLAUDE.md, "Delivery to
target machines"):
```
wget -O enable-ssh.sh https://raw.githubusercontent.com/xxsdf-james/le_relais_refurb/refs/tags/<tag>/scripts/linux/enable-ssh.sh
sha256sum enable-ssh.sh      # compare with the value in the Obsidian note
sudo bash enable-ssh.sh <your-github-username>
```
It installs `openssh-server`, writes your key into the live user's `authorized_keys`,
and starts `ssh`. It prints the connect command at the end.

Each Ubuntu Live boot is a fresh session with no memory of a previous one — running
this during opening diagnostics doesn't carry over to the closing-diagnostics boot
later. Run it again on that second boot too (see `toolkit-reference.md`'s per-machine
workflow, steps 2–3 and 11–12).

From the laptop:
```
ssh -i ~/.ssh/id_ed25519_refurb <user>@<target-ip>
scp -i ~/.ssh/id_ed25519_refurb <file> <user>@<target-ip>:~/
```

No cleanup needed afterward — the live session is inherently ephemeral,
and the drive gets wiped and reinstalled regardless.

## Per machine — Windows

Fetch, verify, run, in an elevated PowerShell prompt on the target (CLAUDE.md,
"Delivery to target machines"):
```
Invoke-WebRequest -Uri https://raw.githubusercontent.com/xxsdf-james/le_relais_refurb/refs/tags/<tag>/scripts/windows/enable-ssh.ps1 -OutFile enable-ssh.ps1
Get-FileHash enable-ssh.ps1 -Algorithm SHA256    # compare with the value in the Obsidian note
powershell -ExecutionPolicy Bypass -File .\enable-ssh.ps1 <your-github-username>
```
It prints `OK:` per step and stops at the first `FAILED:`. At the end it prints the
host key fingerprint and the connect command. It opens the firewall rule for every
network profile but only from the local subnet: without that, a Public network (the
usual case) times out (`known-issues.md`, "Remote access (SSH)").

From the laptop, first connection to this install:
```
ssh-keygen -R <target-ip>     # only if known_hosts has an old key for this address
ssh -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new -i ~/.ssh/id_ed25519_refurb Admin@<target-ip>
```
Check that the `Server host key: ssh-ed25519 SHA256:...` it shows (add `-v`) matches
the fingerprint the script printed. `IdentitiesOnly=yes` stops ssh-agent offering
your other keys to the target if the refurb key is refused. Use it on every
`ssh`/`scp` to a target, Linux or Windows.

**Mandatory, before this machine goes to its recipient:**
```
powershell -ExecutionPolicy Bypass -File .\disable-ssh.ps1
```
It removes the capability, the firewall rule and all of `C:\ProgramData\ssh` (host
keys, logs), then checks each is gone. Only `Clean:` with exit 0 counts as done; any
`FAIL:` line has to be fixed before handoff.
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
the identical warning. Before v16 there was no host-key pinning in this
design to check the new key against (the GitHub-published-key model above
authenticates you to the target, not the target's identity to you), so
the trust boundary was only physical. Since v16 it's checked: see
"Session code" below.

Fix — remove the stale entry, then add the new key non-interactively:
```
ssh-keygen -R <target-ip>
ssh-keyscan -t ed25519 <target-ip> >> ~/.ssh/known_hosts
```
CONFIRMED 2026-09-28: after `ssh-keygen -R`, the normal interactive
"continue connecting (yes/no)?" prompt for the new key did not get
answered when `scp` ran nested inside a script — it failed closed
("Host key verification failed") rather than waiting for input. Cause not
fully isolated, but `ssh-keyscan` sidesteps it entirely by adding the key
non-interactively, which is the same trust-on-first-use acceptance a
manual "yes" would have done anyway (see above — there's nothing to
verify the new key against either way). Do the same by hand before a
plain interactive `ssh`/`scp` session if you hit this. The laptop scripts
no longer do it (see below).

Don't disable `StrictHostKeyChecking` globally to work around this; it's
still meaningful for anything outside this specific ephemeral-live-session
case (e.g. non-LAN-local connections).

## Session code: checking the target's identity (v16+)

`enable-ssh.sh` v16 prints a **session code** on the target's screen: the first 6 hex
characters of the SHA-256 of that boot's ed25519 host key (the same hash `ssh-keygen -l`
shows in base64). The laptop scripts (`scripts/laptop/lib-target.sh`) scan the key
actually answering at the IP, compute the same code, and ask you to type the one on the
screen. A match means the IP is the machine you're reading. 6 hex characters leave about
a 1 in 16.7 million chance of a different machine matching by accident.

The verified key is then pinned in `le_relais_refurb_results/.known_hosts/<ip>`, and
every `ssh`/`scp` the scripts make uses that file with `StrictHostKeyChecking=yes`. A new
boot, or a different machine taking that IP, presents a different key. The scripts then
ask for the code again instead of trusting it. `~/.ssh/known_hosts` isn't touched.

Before v16, `pull-results.sh`/`push-summary.sh` re-scanned and trusted whatever key
answered (trust on first use). For a target running an older `enable-ssh.sh`, which shows
no code, run `ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub` there and type the last
6 characters of the `SHA256:` value instead.
