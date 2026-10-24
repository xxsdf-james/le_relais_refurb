#!/bin/bash
# Diagnostics script — Le Relais PC Refurbishment
#
# Fetched via raw.githubusercontent.com and run under Ubuntu Live (see
# CLAUDE.md, "Delivery to target machines" — the Toolbox USB this comment
# used to describe is retired, see CLAUDE.md "Out of scope / superseded").
# Assesses hardware condition and drive type. Does NOT wipe a disk, install
# anything, or verify Windows activation — those stay outside this script's
# scope (activation only exists inside a booted Windows session; it's checked
# there, see toolkit-reference.md).
#
# v0.12 changes (2026-10-21, paired with enable-ssh.sh v16 and the
# laptop-driven passes, scripts/laptop/open-machine.sh / close-machine.sh):
#   - If results/identity.env exists (written by enable-ssh.sh from the
#     stickers, typed at this machine's keyboard), the machine number and
#     CIAD come from it and aren't prompted for. Only the stage is asked.
#   - Stops before recording anything if that file's chassis serial differs
#     from the one dmidecode reads now (a file from another machine).
#   - Without the file, prompts exactly as before.
#
# v0.11 changes (2026-10-19, multi-disk support, paired with
# erase-partition.sh v15):
#   - On a machine with more than one internal disk, every disk's type,
#     capacity, model and own serial are read and logged, and upserted into
#     results/drives.csv (one row per disk, keyed on machine_serial +
#     drive_serial). erase-partition.sh v15 cross-checks each disk against
#     that file and records each disk's erase result in it. Its erase
#     columns are carried over untouched on a re-run.
#   - summary.csv is unchanged (same 13 columns). Its drive_serial and
#     storage columns still describe the first disk only.
#   - Single-disk machines: no drives.csv, no change in behavior.
#
# v0.10 changes (2026-10-14, after 036/FR1589 turned up a second internal
# disk, a 32 GB mSATA cache SSD next to the HDD):
#   - Counts every internal disk (NVMe and SATA together) and, if there is
#     more than one, prints a WARNING block listing them after the
#     sanitization recommendation. Previously only the first disk was
#     assessed and the rest were left out without a word; on 036 the extra
#     disk showed up only in the hardware summary.
#
# v0.9 changes (2026-09-29):
#   - Stage prompt now only accepts before/after (case-insensitive) and asks
#     again otherwise. Previously "After" (or any typo) was taken as-is: the
#     after-run logic never fired, so status never reached GREEN, and the log
#     was named diag_*_After.txt, which pull-results.sh's not-GREEN warning
#     (a case-sensitive diag_*_after.txt match) never saw either.
#   - Dropped the STAGE=after "Windows activation reminder" block. It dated
#     from when activation was checked in Settings; that GUI lags the real
#     state, and activation is now checked at the console with the
#     Get-CimInstance one-liner in toolkit-reference.md's Windows Update
#     walkthrough.
#   - End-of-run message points at scripts/laptop/pull-results.sh instead
#     of a hand-typed scp.
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
 
IDENTITY_FILE="$RESULTS_DIR/identity.env"
IDENTITY_SERIAL=""
if [ -f "$IDENTITY_FILE" ]; then
  # Read line by line, not sourced: it's data, not code.
  MACHINE_ID=$(sed -n 's/^MACHINE_NUMBER=//p' "$IDENTITY_FILE")
  CIAD_NUMBER=$(sed -n 's/^ASSET_TAG=//p' "$IDENTITY_FILE")
  IDENTITY_SERIAL=$(sed -n 's/^CHASSIS_SERIAL=//p' "$IDENTITY_FILE")
  if [ -z "$MACHINE_ID" ] || [ -z "$CIAD_NUMBER" ]; then
    echo "ERROR: $IDENTITY_FILE is incomplete — re-run enable-ssh.sh." >&2
    exit 1
  fi
  echo "Machine number $MACHINE_ID, CIAD $CIAD_NUMBER (from results/identity.env)"
else
  read -rp "Machine ID/label: " MACHINE_ID
  read -rp "CIAD number (manual entry, traceability to legacy tracking): " CIAD_NUMBER
fi
while :; do
  read -rp "Stage (before/after): " STAGE || exit 1
  STAGE="${STAGE,,}"
  case "$STAGE" in
    before|after) break ;;
    *) echo "Type 'before' or 'after'." ;;
  esac
done

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

if [ -n "$IDENTITY_SERIAL" ] && [ "$IDENTITY_SERIAL" != "$SERIAL" ]; then
  log "ERROR: results/identity.env was written for chassis serial $IDENTITY_SERIAL,"
  log "but this machine's is $SERIAL. Nothing recorded. Re-run enable-ssh.sh on"
  log "this machine, then this script."
  exit 1
fi

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
# The first internal disk found is assessed in full here and goes in
# summary.csv. If there are more (v0.11), every disk is also recorded in
# drives.csv further down. USB boot media is excluded from candidacy.
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
 
# v0.10: every internal disk, NVMe and SATA together (same filter as
# erase-partition.sh v14). PRIMARY_DEV above is only the first of these;
# any others would be left out of the recommendation below.
ALL_INTERNAL=$( { ls /dev/nvme?n1 2>/dev/null; have lsblk && lsblk -dno NAME,TYPE,TRAN,RM 2>/dev/null | awk '$2=="disk" && $3!="usb" && $4==0 {print "/dev/"$1}'; } | grep . | sort -u)
ALL_INTERNAL_COUNT=$(echo "$ALL_INTERNAL" | grep -c . || true)
 
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
 
if [ "$ALL_INTERNAL_COUNT" -gt 1 ]; then
  log "\n=== WARNING: MORE THAN ONE INTERNAL DISK ($ALL_INTERNAL_COUNT) ==="
  have lsblk && lsblk -dno NAME,SIZE,TRAN,ROTA,MODEL $ALL_INTERNAL 2>&1 | tee -a "$OUT"
  log "Only $PRIMARY_DEV was assessed above, and the recommendation covers only"
  log "that disk. Every other disk may also hold user data (e.g. an mSATA cache"
  log "SSD). Each disk is listed below and recorded in drives.csv: run"
  log "erase-partition.sh once per disk, picking a different one each time."

  # v0.11: identity read the same way as the primary disk above (same tools,
  # same fields), since erase-partition.sh matches against these serials.
  DRIVES_CSV="$RESULTS_DIR/drives.csv"
  DRIVES_HEADER="machine_serial,drive_serial,storage_type,storage_capacity_gb,drive_model,erase_method,erase_result,partition_status,date"
  [ -f "$DRIVES_CSV" ] || echo "$DRIVES_HEADER" > "$DRIVES_CSV"
  if [ "$(head -n1 "$DRIVES_CSV")" != "$DRIVES_HEADER" ]; then
    log "WARNING: drives.csv's header doesn't match the current schema — not updating it."
    log "erase-partition.sh will refuse to run on this machine until it's fixed by hand."
  else
    for dev in $ALL_INTERNAL; do
      D_TYPE="unknown"; D_SERIAL="unknown"; D_MODEL="unknown"; D_CAP_GB="unknown"
      case "$dev" in
        /dev/nvme*)
          D_TYPE="NVMe"
          if have nvme; then
            D_ID=$(sudo nvme id-ctrl "$dev" 2>/dev/null)
            D_SERIAL=$(echo "$D_ID" | awk -F': *' '/^sn[[:space:]]*:/{print $2; exit}' | tr -d '[:space:]')
            D_MODEL=$(echo "$D_ID" | awk -F': *' '/^mn[[:space:]]*:/{print $2; exit}')
          fi
          ;;
        *)
          if [ "$(lsblk -dno ROTA "$dev" 2>/dev/null | tr -d '[:space:]')" = "1" ]; then
            D_TYPE="SATA HDD (rotational)"
          else
            D_TYPE="SATA SSD (non-rotational)"
          fi
          if have smartctl; then
            D_ID=$(sudo smartctl -i "$dev" 2>/dev/null)
            D_SERIAL=$(echo "$D_ID" | awk -F': *' '/Serial Number/{print $2; exit}' | tr -d '[:space:]')
            D_MODEL=$(echo "$D_ID" | awk -F': *' '/Device Model|Model Number/{print $2; exit}')
          fi
          ;;
      esac
      [ -z "$D_SERIAL" ] && D_SERIAL="unknown"
      [ -z "$D_MODEL" ] && D_MODEL="unknown"
      D_MODEL=$(echo "$D_MODEL" | tr ',' ';')
      D_CAP_BYTES=$(lsblk -bdno SIZE "$dev" 2>/dev/null)
      [ -n "$D_CAP_BYTES" ] && D_CAP_GB=$(( D_CAP_BYTES / 1000 / 1000 / 1000 ))

      log "\n--- $dev ---"
      log "Type     : $D_TYPE"
      log "Model    : $D_MODEL"
      log "Serial   : $D_SERIAL   (drive's own serial)"
      log "Capacity : ${D_CAP_GB} GB"
      if have smartctl; then
        log "SMART    : $(sudo smartctl -H "$dev" 2>/dev/null | awk -F': ' '/overall-health/{print $2}')"
      fi
      if [ "$D_SERIAL" = "unknown" ]; then
        log "WARNING: could not read this disk's serial — not recorded in drives.csv,"
        log "so erase-partition.sh won't be able to erase it. Investigate first."
        continue
      fi

      # Upsert on (machine_serial, drive_serial). erase_method, erase_result
      # and partition_status belong to erase-partition.sh: kept as they were.
      D_ROW_PREFIX="\"$SERIAL\",\"$D_SERIAL\",\"$D_TYPE\",\"$D_CAP_GB\",\"$D_MODEL\""
      D_TMP=$(mktemp)
      D_MATCHED=0
      {
        IFS= read -r hdr_line
        echo "$hdr_line"
        while IFS= read -r row; do
          ROW_MS=$(echo "$row" | awk -F',' '{print $1}' | tr -d '"')
          ROW_DS=$(echo "$row" | awk -F',' '{print $2}' | tr -d '"')
          if [ "$ROW_MS" = "$SERIAL" ] && [ "$ROW_DS" = "$D_SERIAL" ]; then
            D_MATCHED=1
            echo "$D_ROW_PREFIX,$(echo "$row" | awk -F',' -v OFS=',' '{print $6,$7,$8}'),\"$(date -I)\""
          else
            echo "$row"
          fi
        done
      } < "$DRIVES_CSV" > "$D_TMP"
      [ "$D_MATCHED" -eq 0 ] && echo "$D_ROW_PREFIX,\"\",\"\",\"\",\"$(date -I)\"" >> "$D_TMP"
      mv "$D_TMP" "$DRIVES_CSV"
    done
    log "\nRecorded in $DRIVES_CSV."
  fi
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
#
# v0.8: this result now also drives the windows_verified column and the
# GREEN status below (STAGE=after only) — see the summary.csv comment block
# further down for why status is tied to this specific automated result
# rather than just trusting that closing diagnostics was only run after a
# manual pass.
log "\n=== Windows Boot Manager Check ==="
WINDOWS_BOOT_ENTRY_FOUND=0
if [ -n "$BOOTMGR_OUT" ]; then
  if echo "$BOOTMGR_OUT" | grep -qi "windows boot manager"; then
    WINDOWS_BOOT_ENTRY_FOUND=1
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

# --- Machine-readable summary — upsert one row per machine -------------------
# summary.csv is now ONE ROW PER MACHINE, keyed on machine_serial (chassis
# serial — the source of truth per methodology.md §3), not one row per
# stage. This script only owns and writes: machine_serial, ciad_number,
# ram_gb, storage_type, storage_capacity_gb, drive_serial, smart_status,
# windows_verified, date. Columns owned by other scripts (erase_method,
# erase_result, os_installed) are carried over untouched on update, left
# blank on insert.
#
# v0.8 — closing diagnostics (STAGE=after) now writes two things the opening
# pass doesn't:
#   - windows_verified: "verified" if the Windows Boot Manager Check above
#     found an EFI entry, "not verified" if it didn't. Column is otherwise
#     left untouched (blank on a fresh machine) — it only means anything
#     once an after-run has actually happened.
#   - status advances to GREEN, but ONLY when that same check passed. The
#     workflow already calls for closing diagnostics to run after a manual
#     Windows Update/activation check at the console (toolkit-reference.md,
#     steps 8-9) — GREEN is not a substitute for that, it's confirmation
#     that this automated signal agrees with it. If the boot-manager entry
#     is missing on an after-run, status is deliberately NOT advanced (this
#     is a real discrepancy worth investigating, not busywork) — same
#     forward-only rule as every other status value here, so a bad after-run
#     can't downgrade a GREEN a prior after-run already earned.
log "\n=== Recording result ==="

EXPECTED_HEADER="machine_serial,ciad_number,ram_gb,storage_type,storage_capacity_gb,drive_serial,smart_status,erase_method,erase_result,os_installed,status,date,windows_verified"
 
if [ ! -f "$SUMMARY_CSV" ]; then
  echo "$EXPECTED_HEADER" > "$SUMMARY_CSV"
fi
 
CURRENT_HEADER=$(head -n1 "$SUMMARY_CSV")
if [ "$CURRENT_HEADER" != "$EXPECTED_HEADER" ]; then
  log "WARNING: summary.csv's header doesn't match the current one-row-per-machine"
  log "schema (machine_serial-keyed, 13 columns). This usually means the file"
  log "still has rows in an older format and needs migrating by hand —"
  log "proceeding anyway rather than aborting a diagnostic run, but don't trust"
  log "this upsert to have found the right row until that's done."
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
      OLD_WINDOWS_VERIFIED=$(echo "$row" | awk -F',' '{print $13}')
      NEW_STATUS="$OLD_STATUS"
      NEW_WINDOWS_VERIFIED="$OLD_WINDOWS_VERIFIED"
      STATUS_BARE=$(echo "$OLD_STATUS" | tr -d '"')
      # Only ever set to "before" if nothing further has been recorded yet —
      # never downgrade progress an erase/partition run already made.
      [ -z "$STATUS_BARE" ] && NEW_STATUS="\"before\""
      if [ "$STAGE" = "after" ]; then
        if [ "$WINDOWS_BOOT_ENTRY_FOUND" -eq 1 ]; then
          NEW_WINDOWS_VERIFIED="\"verified\""
          NEW_STATUS="\"GREEN\""
        else
          NEW_WINDOWS_VERIFIED="\"not verified\""
          log "WARNING: no Windows Boot Manager entry found on this closing run —"
          log "status NOT advanced to GREEN. Investigate before treating $SERIAL"
          log "(CIAD $CIAD_NUMBER) as ready for handoff."
        fi
      fi
      echo "\"$SERIAL\",\"$CIAD_NUMBER\",\"$RAM_GB\",\"$STORAGE_TYPE\",\"$STORAGE_CAPACITY_GB\",\"$DRIVE_SERIAL\",\"$SMART_STATUS\",$OLD_ERASE_METHOD,$OLD_ERASE_RESULT,$OLD_OS_INSTALLED,$NEW_STATUS,\"$(date -I)\",$NEW_WINDOWS_VERIFIED"
    else
      echo "$row"
    fi
  done
} < "$SUMMARY_CSV" > "$TMP_CSV"

if [ "$MATCHED" -eq 0 ]; then
  INSERT_STATUS="\"before\""
  INSERT_WINDOWS_VERIFIED="\"\""
  if [ "$STAGE" = "after" ]; then
    log "WARNING: closing diagnostics ran for $SERIAL (CIAD $CIAD_NUMBER) but no"
    log "existing row was found — there's no 'before' baseline for this machine."
    log "Inserting a row anyway, but status is left at \"before\" rather than"
    log "GREEN: re-run opening diagnostics for this machine so there's an actual"
    log "before/after comparison on record, per methodology.md §1.2."
  fi
  echo "\"$SERIAL\",\"$CIAD_NUMBER\",\"$RAM_GB\",\"$STORAGE_TYPE\",\"$STORAGE_CAPACITY_GB\",\"$DRIVE_SERIAL\",\"$SMART_STATUS\",\"\",\"\",\"\",$INSERT_STATUS,\"$(date -I)\",$INSERT_WINDOWS_VERIFIED" >> "$TMP_CSV"
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
echo "This live session is not permanent storage — once enable-ssh.sh has been"
echo "run on this machine, pull these from the laptop (docs/toolkit-reference.md):"
echo "  scripts/laptop/pull-results.sh <this-machine-ip> <machine-label>"
