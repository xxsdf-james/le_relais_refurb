# Test fixtures — raw hardware output

These are raw, unmodified command outputs captured from real machines, used to test
`diagnostics.sh`'s parsing logic without ever running it for real. This is what the
CLAUDE.md rule "Don't run `sudo`. Test parsing logic against `tests/fixtures/` instead."
refers to — nothing in this directory is synthetic or hand-edited.

Machine numbers match the numbering already used in `known-issues.md` /
`methodology.md` (machine 001 is the documented Clear-tier-fallback NVMe case,
Samsung MZVLW256HEHP-000L7 / CIAD7562).

## Layout

```
tests/fixtures/
  001-nvme/
    lsblk.json              lsblk -J
    lsblk-summary.txt       lsblk -dno NAME,TYPE,TRAN,RM,ROTA
    dmidecode-system.txt    sudo dmidecode -t system
    dmidecode-memory.txt    sudo dmidecode -t memory
    nvme-id-ctrl.txt        sudo nvme id-ctrl <device>     (NVMe only)
    smartctl-i.txt          sudo smartctl -i <device>
    device.txt              the exact device path used, e.g. /dev/nvme0n1
  002-sata-ssd/
    lsblk.json
    lsblk-summary.txt
    dmidecode-system.txt
    dmidecode-memory.txt
    smartctl-i.txt          (no nvme-id-ctrl.txt — not applicable to SATA)
    device.txt
```

One file per command, named after the command, holding its output verbatim. Add a
`00X-<drive-type>/` directory the same way for any future machine that needs its own
fixture set (e.g. an HDD case).

## Capture checklist (run once per machine, from the Ubuntu Live session)

1. **Identify the primary drive first** — several commands below need its device path:
   ```
   lsblk -dno NAME,TYPE,TRAN,RM,ROTA
   ```
   The internal drive is the line with `TYPE=disk`, `TRAN` not `usb`, `RM=0`. Call its
   path `$DEV` (e.g. `/dev/nvme0n1` or `/dev/sda`).

2. **Capture each command to its own file, unmodified:**
   ```
   lsblk -J                          > lsblk.json
   lsblk -dno NAME,TYPE,TRAN,RM,ROTA > lsblk-summary.txt
   sudo dmidecode -t system          > dmidecode-system.txt
   sudo dmidecode -t memory          > dmidecode-memory.txt
   sudo nvme id-ctrl "$DEV"          > nvme-id-ctrl.txt   # NVMe only
   sudo smartctl -i "$DEV"           > smartctl-i.txt
   echo "$DEV"                       > device.txt
   ```
   Use `sudo <cmd> | tee <file>` instead of `>` if you want to see it on screen too.

3. **Skim before the files leave the machine.** Hardware identity/health data (serials,
   CIAD numbers) is fine — already used elsewhere in the docs. Check for anything that
   isn't: BIOS/UEFI passwords surfacing in a dmidecode string, stray Wi-Fi credentials,
   anything Le Relais-internal beyond the asset itself.

4. **Get the files into `tests/fixtures/00X-<drive-type>/` in the repo.** As of
   2026-09-28, `scripts/linux/enable-ssh.sh` + `docs/ssh-access.md` gives a
   CONFIRMED-working path: `scp -O` the capture off the target straight to the
   laptop (note the `-O` — see the known issue in `docs/ssh-access.md`). A spare
   USB stick or manual copy-paste both still work too, if SSH isn't set up on a
   given machine.

5. **Before committing:** run `git status` / `git diff --staged` and check against step 3
   above one more time, per the repo's secrets rule (CLAUDE.md, Safety rules).

## Known dependency

Getting captures off a target machine used to share the same open blocker as routine
`diagnostics.sh` results ("where diagnostic results go without the Toolbox USB").
`docs/ssh-access.md` now gives a working answer for ad hoc/troubleshooting use
(CONFIRMED 2026-09-28, used for the 002-sata-ssd fixtures) — whether that becomes the
standard answer for routine `diagnostics.sh` runs across all ~100 machines, versus
just the bench-troubleshooting case it was built for, is still Hamish's call, not
decided here.
