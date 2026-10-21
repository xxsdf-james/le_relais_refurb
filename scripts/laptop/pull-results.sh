#!/usr/bin/env bash
# Runs on the laptop, not a target machine — not part of the
# raw.githubusercontent.com delivery path (CLAUDE.md, "Delivery to target
# machines"). Pulls one machine's results/ (diag_*.txt + erase_*.txt +
# summary.csv, plus drives.csv on a multi-disk machine) from an Ubuntu Live
# session over SSH, per docs/ssh-access.md.
#
# summary.csv lands as <machine-label>/summary.csv. The closing session's
# copy is a superset of the opening one (push-summary.sh sends the opening
# row back before closing diagnostics), so a later pull replaces an earlier
# one — but the existing file is first copied to a timestamped backup, in
# case the push was skipped and the incoming copy is missing the erase
# columns. combine-summary.sh stacks the per-machine files into one.

set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: pull-results.sh <target-ip|user@target-ip> <machine-label> [remote-user] [remote-results-dir]

  target-ip           e.g. 192.168.8.18, or ubuntu@192.168.8.18 (either form works)
  machine-label       local folder name to file this machine's results under
  remote-user         default: ubuntu (ignored if user@ was given in the first arg)
  remote-results-dir  default: results (relative to the remote user's home,
                       resolved by the SFTP server — safe regardless of scp's
                       own tilde-expansion behavior). diagnostics.sh prints
                       the exact absolute path at the end of its run
                       ("Summary row in: ...") if this default doesn't match.

Local destination: ${LE_RELAIS_RESULTS_DIR:-<repo's parent dir>/le_relais_refurb_results}/<machine-label>/
Default is a sibling of this repo (created if it doesn't exist yet, used
as-is if it does), never inside the repo itself — see CLAUDE.md, "Repo
layout": real results don't go in git.
USAGE
}

if [ "$#" -lt 2 ]; then
  usage
  exit 1
fi

TARGET_ARG="$1"
if [[ "$TARGET_ARG" == *"@"* ]]; then
  REMOTE_USER="${TARGET_ARG%%@*}"
  TARGET_IP="${TARGET_ARG#*@}"
else
  TARGET_IP="$TARGET_ARG"
  REMOTE_USER="ubuntu"
fi
MACHINE_LABEL="$2"
REMOTE_USER="${3:-$REMOTE_USER}"
REMOTE_RESULTS_DIR="${4:-results}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DEFAULT_RESULTS_DIR="$(dirname "$REPO_ROOT")/le_relais_refurb_results"

LOCAL_BASE="${LE_RELAIS_RESULTS_DIR:-$DEFAULT_RESULTS_DIR}"
LOCAL_DEST="$LOCAL_BASE/$MACHINE_LABEL"

# Each live-session boot has a fresh, unpersisted host key (docs/ssh-access.md,
# "REMOTE HOST IDENTIFICATION HAS CHANGED"). Until 2026-10-21 this script
# re-scanned and trusted whatever key answered at the IP. Now it uses the key
# verified with the session code (lib-target.sh), and asks for the code if
# there's none for this IP or the machine there presents a different key.
# shellcheck source=lib-target.sh
source "$SCRIPT_DIR/lib-target.sh"
ensure_host "$TARGET_IP"

# Before anything lands in $LOCAL_DEST: the target's results must be this
# label's machine. The session code only proves which machine is at the IP,
# not that it's the one the label names. (Added 2026-10-21, found in a dry
# run: a pull under the wrong label overwrote another machine's summary.csv.)
INCOMING_SUMMARY=$(mktemp)
trap 'rm -f "$INCOMING_SUMMARY"' EXIT
scp "${SSH_OPTS[@]}" "${REMOTE_USER}@${TARGET_IP}:${REMOTE_RESULTS_DIR}/summary.csv" "$INCOMING_SUMMARY" \
  || die "No ${REMOTE_RESULTS_DIR}/summary.csv on the target — has diagnostics.sh run there?"
INCOMING_SERIAL=$(summary_field "$INCOMING_SUMMARY" 1)
REMOTE_ASSET=$(ssh "${SSH_OPTS[@]}" -n "${REMOTE_USER}@${TARGET_IP}" "cat ${REMOTE_RESULTS_DIR}/identity.env 2>/dev/null" \
  | sed -n 's/^ASSET_TAG=//p' || true)
if [ -n "$REMOTE_ASSET" ] && [ "$REMOTE_ASSET" != "$MACHINE_LABEL" ]; then
  die "The target was identified as asset tag $REMOTE_ASSET (identity.env), not $MACHINE_LABEL. Nothing pulled."
fi
if [ -f "$LOCAL_DEST/summary.csv" ] && [ "$(summary_field "$LOCAL_DEST/summary.csv" 1)" != "$INCOMING_SERIAL" ]; then
  die "$MACHINE_LABEL/summary.csv is for serial $(summary_field "$LOCAL_DEST/summary.csv" 1), but the target's is $INCOMING_SERIAL. Wrong label or wrong IP — nothing pulled."
fi

mkdir -p "$LOCAL_DEST"

echo "Pulling from ${REMOTE_USER}@${TARGET_IP}:${REMOTE_RESULTS_DIR}/ -> $LOCAL_DEST"

if ! scp "${SSH_OPTS[@]}" "${REMOTE_USER}@${TARGET_IP}:${REMOTE_RESULTS_DIR}/diag_*.txt" "$LOCAL_DEST/" 2>/dev/null; then
  echo "No diag_*.txt matched (fine if this pull is erase-only, or that stage hasn't run yet)."
fi

# erase-partition.sh names its report erase_${MACHINE_ID}_${CIAD_NUMBER}.txt
# — a different prefix from diagnostics.sh's diag_*.txt, so it needs its own
# glob. (Bug fixed 2026-09-28: this script only ever fetched diag_*.txt,
# so an erase-only pull silently came back with nothing — not an SSH or
# results/ path problem, just a missing pattern here.)
if ! scp "${SSH_OPTS[@]}" "${REMOTE_USER}@${TARGET_IP}:${REMOTE_RESULTS_DIR}/erase_*.txt" "$LOCAL_DEST/" 2>/dev/null; then
  echo "No erase_*.txt matched (fine if this pull is diagnostics-only, or that stage hasn't run yet)."
fi

SUMMARY_DEST="$LOCAL_DEST/summary.csv"
SUMMARY_BACKUP=""
if [ -f "$SUMMARY_DEST" ]; then
  SUMMARY_BACKUP="$LOCAL_DEST/summary.csv.$(date +%Y%m%d-%H%M%S).bak"
  cp -p "$SUMMARY_DEST" "$SUMMARY_BACKUP"
  echo "Backed up existing summary.csv -> $SUMMARY_BACKUP"
fi
cp "$INCOMING_SUMMARY" "$SUMMARY_DEST"

# drives.csv: one row per disk, only on machines with more than one internal
# disk (diagnostics.sh v0.11). A closing session usually has none, since
# the extra disk is out by then, so a missing remote file keeps the local one.
DRIVES_TMP=$(mktemp)
if scp "${SSH_OPTS[@]}" "${REMOTE_USER}@${TARGET_IP}:${REMOTE_RESULTS_DIR}/drives.csv" "$DRIVES_TMP" 2>/dev/null; then
  if [ -f "$LOCAL_DEST/drives.csv" ]; then
    cp -p "$LOCAL_DEST/drives.csv" "$LOCAL_DEST/drives.csv.$(date +%Y%m%d-%H%M%S).bak"
  fi
  mv "$DRIVES_TMP" "$LOCAL_DEST/drives.csv"
  echo "Pulled drives.csv (multi-disk machine)."
else
  rm -f "$DRIVES_TMP"
fi

# Warnings only — the pull itself has already succeeded. Status column 11,
# windows_verified column 13 (same positions diagnostics.sh writes).
ROW=$(sed -n 2p "$SUMMARY_DEST")
ROW_STATUS=$(echo "$ROW" | awk -F',' '{print $11}' | tr -d '"')
ROW_WINDOWS_VERIFIED=$(echo "$ROW" | awk -F',' '{print $13}' | tr -d '"')

echo ""
echo "Done."
echo "Logs        : $LOCAL_DEST (diag_*.txt and/or erase_*.txt, whichever stages have run)"
echo "Summary row : $SUMMARY_DEST"
echo "Status      : ${ROW_STATUS:-<blank>} (windows_verified: ${ROW_WINDOWS_VERIFIED:-<blank>})"

# Pulled copy identical to the one it replaced: nothing on the target updated
# the row since the last pull — e.g. push-summary.sh ran but closing
# diagnostics didn't (confirmed 2026-09-29 on CIAD7483).
if [ -n "$SUMMARY_BACKUP" ] && cmp -s "$SUMMARY_DEST" "$SUMMARY_BACKUP"; then
  echo ""
  echo "WARNING: summary.csv is unchanged since the last pull — did the script for"
  echo "this stage (diagnostics.sh / erase-partition.sh) actually run on the target?"
fi

# Closing diagnostics ran but didn't reach GREEN: the Windows Boot Manager
# check failed (see that diag_*_after.txt). Catch it while still in the session.
if compgen -G "$LOCAL_DEST/diag_*_after.txt" >/dev/null && [ "$ROW_STATUS" != "GREEN" ]; then
  echo ""
  echo "WARNING: a closing-diagnostics log is present but status is not GREEN —"
  echo "check the Windows Boot Manager section of diag_*_after.txt before handoff."
fi
