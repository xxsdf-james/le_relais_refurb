# Toolkit Reference — Le Relais PC Refurbishment

*Living document — describes the current working setup. Update this whenever the toolkit itself changes, so a new conversation can execute the workflow without re-deriving it.*

## Physical media: four USB drives, one job each

Each drive has exactly one purpose. Don't combine roles — see `known-issues.md` and the earlier methodology discussion for why (a boot drive being read from live-locks it; a working-data drive needs to never be a boot dependency).

| USB | Contents | Purpose |
|---|---|---|
| **Windows 11 USB** | Windows 11 multi-edition ISO, written via Rufus | Boots and installs Windows 11. Multi-edition ISO auto-matches the firmware-embedded OEM edition (see known-issues). |
| **Ubuntu USB** | Ubuntu Desktop ISO, written via Rufus | Boots Ubuntu Live — used for opening/closing diagnostics, disk wiping, and any manual repair work. |
| **Mint USB** | Linux Mint ISO, written via Rufus | Boots and installs Linux Mint, where a machine's triage outcome calls for it. |
| **Toolbox USB** | Plain FAT32, `diagnostics.sh` + results folder | Not bootable. Holds the diagnostics script and receives its output. Plugged in alongside whichever boot USB is in use. |

## Building each Rufus USB

1. Download the correct ISO (see below for sources).
2. Open Rufus, select the target USB, select the ISO.
3. Partition scheme: **GPT**, target: **UEFI (non-CSM)**.
4. For the Windows 11 USB specifically: use Rufus's extended Windows 11 install options to bypass the online-Microsoft-account requirement — but see `known-issues.md` regarding the blank-password local admin account this creates, and set a real password immediately after every install.
5. Rufus's "UEFI:NTFS" / media-validation option is **deliberately left off**. Integrity is instead checked periodically by hashing a key file on each USB and re-verifying every 15-20 installs:
   - Windows: `certutil -hashfile E:\sources\install.wim SHA256`
   - Mint: `certutil -hashfile E:\casper\filesystem.squashfs SHA256`
   Record the known-good hash the first time, then re-run periodically and compare — a mismatch means re-create the USB from scratch rather than trying to repair it.

## ISO sources

- **Ubuntu Desktop**: `ubuntu.com/download/desktop` — direct download, current LTS. Verify with `sha256sum` against the SHA256SUMS file linked on the same page before use.
- **Windows 11**: `microsoft.com/software-download/windows11` — official page only, multi-edition ISO, French language selected. No official checksum provided by Microsoft; sourcing from this exact URL is the safeguard.
- **Linux Mint**: 22.3 Cinnamon (primary edition), with a fallback to the Xfce edition for machines where Cinnamon isn't suitable — fallback criteria not yet defined.

## Toolbox USB setup (one-time)

1. Format a spare USB as plain FAT32, label it `TOOLBOX`.
2. Create folder structure:
   ```
   TOOLBOX/
     scripts/
       diagnostics.sh
     results/
   ```
3. Write `diagnostics.sh` into `scripts/` (current version is a TODO — see below; the version used during initial Ventoy-based testing is outdated and needs rework for the current three-USB workflow, drive-type detection, and dual-boot triage per `methodology.md` §4–5).

## Per-machine workflow (current)

```
1. Boot Ubuntu USB → Ubuntu Live
2. Plug in Toolbox USB (separate port from the boot USB)
3. cd to TOOLBOX/scripts, run ./diagnostics.sh → opening diagnostics
   (machine label + "before", saves to ../results/)
4. Wipe disk — method depends on drive type (see methodology.md §4)
5. Partition per triage outcome (dual-boot / Windows-only / Mint-only)
6. Boot Windows 11 USB → install
   - Windows Update
   - Install Firefox, Thunderbird, VLC, LibreOffice
   - Verify drivers, verify install, confirm activation
7. If dual-boot or Mint-only: boot Mint USB → install
   - Updates
   - Verify Firefox/Thunderbird/VLC/LibreOffice presence/version
8. Boot Ubuntu USB again → Ubuntu Live
9. Plug in Toolbox USB again, run ./diagnostics.sh → closing diagnostics
   (same machine label + "after")
   - Confirm wipe verification, both installs, bootloader (if dual-boot)
10. Copy that machine's before/after result files off the Toolbox USB
    periodically (it's not permanent storage)
```

## Known gotcha specific to this sequence

If Windows 11 was installed in step 6 and you need to boot the Mint USB in step 7, the boot-menu hotkey may no longer respond due to Windows 11's Fast Startup (see `known-issues.md`). Use **Settings → System → Recovery → Advanced startup → Restart now → Use a device** rather than troubleshooting the hotkey.

## Open items / TODO

- `diagnostics.sh` itself needs a full rewrite for the current workflow — drive-type detection (NVMe vs HDD) to select sanitization method, dual-boot suitability evaluation, Windows activation check, bootloader verification, and machine-identity fields (serial number + CIAD number). Tracked as a standalone task, not yet started.
- Criteria for falling back from Mint Cinnamon to Mint Xfce not yet defined (likely tied to the same hardware triage thresholds as the dual-boot decision — see methodology.md §5).
- Confirm whether Rufus's default local account naming behavior needs a standard username set explicitly per install, rather than relying on whatever default it falls back to.
