#!/bin/bash
# Diagnostics script — Le Relais PC Refurbishment
#
# Runs from the TOOLBOX USB (TOOLBOX/scripts/diagnostics.sh) under Ubuntu Live.
# Assesses hardware condition, drive type, and dual-boot suitability. Does NOT
# wipe a disk, install anything, or verify Windows activation — those stay
# outside this script's scope (see comments below for why).
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
# Usage (from TOOLBOX/scripts/): ./diagnostics.sh
 
set -uo pipefail
# Deliberately no -e: a single missing tool or offline apt call must not abort
# the whole diagnostic run — we want partial results, not a hard stop.
 
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULTS_DIR="$SCRIPT_DIR/../results"
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
# recurring need, bundle these as .deb files on the Toolbox USB instead of
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
 
# --- Dual-boot presence check (most useful on 'after' runs) ------------------
log "\n=== Bootloader / Dual-Boot Presence Check ==="
if [ -n "$BOOTMGR_OUT" ]; then
  if echo "$BOOTMGR_OUT" | grep -qi "windows boot manager"; then
    log "Windows Boot Manager entry : FOUND"
  else
    log "Windows Boot Manager entry : NOT FOUND"
  fi
  if echo "$BOOTMGR_OUT" | grep -Eqi "ubuntu|mint|grub|opensuse|fedora"; then
    log "Linux/GRUB boot entry      : FOUND"
  else
    log "Linux/GRUB boot entry      : NOT FOUND"
  fi
else
  log "efibootmgr unavailable — could not check boot entries."
fi
 
# --- Hardware suitability specs (reported only — no thresholds applied) ------
log "\n=== Hardware Suitability Specs (for manual dual-boot/Windows-only/Mint-only decision) ==="
log "RAM (GB)             : $RAM_GB"
log "Storage type         : $STORAGE_TYPE"
log "Storage capacity (GB): $STORAGE_CAPACITY_GB"
log "UEFI capable         : $UEFI_CAPABLE"
log "NOTE: no thresholds are applied here — methodology.md §5 leaves the"
log "dual-boot vs Windows-only vs Mint-only decision undefined. Decide"
log "manually from the specs above until thresholds are agreed."
 
# --- Windows activation reminder (out of scope for this script) -------------
if [ "$STAGE" = "after" ]; then
  log "\n=== Reminder ==="
  log "Windows activation status CANNOT be checked from Ubuntu Live — it only"
  log "exists inside a booted Windows session. Verify manually (Settings >"
  log "System > Activation) and record the result yourself — summary.csv has"
  log "no dedicated column for it yet, so note it against this machine's"
  log "CIAD number in whatever tracking you're keeping outside this script."
fi
 
# --- Machine-readable summary row ---------------------------------------------
# Schema shared with erase-partition.sh (stage=erase rows). Diagnostic rows
# (stage=before/after) leave erase_method..verify_result blank; only
# erase-partition.sh populates them. drive_serial (added in v0.5) is
# populated by both scripts and is the field erase-partition.sh's
# pre-sanitize cross-check matches on — NOT serial_number, which stays the
# machine/chassis serial on rows written by this script.
EXPECTED_HEADER="serial_number,ciad_number,date_processed,stage,cpu_model,ram_gb,storage_type,storage_capacity_gb,smart_status,erase_method,erase_start,erase_end,erase_exit_status,verify_method,verify_result,drive_serial"
 
if [ ! -f "$SUMMARY_CSV" ]; then
  echo "$EXPECTED_HEADER" > "$SUMMARY_CSV"
else
  CURRENT_HEADER=$(head -n1 "$SUMMARY_CSV")
  if ! echo "$CURRENT_HEADER" | grep -q "drive_serial"; then
    log "WARNING: summary.csv still has the pre-v0.5 15-column header (no"
    log "drive_serial). Appending this row in the 16-column format anyway —"
    log "existing rows won't have drive_serial until their machines are"
    log "re-diagnosed under this version. See known-issues.md."
  fi
fi
 
echo "\"$SERIAL\",\"$CIAD_NUMBER\",\"$(date -I)\",\"$STAGE\",\"$CPU_MODEL\",\"$RAM_GB\",\"$STORAGE_TYPE\",\"$STORAGE_CAPACITY_GB\",\"$SMART_STATUS\",\"\",\"\",\"\",\"\",\"\",\"\",\"$DRIVE_SERIAL\"" >> "$SUMMARY_CSV"
 
echo ""
echo "Done."
echo "Full log       : $OUT"
echo "Summary row in : $SUMMARY_CSV"
echo "Copy results off the Toolbox USB periodically — it's not permanent storage."
 
