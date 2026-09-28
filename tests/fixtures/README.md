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

4. **Get the files into `tests/fixtures/00X-<drive-type>/` in the repo.** There's no
   defined path for this yet — it's the same open item as "where diagnostic results go
   without the Toolbox USB" (see handoff, Open items). For a one-off capture on two
   machines, a spare USB stick or manually copying terminal output into files on the
   Bluefin laptop both work; this doesn't need to wait on that decision being finalized.

5. **Before committing:** run `git status` / `git diff --staged` and check against step 3
   above one more time, per the repo's secrets rule (CLAUDE.md, Safety rules).

## Known dependency

Getting captures off a target machine shares the same open blocker as routine
`diagnostics.sh` results ("where diagnostic results go without the Toolbox USB"). That
question needs an answer before `diagnostics.sh` can be rewritten to not assume the
Toolbox USB — but it doesn't block this one-off fixture capture on two machines.
