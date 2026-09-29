#!/bin/bash
# erase-partition.sh — Le Relais PC Refurbishment
#
# Fetched via raw.githubusercontent.com and run under Ubuntu Live (see
# CLAUDE.md, "Delivery to target machines" — the Toolbox USB this comment
# used to describe is retired, see CLAUDE.md "Out of scope / superseded"),
# between "opening diagnostics" and "Windows 11 install" in the
# toolkit-reference.md workflow.
#
# Unlike diagnostics.sh v0.3 (which only RECOMMENDS a sanitization command),
# this script actually:
#   1. Re-detects the target drive from scratch (never trusts a device path
#      carried over from a prior boot session).
#   2. Sanitizes it, method chosen by drive type (methodology.md §4).
#   3. Verifies the sanitization independently of the tool that performed it.
#   4. Clears any leftover GPT/MBR partition-table structure (sgdisk
#      --zap-all) and leaves the disk fully unallocated — this script does
#      NOT create any partitions; Windows Setup partitions the whole disk
#      itself (v8; see changelog below).
#   5. Writes a per-machine erasure report and appends a stage=erase row to
#      the same results/summary.csv that diagnostics.sh writes to.
#
# v9 changes (SATA-SSD branch: prefer Enhanced Secure Erase; frozen-state fix
# corrected; provisional marker removed):
#   - First real-hardware confirmation of this branch, 2026-09-28 (002/SATA
#     SSD): exit=0, readback-sample verify=pass, partition=ok. Previously
#     marked "provisional, not yet confirmed" — see known-issues.md.
#   - Drive reported security state FROZEN on the first attempt. The die()
#     message below used to suggest a full power-off/power-on cycle; that is
#     unreliable because most BIOSes reissue SECURITY FREEZE LOCK on every
#     POST, refreezing the drive. Confirmed fix: suspend the machine to RAM
#     (S3) and resume — this forces a SATA link reset (COMRESET) via the
#     kernel without going through BIOS POST, so the freeze-lock command is
#     never reissued. Message updated accordingly.
#   - Now prefers `hdparm --security-erase-enhanced` over plain
#     `--security-erase` whenever `hdparm -I` reports enhanced-erase support,
#     recording which variant actually ran in erase_method (same pattern as
#     the NVMe crypto-erase/user-data-erase distinction above). Enhanced is a
#     strict superset by ATA spec (covers reallocated/spare sectors the plain
#     variant doesn't guarantee) at no measured cost — both completed in the
#     same ~30s ballpark on the confirmed drive, consistent with SSD firmware
#     typically implementing both via the same internal key-discard/
#     block-erase mechanism rather than a literal sector-by-sector overwrite.
#   - This is NOT a NIST-certified Purge-tier claim — see methodology.md §4.3
#     for why (NIST SP 800-88 Rev. 1 was withdrawn 2025-09-26 and superseded
#     by Rev. 2, which removed the per-command Clear/Purge table this project
#     used to cite and now defers to the paid IEEE 2883 standard instead).
#     §4.3 documents this as a reasoned judgment call, same treatment as
#     §4.1's NVMe Clear-tier fallback exception.
#
# v10 changes (revert v9's Enhanced-erase preference — empirically broke
# verification on real hardware):
#   - 2026-09-28, 002/SATA SSD: v9's `--security-erase-enhanced` completed
#     (exit=0) but readback-sample verification then failed at offset 0%
#     with non-zero data present. Re-running the SAME drive with the v1
#     script (plain `--security-erase`) passed verification cleanly at
#     every sampled offset. This is the concrete, on-hardware confirmation
#     of the spec distinction only described in theory in v9's changelog:
#     plain SECURITY ERASE UNIT is spec-defined to write binary zeroes;
#     ENHANCED SECURITY ERASE UNIT writes a manufacturer-defined pattern,
#     not guaranteed to be zero. This script's readback-sample verification
#     only checks for zero (§6) — so Enhanced was always going to look like
#     a failure on any drive whose vendor pattern isn't zero, independent of
#     whether the drive was actually sanitized.
#   - Reverted to plain `--security-erase` only, dropping v9's
#     enhanced-detection branch entirely. Considered instead teaching
#     verification to accept a captured non-zero pattern, but rejected: real
#     engineering complexity for a benefit (Enhanced's broader
#     reallocated/spare-sector coverage) already documented in
#     methodology.md §4.3 as not NIST-certified anyway — not worth adding a
#     second way to get sanitization verification wrong across ~100
#     machines. See methodology.md §4.3's dated correction note.
#   - The suspend-to-RAM frozen-state fix from v9 is unaffected and stays —
#     it's independently confirmed and unrelated to this bug.
#
# v11 changes (2026-09-29, messages only — no change to erase logic):
#   - FROZEN die() message now says how to suspend (Ubuntu's GUI power menu,
#     the method used on 002) and to re-run this script after resuming.
#   - End-of-run message points at scripts/laptop/pull-results.sh instead
#     of a hand-typed scp.
#
# v8 changes (Windows-only batch — 36 machines, IT dept priority,
# 2026-09-28, paired with diagnostics.sh v0.7):
#   - Header comment and the end-of-run reminder updated for the retired
#     Toolbox USB; end-of-run reminder now points at the SSH-based pull
#     (docs/ssh-access.md) instead.
#   - §7 no longer pre-creates a shared 512 MB ESP. That existed so Windows
#     Setup and, later, Mint's installer could both reuse ONE EFI System
#     Partition — a dual-boot-specific concern that doesn't apply to this
#     Windows-only batch. §7 now only zaps any leftover GPT/MBR structure
#     (still necessary: a crypto erase, NVMe --ses=2, discards the
#     encryption key rather than zero-writing the disk, so a stale garbled
#     partition table can survive as unreadable garbage and make Windows
#     Setup prompt to convert/repair the disk instead of showing plain
#     unallocated space) and leaves the rest for Windows Setup to partition
#     end-to-end itself. Dropped mkfs.fat/dosfstools from REQUIRED_TOOLS
#     accordingly (no longer used). summary.csv's "partitioned" status value
#     is kept as-is for continuity but now means "sanitized + confirmed
#     clean partition table," not "ESP created."
#   - CONFIRMED on real hardware 2026-09-28 (001/CIAD7562, NVMe Clear-tier
#     fallback path): zap succeeded, partition_status=ok, summary.csv row
#     updated correctly. If the dual-boot/Mint phase resumes later
#     (CLAUDE.md, "comes later"), pull the pre-created-shared-ESP
#     version back from git history rather than re-deriving it.
#   - RESULTS_DIR fixed from "$SCRIPT_DIR/../results" to "$SCRIPT_DIR/results"
#     — same Toolbox-USB-layout bug as diagnostics.sh v0.7 (see its
#     changelog for why). Both scripts must be fetched into the same
#     directory on the target so they agree on where results/ is.
#
# v7 changes (summary.csv redesign — one row per machine, paired with
# diagnostics.sh v0.6):
#   - summary.csv is now keyed on machine_serial (chassis serial) with
#     exactly ONE ROW PER MACHINE, not one row per stage. This script now
#     reads its own chassis serial too (dmidecode -t system, §1b — same
#     method diagnostics.sh uses), so §3 locates "this machine's" row the
#     same way diagnostics.sh does: by machine_serial, the actual PK, not
#     by CIAD number (manual entry, being phased out per open-questions.md).
#     CIAD number is still checked as a secondary consistency signal — a
#     mismatch between what's recorded and what was just typed is logged
#     as a warning, not fatal, since machine_serial is what actually
#     matters. The real safety check is unchanged in spirit: once the row
#     is found, its recorded drive_serial is still compared against the
#     drive just detected, and a mismatch still aborts rather than
#     proceeding. See chat, 2026-09-23/24, for the full reasoning (also
#     fixes the serial_number ambiguity where that column meant chassis
#     serial on "before" rows but drive serial on "erase" rows —
#     machine_serial and drive_serial are now always what their names say,
#     on every row).
#   - §8 now UPDATES that same row in place (erase_method, erase_result,
#     status) instead of appending a stage=erase row. erase_drive_serial is
#     deliberately not written — §3's cross-check already guarantees this
#     run's drive matches the row's recorded drive_serial before any write
#     happens, so a second copy of it would only restate what's already
#     there.
#   - erase_exit_status/verify_method/verify_result collapse into a single
#     erase_result: "pass" only when the sanitization command exited 0 AND
#     independent verification actually passed, "fail" otherwise. Dropped
#     erase_start/erase_end entirely — in the old schema these were both
#     `date -Iseconds` called back-to-back at CSV-write time, AFTER
#     sanitization/verification/partitioning had already finished, so they
#     were always identical and never actually reflected the real
#     operation's timing (confirmed against CIAD7483's own report: CSV said
#     erase_start=erase_end=13:51:49, but the report shows hdparm actually
#     ran 13:51:25→13:51:40). The real per-command timestamps remain
#     exactly where they always were — in run_logged()'s start=/end= lines
#     in this machine's own .txt report.
#   - status advances forward-only, same rule diagnostics.sh v0.6 uses: a
#     failed erase never downgrades a status already on record, and a
#     successful erase that fails to partition still advances status to
#     "erased" (partitioning wasn't tracked in the CSV at all before this
#     version — only in the free-text report).
#   - Fixed a latent CSV-corruption risk this redesign would otherwise hit:
#     ERASE_METHOD can legitimately contain a comma (e.g. the existing
#     "nvme --ses=1 (user-data erase, crypto erase unsupported)" label) but
#     summary.csv is parsed with a plain `awk -F','`, which doesn't respect
#     quoting. This never mattered under the old one-row-per-stage schema,
#     because no script ever re-parsed a stage=erase row's own later
#     columns. It WOULD matter now, because §8 has to read columns 10/11
#     (os_installed, status) back off the same row that holds erase_method
#     in column 8 — an embedded comma there would shift everything after
#     it. Fix: erase_method is written with commas replaced by semicolons
#     at write time, matching the punctuation the Clear-tier fallback
#     string already uses.
#
# v6 changes (resumable runs: skip re-erasing when only a later stage failed):
#   - Motivating case: a run got past sanitization and verification (both
#     genuinely completed) and then failed at partitioning. Re-running the
#     whole script from scratch would re-sanitize an already-sanitized
#     drive — wasted time on every retry, and destructive for no reason.
#   - Fix: after sanitization succeeds, and again after verification
#     passes, the script writes a small checkpoint file
#     (results/state_${MACHINE_ID}_${CIAD_NUMBER}.env — plain KEY=value,
#     RESUME_-prefixed, meant to be sourced) recording enough to skip
#     redoing that stage. On the next run, once the drive is re-detected
#     (detection itself is NEVER skipped), if a checkpoint exists for this
#     CIAD the script confirms the checkpoint's recorded drive serial
#     still matches what was JUST detected — refusing to resume against a
#     mismatched drive rather than trusting the file blindly — then offers
#     (default yes) to resume: skip confirmation + sanitization (and skip
#     verification too, if verification had already passed) and continue
#     from wherever it left off. Answering no runs the full sequence again,
#     including a real re-erase.
#   - The checkpoint is deleted once the run reaches PARTITION_STATUS=ok
#     (true completion). If verification legitimately fails (drive still
#     has data — a real problem, not a resumable one), no checkpoint is
#     written for that stage, so a re-run naturally re-attempts
#     verification rather than silently trusting a bad result; if it's the
#     partitioning step that fails, the checkpoint stays at "verify" so the
#     next run skips straight back to partitioning.
#   - Companion fix, same motivation: §8's summary.csv write is now an
#     upsert keyed on (ciad_number, drive_serial, stage=erase) rather than
#     a blind append. Without this, a resumed run that reaches §8 a second
#     time would leave TWO rows for the same erase attempt — one recording
#     the earlier failure (e.g. partition_status=fail) and one recording
#     the eventual success — which is exactly the "duplicate/partial row"
#     failure mode the erase-script checklist already calls out under
#     summary.csv. The upsert replaces the earlier row instead of adding a
#     second one, so a resumed machine still nets exactly one row, now
#     reflecting the final outcome. This also makes §8 idempotent for a
#     from-scratch re-run of the same CIAD/serial, independent of resume.
#
# v5 changes (bugfix: readback-sample verification crashed on every PASS):
#   - Discovered on 001/CIAD7562, immediately after a successful nwipe run:
#     step 6 ("Verification (readback-sample)") aborted with
#     "line 425: 0+0+0+0....: arithmetic syntax error" instead of reporting
#     PASS.
#   - Cause: the old sampling method piped a 4096-byte block through
#     `od -An -tu1`, then `tr -s ' \n' '+'` to turn the byte list into an
#     addition expression for `$(( ))`. GNU `od` defaults to collapsing runs
#     of IDENTICAL output lines into a single `*` marker rather than
#     printing them — and a genuinely all-zero 4096-byte block (i.e. the
#     PASS case this whole check exists to detect) is 256 identical lines,
#     guaranteed to trigger that collapse. `tr` turned the resulting `*`
#     into `+*+` inside the arithmetic string, which is a syntax error to
#     `$(( ))`, not just a bad value — fatal even under `set -uo pipefail`
#     without `-e`. Net effect: this check could never actually reach
#     VERIFY_RESULT=pass; it crashed on exactly the input it was supposed to
#     confirm. A non-zero/mismatched sample, by contrast, rarely has runs of
#     identical lines and mostly wouldn't have hit this — so the bug was
#     specific to the success path, which is why it went unnoticed until a
#     wipe actually succeeded.
#   - Fix: replaced the od/tr/arithmetic sum entirely with a direct byte-for-
#     byte comparison against a zero-filled reference via `cmp -s`. No text
#     rendering of the sample, no arithmetic expression, nothing for `od`'s
#     output-collapsing to interact with. Confirmed manually against the
#     live drive before changing the script (both the old od/tr expression
#     reproducing the bug, and the new cmp expression working correctly, at
#     the same block offset).
#   - Trade-off: the log no longer prints a `sum=<n>` figure for a mismatched
#     block (that figure was informational only — never part of the pass/
#     fail decision, which was always PASS_COUNT-based). If a byte-level
#     view of a mismatch is ever needed again, `sudo dd ... | od -An -tu1 -v`
#     (note the explicit `-v`/--output-duplicates, which disables the
#     collapsing) run by hand against the reported offset is the direct
#     replacement.
#   - See known-issues.md for the full writeup.
#
# v4 changes (--noblank; drop redundant blanking pass on nwipe zero-fills):
#   - Discovered on 001/CIAD7562, mid-run, by tracking /proc/<pid>/io
#     write_bytes for the live nwipe process: total bytes written exceeded
#     the drive's own capacity (confirmed via `blockdev --getsize64`) and
#     kept climbing well past it. Cause: nwipe's default behavior is to run
#     a final "blanking" pass after the selected method's pass, for every
#     method except RCMP TSSIT OPS-II — `zero` is not exempt. Neither nwipe
#     invocation below passed --noblank, so both were silently running a
#     full second all-zero pass on top of the first.
#   - For --method=zero specifically this second pass is pure redundancy:
#     the method's own pass already leaves the drive all-zero, so the
#     blanking pass verifies nothing new and changes nothing about the
#     sanitization result — it was roughly doubling this step's duration
#     on every machine processed so far, batch-wide, not just this unit.
#   - Fix: added --noblank to both nwipe calls (NVMe Clear-tier fallback
#     and plain HDD branch). No change to VERIFY_METHOD/VERIFY_RESULT
#     handling — the readback-sample verification already only checks the
#     final on-disk state, which is unaffected by dropping the redundant
#     pass.
#   - Considered adding automated in-script progress reporting (polling
#     /proc/<pid>/io on a timer, logging throughput/ETA) but decided
#     against it: extra process-management complexity (finding the correct
#     PID through sudo's monitor-process chain, backgrounding/cleanup) in
#     a script that's already destructive by design, for a convenience
#     feature. Documented the manual check instead (see comment block
#     immediately above §5) — it uses the same /proc/<pid>/io mechanism,
#     confirmed working by hand on 001/CIAD7562, without adding moving
#     parts to the unattended path.
#
# v3 changes (Clear-tier fallback for NVMe drives with no Purge-tier path):
#   - Confirmed on 001/CIAD7562 (Samsung MZVLW256HEHP-000L7): oacs/fna report
#     Format NVM + crypto-erase support, but `nvme format` rejects EVERY ses
#     value (0/1/2) with "Invalid Command Opcode", and sanicap=0 rules out
#     Sanitize entirely. Confirmed independent of nvme-cli via
#     `admin-passthru --opcode=0x80` (also rejected identically) — this is
#     the drive's firmware, not an nvme-cli bug or a namespace-addressing
#     issue. See known-issues.md for the full diagnosis trail.
#   - The NVMe branch now attempts Format NVM as before (crypto erase if
#     oacs/fna claims support, else user-data erase), but on failure inspects
#     WHETHER it failed with that specific opcode-level rejection. If so —
#     and ONLY if so — it falls back to a Clear-tier `nwipe` overwrite
#     (methodology.md §4.1, accepted exception, decided 2026-09-22). Any other
#     failure (mount lock, transient error, genuinely failing drive) does
#     NOT auto-fall-back; it stops for manual investigation, same as before.
#   - The Clear-tier fallback's `erase_method` string is deliberately
#     distinct from both the normal NVMe methods AND the plain HDD nwipe
#     label, so summary.csv doesn't conflate Purge-tier and Clear-tier
#     results under one name. See methodology.md §4 for the compliance
#     rationale (FADP "adequate measures" / NIST 800-88 tier language).
#   - Added --force to the nvme format invocation. Without it, nvme-cli
#     prompts for interactive confirmation — which hangs indefinitely in an
#     unattended run and defeats the point of this script. (Surfaced during
#     manual troubleshooting on 001/CIAD7562, where --force had to be typed
#     by hand each time; not previously in the scripted path.)
#
# v2 changes (bugfix, paired with diagnostics.sh v0.5):
#   - Step 3's pre-sanitize cross-check now matches the "before" diagnostic
#     row on the drive_serial column (16th field), scoped first by CIAD
#     number. Previously it matched drive serial against column 1
#     (serial_number), which diagnostics.sh populates with the MACHINE's
#     chassis serial (dmidecode), not the drive's — two different numbers,
#     so the match could only ever succeed by coincidence. This is the bug
#     behind "before row exists but isn't found" on 001/CIAD7562.
#   - If a "before" row exists for the given CIAD but has no drive_serial
#     recorded (i.e. it was written by diagnostics.sh v0.3/v0.4, before that
#     column existed), this now aborts with a specific instruction to
#     re-run diagnostics.sh's before-stage under the current version rather
#     than a generic "no match" error. Every machine already diagnosed
#     before this fix needs that one-time re-run — see known-issues.md.
#   - This script's own stage=erase row now also records the detected drive
#     serial under drive_serial (column 16), not just under serial_number
#     (column 1, kept as-is for continuity with existing rows).
#
# Report/summary file naming: erase_${MACHINE_ID}_${CIAD_NUMBER}.txt
# (CIAD number included so the filename can be matched directly to the
# physical asset sticker — diagnostics.sh matches this convention).
#
# Safety model: this script is destructive by design. It asks for typed
# confirmation of the drive's OWN reported serial (not the machine's) before
# touching anything, and aborts rather than guessing whenever detection is
# ambiguous (multiple candidate disks, no matching "before" diagnostic on
# record, etc.).
#
# Usage: ./erase-partition.sh (must be fetched into the same directory as
# diagnostics.sh, since both resolve results/ relative to their own location)
 
set -uo pipefail
# Deliberately no -e, same rationale as diagnostics.sh: a single missing tool
# must not silently abort a run that's already made destructive changes.
 
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULTS_DIR="$SCRIPT_DIR/results"
mkdir -p "$RESULTS_DIR"
SUMMARY_CSV="$RESULTS_DIR/summary.csv"
 
have() { command -v "$1" >/dev/null 2>&1; }
 
die() {
  echo ""
  echo "ABORTED: $1"
  [ -n "${OUT:-}" ] && { echo "ABORTED: $1" | tee -a "$OUT" >/dev/null; }
  exit 1
}
 
# ============================================================================
# 0. Tooling
# ============================================================================
REQUIRED_TOOLS=(
  nvme:nvme-cli
  smartctl:smartmontools
  dmidecode:dmidecode
  hdparm:hdparm
  nwipe:nwipe
  sgdisk:gdisk
  partprobe:parted
  cmp:diffutils
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
    echo "WARNING: could not install [${MISSING_PKGS[*]}] — no network or apt failed."
    echo "Steps requiring these tools will fail explicitly rather than be skipped silently."
  fi
fi
 
# ============================================================================
# 1. Identity prompts + report file (CIAD number in filename)
# ============================================================================
read -rp "Machine ID/label: " MACHINE_ID
read -rp "CIAD number: " CIAD_NUMBER
 
OUT="$RESULTS_DIR/erase_${MACHINE_ID}_${CIAD_NUMBER}.txt"
log() { echo -e "$1" | tee -a "$OUT"; }
run_logged() {
  # Logs the exact command, then runs it, then logs start/end/exit status.
  local desc="$1"; shift
  log "\n\$ $*"
  local start end rc
  start=$(date -Iseconds)
  "$@" 2>&1 | tee -a "$OUT"
  rc=${PIPESTATUS[0]}
  end=$(date -Iseconds)
  log "[$desc] start=$start end=$end exit_status=$rc"
  return "$rc"
}
 
echo "Erasure + partitioning for ${MACHINE_ID} (CIAD ${CIAD_NUMBER})" > "$OUT"
date >> "$OUT"
 
# ============================================================================
# 1b. Machine identity (chassis serial) — read the SAME way diagnostics.sh
# does (dmidecode -t system), so the two scripts agree on what identifies
# "this machine". summary.csv is keyed on this (machine_serial), per
# methodology.md §3's "source of truth" — NOT the CIAD number just typed
# above, which is manual entry and being phased out (open-questions.md).
# ============================================================================
log "\n=== Machine Identity ==="
SERIAL="unknown"
if have dmidecode; then
  SERIAL=$(sudo dmidecode -t system 2>/dev/null | awk -F': ' '/Serial Number/{print $2; exit}')
  [ -z "$SERIAL" ] && SERIAL="unknown"
fi
log "Machine serial  : $SERIAL   (chassis serial — dmidecode -t system, methodology.md §3. NOT the drive serial detected below.)"
[ "$SERIAL" = "unknown" ] && die "Could not read this machine's chassis serial (dmidecode -t system) — cannot look up its summary.csv row without it. Investigate manually (missing dmidecode? BIOS not exposing a serial?) before proceeding."
 
# --- Resume checkpoint ------------------------------------------------------
# See v6 changelog above. Written after sanitization succeeds and again
# after verification passes; consumed (and validated against the freshly
# re-detected drive) in §2b below; deleted once the run fully completes.
STATE_FILE="$RESULTS_DIR/state_${MACHINE_ID}_${CIAD_NUMBER}.env"
write_state() {
  local stage="$1"
  {
    echo "RESUME_STAGE=\"$stage\""
    echo "RESUME_DRIVE_SERIAL=\"$DRIVE_SERIAL\""
    echo "RESUME_DRIVE_MODEL=\"$DRIVE_MODEL\""
    echo "RESUME_PRIMARY_DEV=\"$PRIMARY_DEV\""
    echo "RESUME_STORAGE_TYPE=\"$STORAGE_TYPE\""
    echo "RESUME_CAP_BYTES=\"$CAP_BYTES\""
    echo "RESUME_ERASE_METHOD=\"$ERASE_METHOD\""
    echo "RESUME_ERASE_EXIT=\"$ERASE_EXIT\""
    echo "RESUME_VERIFY_METHOD=\"$VERIFY_METHOD\""
    echo "RESUME_MARKER_STRING=\"$MARKER_STRING\""
    echo "RESUME_MARKER_OFFSET_BYTES=\"$MARKER_OFFSET_BYTES\""
  } > "$STATE_FILE"
  log "[state] checkpoint saved: stage=$stage ($STATE_FILE)"
}
 
# ============================================================================
# 2. Re-detect the drive from scratch — do not trust anything from a prior run
# ============================================================================
log "\n=== Drive Detection ==="
 
PRIMARY_DEV=""
STORAGE_TYPE="unknown"
 
NVME_CANDIDATES=$(ls /dev/nvme?n1 2>/dev/null)
NVME_COUNT=$(echo "$NVME_CANDIDATES" | grep -c . || true)
 
if [ "$NVME_COUNT" -gt 1 ]; then
  die "Multiple NVMe devices detected ($NVME_CANDIDATES). Multi-disk machines are out of scope (see methodology.md single-disk assumption) — resolve manually, do not proceed automatically."
elif [ "$NVME_COUNT" -eq 1 ]; then
  PRIMARY_DEV="$NVME_CANDIDATES"
  STORAGE_TYPE="NVMe"
elif have lsblk; then
  CANDIDATES=$(lsblk -dno NAME,TYPE,TRAN,RM 2>/dev/null | awk '$2=="disk" && $3!="usb" && $4==0 {print $1}')
  CANDIDATE_COUNT=$(echo "$CANDIDATES" | grep -c . || true)
  if [ "$CANDIDATE_COUNT" -gt 1 ]; then
    die "Multiple non-USB disk-type block devices detected ($CANDIDATES). Multi-disk machines are out of scope — resolve manually."
  elif [ "$CANDIDATE_COUNT" -eq 1 ]; then
    PRIMARY_DEV="/dev/$CANDIDATES"
    ROTA=$(lsblk -dno ROTA "$PRIMARY_DEV" 2>/dev/null | tr -d '[:space:]')
    if [ "$ROTA" = "1" ]; then
      STORAGE_TYPE="SATA HDD (rotational)"
    else
      STORAGE_TYPE="SATA SSD (non-rotational)"
    fi
  fi
fi
 
[ -z "$PRIMARY_DEV" ] && die "No non-removable disk-type device could be identified automatically. Check manually with 'lsblk -f' before proceeding — do not guess a device path."
 
log "Detected device : $PRIMARY_DEV"
log "Detected type   : $STORAGE_TYPE"
 
# --- Drive's own reported identity (not the machine's dmidecode serial) ----
DRIVE_SERIAL="unknown"
DRIVE_MODEL="unknown"
CAP_BYTES=0
if [ "$STORAGE_TYPE" = "NVMe" ] && have nvme; then
  ID_CTRL=$(sudo nvme id-ctrl "$PRIMARY_DEV" 2>/dev/null)
  DRIVE_SERIAL=$(echo "$ID_CTRL" | awk -F': *' '/^sn[[:space:]]*:/{print $2; exit}' | tr -d '[:space:]')
  DRIVE_MODEL=$(echo "$ID_CTRL" | awk -F': *' '/^mn[[:space:]]*:/{print $2; exit}')
elif have smartctl; then
  SM_I=$(sudo smartctl -i "$PRIMARY_DEV" 2>/dev/null)
  DRIVE_SERIAL=$(echo "$SM_I" | awk -F': *' '/Serial Number/{print $2; exit}' | tr -d '[:space:]')
  DRIVE_MODEL=$(echo "$SM_I" | awk -F': *' '/Device Model|Model Number/{print $2; exit}')
fi
[ -z "$DRIVE_SERIAL" ] && DRIVE_SERIAL="unknown"
[ -z "$DRIVE_MODEL" ] && DRIVE_MODEL="unknown"
have lsblk && CAP_BYTES=$(lsblk -bdno SIZE "$PRIMARY_DEV" 2>/dev/null)
CAP_GB=$(( CAP_BYTES / 1000 / 1000 / 1000 ))
 
log "Drive model     : $DRIVE_MODEL"
log "Drive serial    : $DRIVE_SERIAL"
log "Capacity        : ${CAP_GB} GB"
 
[ "$DRIVE_SERIAL" = "unknown" ] && die "Could not read the drive's own serial number — cannot safely confirm identity before a destructive operation. Investigate manually."
 
# ============================================================================
# 2b. Resume check — is there a checkpoint from a previous run on THIS drive?
#
# Detection above is never skipped, resumed or trusted from a prior run —
# only what happens AFTER identity is re-confirmed can be skipped. If a
# checkpoint exists but names a different drive serial than what was just
# detected, this refuses to resume rather than risk acting on stale state
# against a machine that may have been swapped in the meantime.
# ============================================================================
RESUME_MODE=0
SKIP_ERASE=0
SKIP_VERIFY=0
if [ -f "$STATE_FILE" ]; then
  # shellcheck disable=SC1090
  source "$STATE_FILE"
  if [ -n "${RESUME_DRIVE_SERIAL:-}" ] && [ "$RESUME_DRIVE_SERIAL" != "$DRIVE_SERIAL" ]; then
    die "A checkpoint file exists for CIAD $CIAD_NUMBER ($STATE_FILE) but it was recorded against drive serial $RESUME_DRIVE_SERIAL, not the $DRIVE_SERIAL just detected. Refusing to resume against a mismatched drive. If this machine's disk was legitimately swapped, delete the checkpoint file manually and re-run; otherwise investigate why the serials differ before proceeding."
  fi
  if [ -n "${RESUME_STAGE:-}" ]; then
    log "\n=== Resume check ==="
    log "Found a checkpoint from a previous run on this drive: completed stage '$RESUME_STAGE'."
    read -rp "Resume from after that stage instead of re-erasing? [Y/n]: " RESUME_ANSWER
    case "${RESUME_ANSWER:-Y}" in
      [Nn]*)
        log "Starting a full run as requested — this WILL re-sanitize the drive."
        ;;
      *)
        RESUME_MODE=1
        case "$RESUME_STAGE" in
          erase)  SKIP_ERASE=1 ;;
          verify) SKIP_ERASE=1; SKIP_VERIFY=1 ;;
        esac
        log "Resuming: skip_erase=$SKIP_ERASE skip_verify=$SKIP_VERIFY"
        ;;
    esac
  fi
fi
 
# ============================================================================
# 3. Cross-check against the diagnostic already on record
#
# summary.csv is ONE ROW PER MACHINE, keyed on machine_serial (chassis
# serial) — methodology.md §3's source of truth. This script now reads its
# own chassis serial (§1b) so it looks up the same row diagnostics.sh
# creates/updates, the same way diagnostics.sh does. CIAD number is
# checked too, but only as a secondary consistency signal — it's manual
# entry, not the source of truth, so a mismatch there is logged as a
# warning, not fatal.
#
# The real safety gate is unchanged in spirit from prior versions: once
# the row is found, its recorded drive_serial is compared against the
# drive just detected in §2 — this is what proves the physical drive under
# the screwdriver is the one the opening diagnostic actually ran on, not
# just a coincidentally-matching machine or a drive swapped since.
# ============================================================================
log "\n=== Cross-check against opening diagnostic ==="
if [ ! -f "$SUMMARY_CSV" ]; then
  die "No summary.csv found at $SUMMARY_CSV — no diagnostic on record for this machine. Run diagnostics.sh first."
fi
 
MACHINE_ROWS=$(awk -F',' -v ms="\"$SERIAL\"" '$1==ms' "$SUMMARY_CSV")
MACHINE_ROW_COUNT=$(echo "$MACHINE_ROWS" | grep -c . || true)
 
if [ "$MACHINE_ROW_COUNT" -eq 0 ]; then
  die "No row in summary.csv for machine_serial $SERIAL. Run diagnostics.sh on this machine first — not proceeding automatically."
elif [ "$MACHINE_ROW_COUNT" -gt 1 ]; then
  die "Found $MACHINE_ROW_COUNT rows in summary.csv for machine_serial $SERIAL — the one-row-per-machine schema should have exactly one. Investigate and de-duplicate by hand before proceeding; not guessing which row is authoritative."
fi
 
RECORDED_CIAD=$(echo "$MACHINE_ROWS" | awk -F',' '{print $2}' | tr -d '"')
if [ "$RECORDED_CIAD" != "$CIAD_NUMBER" ]; then
  log "WARNING: this machine's row is recorded under CIAD $RECORDED_CIAD, but you just"
  log "entered CIAD $CIAD_NUMBER. machine_serial ($SERIAL) is the actual match key, so"
  log "proceeding — but double-check you didn't mistype the CIAD number, or that it"
  log "hasn't genuinely changed. This run will update the row's CIAD to $CIAD_NUMBER."
fi
 
RECORDED_DRIVE_SERIAL=$(echo "$MACHINE_ROWS" | awk -F',' '{print $6}' | tr -d '"')
if [ -z "$RECORDED_DRIVE_SERIAL" ] || [ "$RECORDED_DRIVE_SERIAL" = "unknown" ]; then
  die "Found this machine's row, but it has no drive_serial recorded (empty or 'unknown'). Re-run diagnostics.sh on this machine so the opening diagnostic actually captures the drive's serial, then re-run this script."
fi
 
if [ "$RECORDED_DRIVE_SERIAL" != "$DRIVE_SERIAL" ]; then
  die "Found this machine's row, but its recorded drive_serial ($RECORDED_DRIVE_SERIAL) does not match this drive's serial ($DRIVE_SERIAL). This may be the wrong machine/drive, or the drive may have been swapped since the diagnostic. Investigate before proceeding — not proceeding automatically."
fi
log "Match found: drive serial $DRIVE_SERIAL matches the diagnostic recorded for machine_serial $SERIAL. Proceeding."
 
if [ "$SKIP_ERASE" -eq 1 ]; then
  log "\n=== Confirmation + Sanitization (skipped — resuming from checkpoint) ==="
  ERASE_METHOD="$RESUME_ERASE_METHOD"
  ERASE_EXIT="${RESUME_ERASE_EXIT:-0}"
  VERIFY_METHOD="$RESUME_VERIFY_METHOD"
  MARKER_STRING="${RESUME_MARKER_STRING:-}"
  MARKER_OFFSET_BYTES="${RESUME_MARKER_OFFSET_BYTES:-$((1 * 1024 * 1024))}"
  log "Restored from checkpoint: erase_method=$ERASE_METHOD verify_method=$VERIFY_METHOD erase_exit=$ERASE_EXIT"
else
 
# ============================================================================
# 4. Explicit typed confirmation — this is the point of no return
# ============================================================================
log "\n=== Confirmation ==="
echo ""
echo "About to SANITIZE and REPARTITION:"
echo "  Device   : $PRIMARY_DEV"
echo "  Model    : $DRIVE_MODEL"
echo "  Serial   : $DRIVE_SERIAL"
echo "  Capacity : ${CAP_GB} GB"
echo "  Type     : $STORAGE_TYPE"
echo ""
read -rp "Type the LAST 4+ CHARACTERS of the drive serial above to confirm: " CONFIRM_INPUT
SERIAL_TAIL="${DRIVE_SERIAL: -4}"
case "$DRIVE_SERIAL" in
  *"$CONFIRM_INPUT") ;;
  *) die "Confirmation input '$CONFIRM_INPUT' does not match the end of serial '$DRIVE_SERIAL'. Nothing was erased." ;;
esac
[ "${#CONFIRM_INPUT}" -lt 4 ] && die "Confirmation input too short — type at least 4 characters of the serial. Nothing was erased."
log "Confirmed by technician: matched tail of serial $DRIVE_SERIAL."
 
# --- Manual progress check (optional, from a second terminal) --------------
# nwipe --nogui prints a start notice and a completion line to stdout, but
# no periodic progress in between — an unchanging tail is normal, not a
# hang. To check on a running wipe without interrupting it, from a SEPARATE
# terminal on this same Ubuntu Live session:
#
#   1. Find the real nwipe worker process. sudo wraps the actual command in
#      a monitor process, so `pgrep -af nwipe` shows multiple PIDs for one
#      wipe — don't assume duplicates mean concurrent wipes:
#        pgrep -af nwipe
#      Confirm the parent/child chain to find the true worker PID (the one
#      with no "sudo" in its own command line, and another nwipe PID as its
#      parent):
#        ps -eo pid,ppid,lstart,cmd | grep nwipe
#
#   2. Read live throughput directly from the kernel — this works
#      regardless of nwipe's own stdout buffering, which is unreliable to
#      depend on when piped through `tee` as this script does:
#        sudo cat /proc/<worker_pid>/io      # note write_bytes
#        sleep 60
#        sudo cat /proc/<worker_pid>/io      # note write_bytes again
#      (second value − first value) / 60 = current throughput, bytes/sec.
#      A single short sample can catch an SSD write-cache burst and read
#      much faster than the sustained rate — a 60s+ window, or two
#      samples compared against each other, is more trustworthy than one.
#
#   3. Compare against the drive's actual capacity (not the marketing
#      label — they can differ):
#        sudo blockdev --getsize64 $PRIMARY_DEV
#      With --noblank in effect (see v4 changes above), total write_bytes
#      for a single zero pass should top out at roughly this figure, not
#      double it.
# -----------------------------------------------------------------------------
 
# ============================================================================
# 5. Sanitization — method branches by drive type (methodology.md §4)
# ============================================================================
log "\n=== Sanitization ==="
ERASE_METHOD="none"
ERASE_EXIT=1
VERIFY_METHOD="none"
VERIFY_RESULT="not_run"
MARKER_STRING=""
MARKER_OFFSET_BYTES=$((1 * 1024 * 1024))  # 1 MiB in — clear of any partition table remnants
 
case "$STORAGE_TYPE" in
  NVMe)
    CRYPTO_SUPPORTED=0
    if have nvme; then
      FNA_DECODE=$(sudo nvme id-ctrl -H "$PRIMARY_DEV" 2>&1)
      log "\n-- nvme id-ctrl -H (Format NVM Attributes) --"
      echo "$FNA_DECODE" | tee -a "$OUT" >/dev/null
      echo "$FNA_DECODE" | grep -qi "crypto erase supported" && CRYPTO_SUPPORTED=1
    fi
 
    if [ "$CRYPTO_SUPPORTED" -eq 1 ]; then
      TRY_SES=2
      TRY_LABEL="nvme --ses=2 (crypto erase)"
      TRY_VERIFY="marker-file"
    else
      TRY_SES=1
      TRY_LABEL="nvme --ses=1 (user-data erase, crypto erase unsupported)"
      TRY_VERIFY="readback-sample"
    fi
 
    if [ "$TRY_VERIFY" = "marker-file" ]; then
      MARKER_STRING="LERELAIS-ERASE-MARKER-$(date +%s)-$$"
      log "\n-- Writing pre-erase marker for independent verification --"
      log "Marker offset: ${MARKER_OFFSET_BYTES} bytes; marker: $MARKER_STRING"
      printf '%s' "$MARKER_STRING" | sudo dd of="$PRIMARY_DEV" bs=1 seek="$MARKER_OFFSET_BYTES" conv=notrunc status=none
    fi
 
    FORMAT_OUTPUT=$(sudo nvme format "$PRIMARY_DEV" --ses="$TRY_SES" --force 2>&1)
    FORMAT_EXIT=$?
    log "\n\$ sudo nvme format $PRIMARY_DEV --ses=$TRY_SES --force"
    echo "$FORMAT_OUTPUT" | tee -a "$OUT" >/dev/null
    log "[nvme_format_attempt] exit_status=$FORMAT_EXIT"
 
    if [ "$FORMAT_EXIT" -eq 0 ]; then
      ERASE_METHOD="$TRY_LABEL"
      ERASE_EXIT=0
      VERIFY_METHOD="$TRY_VERIFY"
 
    elif echo "$FORMAT_OUTPUT" | grep -qiE "invalid.?command.?opcode|INVALID_OPCODE"; then
      # Opcode-level rejection, not SES-specific — matches the confirmed
      # unsupported-firmware pattern (known-issues.md: this drive's oacs/fna
      # report Format NVM + crypto-erase support that isn't actually
      # implemented; sanicap=0 already rules out Sanitize). No Purge-tier
      # path exists on this drive. Accepted exception, decided 2026-09-22:
      # fall back to a Clear-tier overwrite rather than pulling the machine
      # from the participant pool. See methodology.md §4.
      log "\nFormat NVM rejected at the opcode level (not SES-specific) — matches the"
      log "confirmed unsupported-firmware pattern in known-issues.md. No Purge-tier"
      log "path exists on this drive (Format NVM unimplemented despite oacs/fna"
      log "claiming support; sanicap=0 rules out Sanitize). Falling back to"
      log "Clear-tier overwrite per methodology.md §4 (accepted exception)."
      ERASE_METHOD="nwipe overwrite (Clear-tier fallback — Format NVM confirmed unsupported despite oacs/fna claiming support; see known-issues.md)"
      if have nwipe; then
        run_logged "nwipe_nvme_fallback" sudo nwipe --nogui --autonuke --noblank --method=zero "$PRIMARY_DEV"
        ERASE_EXIT=$?
      else
        log "nwipe not available — cannot apply the Clear-tier fallback automatically."
        ERASE_EXIT=1
      fi
      VERIFY_METHOD="readback-sample"
 
    else
      log "\nFormat NVM failed for a reason OTHER than opcode-level rejection (exit"
      log "$FORMAT_EXIT). NOT falling back automatically — this could be a mount"
      log "lock, a transient error, or a genuinely failing drive, none of which"
      log "the Clear-tier fallback decision was meant to cover. Investigate"
      log "manually before proceeding; do not assume this is the known"
      log "unsupported-firmware case without re-checking the output above."
      ERASE_METHOD="$TRY_LABEL (failed, non-opcode error — see report for output)"
      ERASE_EXIT="$FORMAT_EXIT"
      VERIFY_METHOD="none"
    fi
    ;;
 
  "SATA SSD (non-rotational)")
    log "NOTE: SATA-SSD secure-erase path — confirmed on real hardware 2026-09-28 (002). Uses plain --security-erase deliberately, not Enhanced — see methodology.md §4.3 (v10 correction)."
    FROZEN_CHECK=$(sudo hdparm -I "$PRIMARY_DEV" 2>&1)
    log "\n-- hdparm -I security state --"
    echo "$FROZEN_CHECK" | tee -a "$OUT" >/dev/null
    if echo "$FROZEN_CHECK" | grep -Eqi "^\s*frozen\b" ; then
      die "Drive reports security state FROZEN — hdparm secure erase will fail. This is a known BIOS/ATA behavior (BIOS reissues SECURITY FREEZE LOCK on every POST). Confirmed fix (002, 2026-09-28): suspend the machine to RAM (S3) and resume — this forces a SATA link reset without going through BIOS POST, so the freeze-lock command is never reissued. To do it: top-right system menu > Power > Suspend, wake the machine with the power button, then re-run this script (same directory). A full power-off/power-on cycle is NOT reliable by itself, since it goes through POST again and typically refreezes the drive. Nothing was erased."
    fi
    ERASE_METHOD="hdparm security-erase"
    run_logged "hdparm_set_pass" sudo hdparm --user-master u --security-set-pass p1 "$PRIMARY_DEV"
    run_logged "hdparm_secure_erase" sudo hdparm --user-master u --security-erase p1 "$PRIMARY_DEV"
    ERASE_EXIT=$?
    VERIFY_METHOD="readback-sample"
    ;;
 
  "SATA HDD (rotational)")
    ERASE_METHOD="nwipe (single overwrite pass)"
    if have nwipe; then
      run_logged "nwipe" sudo nwipe --nogui --autonuke --noblank --method=zero "$PRIMARY_DEV"
      ERASE_EXIT=$?
    else
      log "nwipe not available — cannot sanitize this HDD automatically."
      ERASE_EXIT=1
    fi
    VERIFY_METHOD="readback-sample"
    ;;
 
  *)
    die "Drive type could not be determined — resolve manually before sanitizing."
    ;;
esac
 
if [ "$ERASE_EXIT" -ne 0 ]; then
  log "\n*** SANITIZATION FAILED (exit $ERASE_EXIT) — STOPPING. No partitioning will be attempted. ***"
  log "This machine needs manual investigation before proceeding."
  # Still write the CSV row (see §8) so the failure is on record, not silent.
  ERASE_ROW_STATUS="fail"
else
  log "\nSanitization command completed (exit $ERASE_EXIT)."
  write_state "erase"
fi
 
fi  # end SKIP_ERASE
 
# ============================================================================
# 6. Verification — independent of the tool that performed the erase
# ============================================================================
if [ "$ERASE_EXIT" -eq 0 ] && [ "$SKIP_VERIFY" -eq 1 ]; then
  log "\n=== Verification ($VERIFY_METHOD) — skipped, resuming from checkpoint (already passed) ==="
  VERIFY_RESULT="pass"
elif [ "$ERASE_EXIT" -eq 0 ]; then
  log "\n=== Verification ($VERIFY_METHOD) ==="
 
  if [ "$VERIFY_METHOD" = "marker-file" ]; then
    READBACK=$(sudo dd if="$PRIMARY_DEV" bs=1 skip="$MARKER_OFFSET_BYTES" count="${#MARKER_STRING}" status=none 2>/dev/null)
    if [ "$READBACK" = "$MARKER_STRING" ]; then
      VERIFY_RESULT="fail"
      log "FAIL: pre-erase marker is still readable at the same LBA offset after crypto erase. Key was not discarded as expected — treat as UNSANITIZED."
    else
      VERIFY_RESULT="pass"
      log "PASS: pre-erase marker is no longer recoverable at the same LBA offset (expected result for crypto erase — the key was discarded, so the ciphertext at that offset no longer decodes to the marker)."
    fi
    log "\n-- nvme sanitize-log (secondary, device-reported cross-check) --"
    have nvme && sudo nvme sanitize-log "$PRIMARY_DEV" 2>&1 | tee -a "$OUT" >/dev/null
 
  elif [ "$VERIFY_METHOD" = "readback-sample" ]; then
    # 5 offsets spread across the drive: 0%, 25%, 50%, 75%, ~99%.
    # Assumes the erased pattern is zero-fill (true for nwipe --method=zero
    # and typically true for ATA/NVMe user-data erase, but not guaranteed by
    # spec for every vendor — a mismatch is logged with its offset so it can
    # be inspected manually rather than trusted blindly).
    #
    # Each 4096-byte sample is compared directly against a zero-filled
    # reference with `cmp -s`, rather than summed via `od`/`tr`/arithmetic.
    # (v5: the old od/tr/arithmetic approach crashed with a bash arithmetic
    # syntax error on every all-zero block — see the v5 changelog at the top
    # of this file and known-issues.md. `cmp` does a direct byte comparison
    # and has no equivalent failure mode.)
    #
    # NOTE (Clear-tier fallback case): on a wear-leveled SSD, this confirms
    # what's readable at the OS/LBA level, not what's physically recoverable
    # from remapped flash cells the controller no longer maps to those LBAs.
    # A "pass" here is the best available confirmation on hardware with no
    # Purge-tier path — it is not equivalent to the marker-file verification
    # used for crypto erase. See methodology.md §4.2 (docs/methodology.md,
    # post-merge; was refurb-diagnostics-methodology.md §3 pre-merge).
    OFFSETS_PCT=(0 25 50 75 99)
    PASS_COUNT=0
    TOTAL_COUNT=${#OFFSETS_PCT[@]}
    for pct in "${OFFSETS_PCT[@]}"; do
      OFFSET_BYTES=$(( CAP_BYTES * pct / 100 ))
      SKIP_BLOCKS=$(( OFFSET_BYTES / 4096 ))
      if sudo dd if="$PRIMARY_DEV" bs=4096 count=1 skip="$SKIP_BLOCKS" status=none 2>/dev/null | cmp -s - <(head -c 4096 /dev/zero); then
        log "  offset ${pct}% (byte ${OFFSET_BYTES}): all-zero — match"
        PASS_COUNT=$(( PASS_COUNT + 1 ))
      else
        log "  offset ${pct}% (byte ${OFFSET_BYTES}): NON-ZERO data present — mismatch"
      fi
    done
    if [ "$PASS_COUNT" -eq "$TOTAL_COUNT" ]; then
      VERIFY_RESULT="pass"
      log "PASS: ${PASS_COUNT}/${TOTAL_COUNT} sampled offsets read back as zero."
    elif [ "$PASS_COUNT" -eq 0 ]; then
      VERIFY_RESULT="fail"
      log "FAIL: 0/${TOTAL_COUNT} sampled offsets read back as zero. Treat as UNSANITIZED."
    else
      VERIFY_RESULT="partial (${PASS_COUNT}/${TOTAL_COUNT})"
      log "PARTIAL: only ${PASS_COUNT}/${TOTAL_COUNT} sampled offsets read back as zero — investigate manually before trusting this drive as sanitized."
    fi
  fi
 
  if [ "$VERIFY_RESULT" = "pass" ]; then
    write_state "verify"
  fi
fi
 
if [ "$ERASE_EXIT" -eq 0 ] && [ "$VERIFY_RESULT" != "pass" ]; then
  log "\n*** VERIFICATION DID NOT PASS ($VERIFY_RESULT) — STOPPING. No partitioning will be attempted. ***"
  log "This machine needs manual investigation before proceeding."
fi
 
# ============================================================================
# 7. Partition-table cleanup (only if erase+verify OK)
#
# v8: no longer creates a shared ESP — see v8 changelog above. Just zaps any
# leftover GPT/MBR structure and leaves the disk fully unallocated for
# Windows Setup to partition end-to-end itself.
# ============================================================================
PARTITION_STATUS="not_attempted"
if [ "$ERASE_EXIT" -eq 0 ] && [ "$VERIFY_RESULT" = "pass" ]; then
  log "\n=== Partition-table cleanup (zap only — Windows Setup partitions the rest) ==="

  run_logged "sgdisk_zap" sudo sgdisk --zap-all "$PRIMARY_DEV"
  ZAP_EXIT=$?
  have partprobe && sudo partprobe "$PRIMARY_DEV" 2>&1 | tee -a "$OUT" >/dev/null

  if [ "$ZAP_EXIT" -eq 0 ]; then
    PARTITION_STATUS="ok"
  else
    log "ERROR: sgdisk --zap-all failed (exit $ZAP_EXIT) — partition table may not be clean."
    PARTITION_STATUS="fail"
  fi

  log "\n-- Resulting partition table (should be empty) --"
  sudo sgdisk -p "$PRIMARY_DEV" 2>&1 | tee -a "$OUT" >/dev/null
  have lsblk && lsblk "$PRIMARY_DEV" 2>&1 | tee -a "$OUT" >/dev/null

  log "\nNext step (outside this script): boot the Windows 11 USB and install"
  log "to this disk's unallocated space — Setup creates its own ESP/MSR/"
  log "recovery partitions from scratch."
fi
 
# ============================================================================
# 8. summary.csv — update this machine's row in place
#
# summary.csv is ONE ROW PER MACHINE now, not one row per stage — this
# updates the same row §3 already matched (by machine_serial) rather than
# appending a new stage=erase row. Still idempotent/resume-safe the same
# way the old upsert was: re-running this section (e.g. after a resumed
# run) just overwrites this row's erase_method/erase_result/status again
# with the latest outcome, never adds a second row.
#
# erase_drive_serial is deliberately NOT written here — §3's cross-check
# already guarantees this run's drive matches the row's recorded
# drive_serial before any write happens, so a second copy would only ever
# restate what column 6 already holds.
#
# erase_result collapses the old erase_exit_status/verify_method/
# verify_result trio into a single pass/fail: "pass" only when the
# sanitization command itself exited 0 AND independent verification
# actually passed. status advances forward-only (same rule diagnostics.sh
# v0.6 uses) — a failed run never downgrades progress already on record,
# and a successful erase that failed to partition still advances status to
# "erased" (partitioning wasn't tracked in the CSV at all before this
# version).
#
# ERASE_METHOD can legitimately contain a comma (e.g. the existing
# "nvme --ses=1 (user-data erase, crypto erase unsupported)" label). Since
# summary.csv is parsed with plain `awk -F','` (no quote-awareness) and §8
# now has to read columns 10/11 back off THIS SAME row, an embedded comma
# in column 8 would shift everything after it. Commas are replaced with
# semicolons at write time to prevent that — matching the punctuation the
# Clear-tier fallback string already uses.
# ============================================================================
log "\n=== Recording result ==="
 
EXPECTED_HEADER="machine_serial,ciad_number,ram_gb,storage_type,storage_capacity_gb,drive_serial,smart_status,erase_method,erase_result,os_installed,status,date,windows_verified"
CURRENT_HEADER=$(head -n1 "$SUMMARY_CSV")
if [ "$CURRENT_HEADER" != "$EXPECTED_HEADER" ]; then
  log "WARNING: summary.csv's header doesn't match the current one-row-per-machine"
  log "schema (machine_serial-keyed, 13 columns). §3 already matched a row against"
  log "it, so proceeding, but this file needs migrating to the current schema."
fi
 
SAFE_ERASE_METHOD=$(echo "$ERASE_METHOD" | tr ',' ';')
 
if [ "$ERASE_EXIT" -eq 0 ] && [ "$VERIFY_RESULT" = "pass" ]; then
  NEW_ERASE_RESULT="pass"
  # v8: "partitioned" now means "sanitized + confirmed clean partition table
  # (zap succeeded)," not "ESP created" — see v8 changelog above.
  if [ "$PARTITION_STATUS" = "ok" ]; then
    NEW_STATUS="partitioned"
  else
    NEW_STATUS="erased"
  fi
else
  NEW_ERASE_RESULT="fail"
  NEW_STATUS=""   # leave existing status untouched below — nothing new succeeded
fi
 
TMP_CSV=$(mktemp)
UPDATED=0
{
  IFS= read -r hdr_line
  echo "$hdr_line"
  while IFS= read -r row; do
    ROW_SERIAL=$(echo "$row" | awk -F',' '{print $1}' | tr -d '"')
    if [ "$ROW_SERIAL" = "$SERIAL" ]; then
      UPDATED=1
      OLD_RAM=$(echo "$row" | awk -F',' '{print $3}')
      OLD_STORAGE_TYPE=$(echo "$row" | awk -F',' '{print $4}')
      OLD_STORAGE_CAP=$(echo "$row" | awk -F',' '{print $5}')
      OLD_DRIVE_SERIAL=$(echo "$row" | awk -F',' '{print $6}')
      OLD_SMART=$(echo "$row" | awk -F',' '{print $7}')
      OLD_OS_INSTALLED=$(echo "$row" | awk -F',' '{print $10}')
      OLD_STATUS=$(echo "$row" | awk -F',' '{print $11}')
      OLD_WINDOWS_VERIFIED=$(echo "$row" | awk -F',' '{print $13}')
      FINAL_STATUS="$OLD_STATUS"
      [ -n "$NEW_STATUS" ] && FINAL_STATUS="\"$NEW_STATUS\""
      echo "\"$SERIAL\",\"$CIAD_NUMBER\",$OLD_RAM,$OLD_STORAGE_TYPE,$OLD_STORAGE_CAP,$OLD_DRIVE_SERIAL,$OLD_SMART,\"$SAFE_ERASE_METHOD\",\"$NEW_ERASE_RESULT\",$OLD_OS_INSTALLED,$FINAL_STATUS,\"$(date -I)\",$OLD_WINDOWS_VERIFIED"
    else
      echo "$row"
    fi
  done
} < "$SUMMARY_CSV" > "$TMP_CSV"
 
mv "$TMP_CSV" "$SUMMARY_CSV"
 
if [ "$UPDATED" -eq 1 ]; then
  log "Updated summary.csv row for machine_serial $SERIAL / CIAD $CIAD_NUMBER (erase_result=$NEW_ERASE_RESULT)."
else
  log "WARNING: could not find machine_serial $SERIAL's row in summary.csv to update, even"
  log "though §3 matched it moments ago — summary.csv may have been modified"
  log "concurrently. Nothing was written."
fi
 
if [ "$PARTITION_STATUS" = "ok" ]; then
  rm -f "$STATE_FILE"
  log "[state] checkpoint cleared — run completed successfully."
fi

# --- Repair ownership if this was (mistakenly) run under sudo ---------------
# Root is only needed for the individual commands above (nvme, sgdisk, ...)
# — see "Usage: ./erase-partition.sh" at the top — not the script as a
# whole. If it WAS invoked via sudo anyway, every file under $RESULTS_DIR
# ends up root-owned, which blocks the scp/sftp pull later (SFTP runs as the
# authenticated live-session user, not root, and can't open a root-owned
# file). Same SUDO_USER-based fix diagnostics.sh uses.
if [ "$(id -u)" -eq 0 ] && [ -n "${SUDO_USER:-}" ]; then
  chown -R "$SUDO_USER:$SUDO_USER" "$RESULTS_DIR"
fi

echo ""
echo "Done."
echo "Full report    : $OUT"
echo "Summary row in : $SUMMARY_CSV"
echo "Erase status   : exit=$ERASE_EXIT, verify=$VERIFY_RESULT, partition=$PARTITION_STATUS"
echo "This live session is not permanent storage — once enable-ssh.sh has been"
echo "run on this machine, pull these from the laptop (docs/toolkit-reference.md):"
echo "  scripts/laptop/pull-results.sh <this-machine-ip> <machine-label>"
