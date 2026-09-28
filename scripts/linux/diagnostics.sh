#!/bin/bash
# Diagnostics script — Le Relais PC Refurbishment
#
# Fetched via raw.githubusercontent.com and run under Ubuntu Live (see
# CLAUDE.md, "Delivery to target machines" — the Toolbox USB this comment
# used to describe is retired, see CLAUDE.md "Out of scope / superseded").
# Assesses hardware condition and drive type. Does NOT wipe a disk, install
# anything, or verify Windows activation — those stay outside this script's
# scope (see comments below for why).
#
# v0.7 changes (Windows-only batch — 36 machines, IT dept priority,
# 2026-09-28, paired with erase-partition.sh v8):
#   - Header comment and the end-of-run reminder updated for the retired
#     Toolbox USB; end-of-run reminder now points at the SSH-based pull
#     (docs/ssh-access.md) instead.
#   - Dropped the Linux/GRUB half of the boot-entry check and the "Hardware
#     Suitability Specs (for manual dual-boot/Windows-only/Mint-only
#     decision)" recap block: for this batch that decision is already fixed
#     (Windows-only), and the underlying specs (RAM, storage, UEFI) are
#     already logged individually elsewhere in this script. Not a permanent
#     removal — if the dual-boot/Mint phase resumes later (CLAUDE.md,
#     "comes later"), pull this logic back from git history rather than
#     re-deriving it.
#   - RESULTS_DIR fixed from "$SCRIPT_DIR/../results" to "$SCRIPT_DIR/results":
#     the old path assumed the Toolbox USB layout (scripts/diagnostics.sh
#     next to a sibling results/ dir). Under the current flat wget-fetch
#     delivery model (CLAUDE.md) there's no scripts/ parent, so "../results"
#     resolved to whatever's above the current directory — wrong, and maybe
#     unwritable. Not yet exercised on a real fetch-and-run (see the open
#     "fetch test on a real target machine" item) — found by inspection,
#     not a live failure.
#
# v0.6 changes from v0.5 (summary.csv redesign — one row per machine):
#   - summary.csv is now keyed on machine_serial (chassis serial) with
#     exactly ONE ROW PER MACHINE, not one row per stage. This script now
#     upserts: it looks for an existing row whose machine_serial matches
#     this machine's chassis serial and updates it in place; if none
#     exists, it inserts a new row.
#   - Fixes a real ambiguity in the old schema: "serial_number" held the
#     chassis serial on stage=before rows but the DRIVE serial on
#     stage=erase rows written by erase-partition.sh — same column,
#     different meaning depending which script wrote it. The new
#     machine_serial column always means chassis serial; drive_serial
#     always means the drive's own serial. Found while reviewing
#     CIAD7562/CIAD7483's rows side by side — see chat for the full
#     writeup.
#   - New pared-down 12-column schema:
#       machine_serial, ciad_number, ram_gb, storage_type,
#       storage_capacity_gb, drive_serial, smart_status, erase_method,
#       erase_result, os_installed, status, date
#     This script only owns and writes: machine_serial, ciad_number,
#     ram_gb, storage_type, storage_capacity_gb, drive_serial,
#     smart_status, date. On update, it leaves erase_method, erase_result
#     and os_installed exactly as they were — those columns belong to
#     erase-partition.sh (and, later, an install-verification script) and
#     this script has no business touching them.
#   - status is only ever set to "before" when INSERTING a brand-new row.
#     If the row already exists with a status further along (e.g.
#     "erased"), a re-run of this script (e.g. the legacy re-diagnosis
#     case from known-issues.md) does not downgrade it back to "before".
#   - Dropped from the CSV entirely (still in this machine's own .txt log,
#     just no longer summarized): cpu_model, and the old per-stage
#     date_processed/stage columns (replaced by a single date column that
#     reflects whichever stage last touched the row).
#   - STAGE=after is still recorded in the .txt report as before, but does
#     NOT yet get its own place in summary.csv — closing diagnostics gets
#     dedicated columns only once that stage is actually built (deferred,
#     not forgotten).
#
# v0.5 changes from v0.4 (bugfix):
#   - Also detects and records the DRIVE'S OWN serial number (via
#     `nvme id-ctrl` / `smartctl -i`), in a new `drive_serial` column —
#     separate from `serial_number`, which remains the machine's chassis
#     serial (dmidecode -t system). These are two different numbers.
#     erase-partition.sh's pre-sanitize cross-check matches against the
#     DRIVE's serial, but until this version, only the machine's chassis
#     serial was ever recorded — so that cross-check was comparing a drive
#     serial against a machine serial and could only ever match by
#     coincidence. This is why erase-partition.sh reported no matching
#     "before" row on 001/CIAD7562 even though one existed.
#   - summary.csv schema extends to 16 columns: drive_serial appended at
#     the end. Existing 15 columns/order unchanged.
#   - IMPORTANT — this does not retroactively fix old rows: any machine
#     whose "before" diagnostic was run under v0.3 or v0.4 has no
#     drive_serial recorded, and erase-partition.sh (updated alongside
#     this) will refuse to proceed on it with a message telling you to
#     re-run this "before" stage under this version first. See
#     known-issues.md for the full writeup and batch-wide impact.
#   - Windows-activation reminder (below) no longer points at
#     hardware-inventory.csv — that file is no longer part of this
#     project's active toolkit; summary.csv is the working record now.
#     See methodology.md §9.
#
# v0.4 changes from v0.3:
#   - Report filename now includes the CIAD number:
#       diag_${MACHINE_ID}_${CIAD_NUMBER}_${STAGE}.txt
#     e.g. diag_001_CIAD7562_before.txt — matches erase-partition.sh's
#     naming convention so a filename can be matched directly to the
#     physical asset sticker.
#   - summary.csv header extended to the same schema erase-partition.sh
#     writes to (erase_method, erase_start, erase_end, erase_exit_status,
#     verify_method, verify_result appended). Diagnostic rows
#     (stage=before/after) leave those six columns blank; only
#     stage=erase rows populate them.
#
# Usage: ./diagnostics.sh (results/ is created next to wherever this file lands)
 
set -uo pipefail
# Deliberately no -e: a single missing tool or offline apt call must not abort
# the whole diagnostic run — we want partial results, not a hard stop.
 
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULTS_DIR="$SCRIPT_DIR/results"
mkdir -p "$RESULTS_DIR"
 
read -rp "Machine ID/label: " MACHINE_ID
read -rp "CIAD number (manual entry, traceability to legacy tracking): " CIAD_NUMBER
read -rp "Stage (before/after): " STAGE
 
OUT="$RESULTS_DIR/diag_${MACHINE_ID}_${CIAD_NUMBER}_${STAGE}.txt"
SUMMARY_CSV="$RESULTS_DIR/summary.csv"
 
log() { echo -e "$1" | tee -a "$OUT"; }
 
echo "Diagnostics for ${MACHINE_ID} (CIAD ${CIAD_NUMBER}, ${STAGE})" > "$OUT"
date >> "$OUT"
 
have() { command -v "$1" >/dev/null 2>&1; }
 
# --- Tooling -----------------------------------------------------------------
# Ubuntu Live doesn't ship all of these by default. Installing needs network;
# if the session is offline, whatever's already on the ISO is used and gaps
# are reported rather than aborting the run. If offline diagnostics become a
# recurring need, bundle these as .deb files on a USB stick instead of
# relying on apt here.
REQUIRED_TOOLS=(
  nvme:nvme-cli
  smartctl:smartmontools
  dmidecode:dmidecode
  lspci:pciutils
  lsusb:usbutils
  hdparm:hdparm
  efibootmgr:efibootmgr
  mokutil:mokutil
  lshw:lshw
)
MISSING_PKGS=()
for entry in "${REQUIRED_TOOLS[@]}"; do
  bin="${entry%%:*}"; pkg="${entry##*:}"
  have "$bin" || MISSING_PKGS+=("$pkg")
done
 
if [ "${#MISSING_PKGS[@]}" -gt 0 ]; then
  echo "Installing missing tools: ${MISSING_PKGS[*]} (needs network)..."
  if sudo apt update -qq 2>/dev/null && sudo apt install -y "${MISSING_PKGS[@]}" >/dev/null 2>&1; then
    echo "Tools installed."
  else
    log "WARNING: could not install [${MISSING_PKGS[*]}] — no network or apt failed."
    log "Related checks below may be skipped or incomplete."
  fi
fi
 
# --- Machine identity ----------------------------------------------------------
# This is the CHASSIS/MOTHERBOARD serial (dmidecode) — source of truth for
# the machine identifier per methodology.md §3. It is a DIFFERENT number
# from the drive's own serial (detected below, in Storage Detection). A
# drive can be swapped between chassis without the chassis serial changing,
# so the two numbers answer different questions and neither substitutes
# for the other.
SERIAL="unknown"
if have dmidecode; then
  SERIAL=$(sudo dmidecode -t system 2>/dev/null | awk -F': ' '/Serial Number/{print $2; exit}')
  [ -z "$SERIAL" ] && SERIAL="unknown"
fi
 
log "\n=== Machine Identity ==="
log "Machine label  : $MACHINE_ID"
log "Serial number  : $SERIAL   (machine/chassis serial — dmidecode -t system, methodology.md §3. NOT the drive serial below.)"
log "CIAD number    : $CIAD_NUMBER   (manual entry, legacy-system traceability)"
 
CPU_MODEL="unknown"
have lscpu && CPU_MODEL=$(lscpu | awk -F': *' '/Model name/{print $2; exit}')
 
# --- RAM -----------------------------------------------------------------------
log "\n=== RAM ==="
MEM_DUMP=""
if have dmidecode; then
  MEM_DUMP=$(sudo dmidecode -t memory 2>&1)
  echo "$MEM_DUMP" | tee -a "$OUT"
fi
 
# Installed RAM (module capacity, from dmidecode) rather than OS-usable
# memory (from free). 'free' subtracts whatever firmware/hardware has
# permanently reserved (shared GPU memory, MMIO regions, etc.), so an 8 GB
# machine routinely shows ~7.7 GB usable — and `free -g` truncates rather
# than rounds that figure, so it reports 7. Installed capacity is the more
# useful, stable number for the hardware record.
RAM_GB="unknown"
if [ -n "$MEM_DUMP" ]; then
  RAM_GB=$(echo "$MEM_DUMP" | awk '
    /^[[:space:]]*Size:/ {
      if ($2 ~ /^[0-9]+$/) {
        if ($3 == "GB") total += $2
        else if ($3 == "MB") total += $2/1024
      }
    }
    END { if (total > 0) printf "%d", total+0.5; else print "unknown" }
  ')
  [ -z "$RAM_GB" ] && RAM_GB="unknown"
fi
 
log "\n--- Usable memory (OS-visible) ---"
have free && free -h 2>&1 | tee -a "$OUT"
log "Installed RAM (dmidecode module sizes): ${RAM_GB} GB"
 
# --- CPU -------------------------------------------------------------------
log "\n=== CPU ==="
have lscpu && lscpu 2>&1 | tee -a "$OUT"
 
# --- Storage: detect the primary drive, classify it, collect health data -----
# Assumption: one primary internal storage device per machine (see
# methodology.md — the workflow doesn't handle multi-disk machines). USB
# boot media is excluded from candidacy.
log "\n=== Storage Detection ==="
 
PRIMARY_DEV=""
STORAGE_TYPE="unknown"
STORAGE_CAPACITY_GB="unknown"
SMART_STATUS="unknown"
 
NVME_DEV=$(ls /dev/nvme?n1 2>/dev/null | head -n1)
if [ -n "$NVME_DEV" ]; then
  PRIMARY_DEV="$NVME_DEV"
  STORAGE_TYPE="NVMe"
elif have lsblk; then
  CANDIDATE=$(lsblk -dno NAME,TYPE,TRAN,RM 2>/dev/null | awk '$2=="disk" && $3!="usb" && $4==0 {print $1; exit}')
  if [ -n "$CANDIDATE" ]; then
    PRIMARY_DEV="/dev/$CANDIDATE"
    ROTA=$(lsblk -dno ROTA "$PRIMARY_DEV" 2>/dev/null | tr -d '[:space:]')
    if [ "$ROTA" = "1" ]; then
      STORAGE_TYPE="SATA HDD (rotational)"
    else
      STORAGE_TYPE="SATA SSD (non-rotational)"
    fi
  fi
fi
 
# --- Drive's own identity (separate from the machine identity above) --------
# This is the number erase-partition.sh's pre-sanitize cross-check matches
# against — it proves the physical drive under the screwdriver is the one
# this diagnostic actually ran on. Detection mirrors erase-partition.sh's
# own detection exactly (same tools, same fields), since the two values
# only mean anything if they're read the same way.
DRIVE_SERIAL="unknown"
DRIVE_MODEL="unknown"
if [ -n "$PRIMARY_DEV" ]; then
  if [ "$STORAGE_TYPE" = "NVMe" ] && have nvme; then
    ID_CTRL=$(sudo nvme id-ctrl "$PRIMARY_DEV" 2>/dev/null)
    DRIVE_SERIAL=$(echo "$ID_CTRL" | awk -F': *' '/^sn[[:space:]]*:/{print $2; exit}' | tr -d '[:space:]')
    DRIVE_MODEL=$(echo "$ID_CTRL" | awk -F': *' '/^mn[[:space:]]*:/{print $2; exit}')
  elif have smartctl; then
    SM_I=$(sudo smartctl -i "$PRIMARY_DEV" 2>/dev/null)
    DRIVE_SERIAL=$(echo "$SM_I" | awk -F': *' '/Serial Number/{print $2; exit}' | tr -d '[:space:]')
    DRIVE_MODEL=$(echo "$SM_I" | awk -F': *' '/Device Model|Model Number/{print $2; exit}')
  fi
fi
[ -z "$DRIVE_SERIAL" ] && DRIVE_SERIAL="unknown"
[ -z "$DRIVE_MODEL" ] && DRIVE_MODEL="unknown"
 
if [ -z "$PRIMARY_DEV" ]; then
  log "Could not identify a primary storage device automatically — check manually with 'lsblk -f'."
else
  log "Primary device : $PRIMARY_DEV"
  log "Detected type  : $STORAGE_TYPE"
  log "Drive model    : $DRIVE_MODEL"
  log "Drive serial   : $DRIVE_SERIAL   (drive's OWN reported serial — nvme id-ctrl/smartctl -i. erase-partition.sh matches against THIS, not the machine serial above.)"
 
  if have lsblk; then
    CAP_BYTES=$(lsblk -bdno SIZE "$PRIMARY_DEV" 2>/dev/null)
    [ -n "$CAP_BYTES" ] && STORAGE_CAPACITY_GB=$(( CAP_BYTES / 1000 / 1000 / 1000 ))
  fi
  log "Capacity       : ${STORAGE_CAPACITY_GB} GB"
 
  if [ "$DRIVE_SERIAL" = "unknown" ]; then
    log "WARNING: could not read the drive's own serial number. erase-partition.sh"
    log "will not be able to cross-check this 'before' row later — investigate"
    log "why (missing nvme-cli/smartmontools? unsupported drive?) before relying"
    log "on this diagnostic to satisfy that check."
  fi
 
  log "\n--- Health data ---"
  case "$STORAGE_TYPE" in
    NVMe)
      have nvme && sudo nvme list 2>&1 | tee -a "$OUT"
      if have nvme; then
        log "\n-- nvme smart-log --"
        sudo nvme smart-log "$PRIMARY_DEV" 2>&1 | tee -a "$OUT"
      fi
      if have smartctl; then
        log "\n-- smartctl -a --"
        sudo smartctl -a "$PRIMARY_DEV" 2>&1 | tee -a "$OUT"
      fi
      ;;
    *)
      have smartctl && sudo smartctl -a "$PRIMARY_DEV" 2>&1 | tee -a "$OUT"
      ;;
  esac
 
  if have smartctl; then
    SMART_STATUS=$(sudo smartctl -H "$PRIMARY_DEV" 2>/dev/null | awk -F': ' '/overall-health/{print $2}')
    [ -z "$SMART_STATUS" ] && SMART_STATUS="see full log"
  fi
 
  # --- Sanitization method: RECOMMENDED ONLY — never executed here ---------
  log "\n=== Recommended Sanitization Method (NOT executed by this script) ==="
  case "$STORAGE_TYPE" in
    NVMe)
      if have nvme; then
        SANICAP=$(sudo nvme id-ctrl "$PRIMARY_DEV" 2>/dev/null | grep -i sanicap)
        log "$SANICAP"
      fi
      log "Per methodology.md §4 — use crypto erase if supported:"
      log "  sudo nvme format $PRIMARY_DEV --ses=2"
      log "Fallback if crypto erase unsupported (user-data erase):"
      log "  sudo nvme format $PRIMARY_DEV --ses=1"
      log "If both --ses=2/1 (and --ses=0) are rejected with 'Invalid Command"
      log "Opcode' regardless of value, this may be the confirmed"
      log "unsupported-firmware pattern in known-issues.md — erase-partition.sh"
      log "detects this automatically and falls back to a documented Clear-tier"
      log "overwrite (methodology.md §4.1); no separate action needed here."
      ;;
    "SATA SSD (non-rotational)")
      log "NOTE: methodology.md §4 only names the NVMe case explicitly. A SATA"
      log "SSD has the same wear-leveling issue — overwrite is not reliable"
      log "Purge-equivalent sanitization — so the same crypto/purge-class method"
      log "applies, via ATA Secure Erase rather than nvme format:"
      log "  sudo hdparm --user-master u --security-set-pass p1 $PRIMARY_DEV"
      log "  sudo hdparm --user-master u --security-erase p1 $PRIMARY_DEV"
      log "This SATA-SSD extension isn't in methodology.md yet — confirm it"
      log "before relying on it across the batch, and add it there once agreed."
      ;;
    "SATA HDD (rotational)")
      log "Per methodology.md §4 — crypto erase doesn't apply (no controller-"
      log "level encryption to discard a key for). Use a full-disk overwrite,"
      log "run separately (e.g. nwipe):"
      log "  sudo nwipe $PRIMARY_DEV"
      ;;
    *)
      log "Drive type not determined — resolve manually before choosing a method."
      ;;
  esac
fi
 
# --- UEFI / boot mode ----------------------------------------------------------
log "\n=== UEFI / Boot Mode ==="
if [ -d /sys/firmware/efi ]; then
  UEFI_CAPABLE="yes (this Live session booted via UEFI)"
else
  UEFI_CAPABLE="no (this Live session booted via legacy BIOS/CSM)"
fi
log "UEFI capable   : $UEFI_CAPABLE"
 
log "\n=== Hardware Summary ==="
have lshw && sudo lshw -short 2>&1 | tee -a "$OUT"
 
log "\n=== PCIe Devices + Drivers ==="
have lspci && lspci -k 2>&1 | tee -a "$OUT"
 
log "\n=== USB Devices ==="
have lsusb && lsusb 2>&1 | tee -a "$OUT"
 
# --- UEFI boot entries / Secure Boot --------------------------------------
log "\n=== UEFI Boot Entries ==="
BOOTMGR_OUT=""
if have efibootmgr; then
  BOOTMGR_OUT=$(sudo efibootmgr -v 2>&1)
  echo "$BOOTMGR_OUT" | tee -a "$OUT"
fi
 
log "\n=== Secure Boot State ==="
have mokutil && mokutil --sb-state 2>&1 | tee -a "$OUT"
 
# --- Windows Boot Manager presence check (most useful on 'after' runs) -------
# v0.7: dropped the Linux/GRUB half of this check for the Windows-only batch
# (see v0.7 changelog above) — no dual-boot in play for these machines.
log "\n=== Windows Boot Manager Check ==="
if [ -n "$BOOTMGR_OUT" ]; then
  if echo "$BOOTMGR_OUT" | grep -qi "windows boot manager"; then
    log "Windows Boot Manager entry : FOUND"
  else
    log "Windows Boot Manager entry : NOT FOUND"
  fi
else
  log "efibootmgr unavailable — could not check boot entries."
fi

# v0.7: dropped the "Hardware Suitability Specs" recap block that supported a
# manual per-machine dual-boot/Windows-only/Mint-only decision — see v0.7
# changelog above. RAM/storage/UEFI are already logged individually above.
 
# --- Windows activation reminder (out of scope for this script) -------------
if [ "$STAGE" = "after" ]; then
  log "\n=== Reminder ==="
  log "Windows activation status CANNOT be checked from Ubuntu Live — it only"
  log "exists inside a booted Windows session. Verify manually (Settings >"
  log "System > Activation) and record the result yourself — summary.csv has"
  log "no dedicated column for it yet, so note it against this machine's"
  log "CIAD number in whatever tracking you're keeping outside this script."
fi
 
# --- Machine-readable summary — upsert one row per machine -------------------
# summary.csv is now ONE ROW PER MACHINE, keyed on machine_serial (chassis
# serial — the source of truth per methodology.md §3), not one row per
# stage. This script only owns and writes: machine_serial, ciad_number,
# ram_gb, storage_type, storage_capacity_gb, drive_serial, smart_status,
# date. It sets status="before" only when inserting a brand-new row — an
# existing row's status (e.g. "erased", written by erase-partition.sh) is
# never downgraded by a re-run of this script, which matters for the
# legacy-row re-diagnosis case in known-issues.md. Columns owned by other
# scripts (erase_method, erase_result, os_installed) are carried over
# untouched on update, left blank on insert.
#
# NOTE: STAGE=after is still recorded in this machine's own .txt report as
# always, but doesn't yet update anything in summary.csv beyond the columns
# above — closing diagnostics gets its own dedicated columns once that
# stage is actually built (deferred per the 2026-09-23 CSV redesign).
log "\n=== Recording result ==="
 
EXPECTED_HEADER="machine_serial,ciad_number,ram_gb,storage_type,storage_capacity_gb,drive_serial,smart_status,erase_method,erase_result,os_installed,status,date"
 
if [ ! -f "$SUMMARY_CSV" ]; then
  echo "$EXPECTED_HEADER" > "$SUMMARY_CSV"
fi
 
CURRENT_HEADER=$(head -n1 "$SUMMARY_CSV")
if [ "$CURRENT_HEADER" != "$EXPECTED_HEADER" ]; then
  log "WARNING: summary.csv's header doesn't match the current one-row-per-machine"
  log "schema (machine_serial-keyed, 12 columns). This usually means the file"
  log "still has rows in the old one-row-per-stage format and needs migrating by"
  log "hand — proceeding anyway rather than aborting a diagnostic run, but don't"
  log "trust this upsert to have found the right row until that's done."
fi
 
TMP_CSV=$(mktemp)
MATCHED=0
{
  IFS= read -r hdr_line
  echo "$hdr_line"
  while IFS= read -r row; do
    ROW_SERIAL=$(echo "$row" | awk -F',' '{print $1}' | tr -d '"')
    if [ "$ROW_SERIAL" = "$SERIAL" ]; then
      MATCHED=1
      # Carry columns 8-10 (erase_method, erase_result, os_installed)
      # forward untouched — this script has no business setting them.
      OLD_ERASE_METHOD=$(echo "$row" | awk -F',' '{print $8}')
      OLD_ERASE_RESULT=$(echo "$row" | awk -F',' '{print $9}')
      OLD_OS_INSTALLED=$(echo "$row" | awk -F',' '{print $10}')
      OLD_STATUS=$(echo "$row" | awk -F',' '{print $11}')
      NEW_STATUS="$OLD_STATUS"
      STATUS_BARE=$(echo "$OLD_STATUS" | tr -d '"')
      # Only ever set to "before" if nothing further has been recorded yet —
      # never downgrade progress an erase/partition run already made.
      [ -z "$STATUS_BARE" ] && NEW_STATUS="\"before\""
      echo "\"$SERIAL\",\"$CIAD_NUMBER\",\"$RAM_GB\",\"$STORAGE_TYPE\",\"$STORAGE_CAPACITY_GB\",\"$DRIVE_SERIAL\",\"$SMART_STATUS\",$OLD_ERASE_METHOD,$OLD_ERASE_RESULT,$OLD_OS_INSTALLED,$NEW_STATUS,\"$(date -I)\""
    else
      echo "$row"
    fi
  done
} < "$SUMMARY_CSV" > "$TMP_CSV"
 
if [ "$MATCHED" -eq 0 ]; then
  echo "\"$SERIAL\",\"$CIAD_NUMBER\",\"$RAM_GB\",\"$STORAGE_TYPE\",\"$STORAGE_CAPACITY_GB\",\"$DRIVE_SERIAL\",\"$SMART_STATUS\",\"\",\"\",\"\",\"before\",\"$(date -I)\"" >> "$TMP_CSV"
  log "New machine — inserted row for $SERIAL (CIAD $CIAD_NUMBER)."
else
  log "Existing machine — updated row for $SERIAL (CIAD $CIAD_NUMBER) in place."
fi
 
mv "$TMP_CSV" "$SUMMARY_CSV"

# --- Repair ownership if this was (mistakenly) run under sudo ---------------
# Root is only needed for the individual commands above (nvme, dmidecode,
# ...) — see "Usage: ./diagnostics.sh" at the top — not the script as a
# whole. If it WAS invoked via sudo anyway, every file under $RESULTS_DIR
# ends up root-owned, which blocks the scp/sftp pull later (SFTP runs as the
# authenticated live-session user, not root, and can't open a root-owned
# file). Same SUDO_USER-based fix enable-ssh.sh already uses.
if [ "$(id -u)" -eq 0 ] && [ -n "${SUDO_USER:-}" ]; then
  chown -R "$SUDO_USER:$SUDO_USER" "$RESULTS_DIR"
fi

echo ""
echo "Done."
echo "Full log       : $OUT"
echo "Summary row in : $SUMMARY_CSV"
echo "This live session is not permanent storage — pull these off via SSH once"
echo "enable-ssh.sh has been run on this machine (see docs/ssh-access.md), e.g."
echo "from the laptop:"
echo "  scp -i ~/.ssh/id_ed25519_refurb <user>@<this-machine-ip>:$OUT ."
echo "  scp -i ~/.ssh/id_ed25519_refurb <user>@<this-machine-ip>:$SUMMARY_CSV ."
