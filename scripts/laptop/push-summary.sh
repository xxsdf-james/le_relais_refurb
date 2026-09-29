#!/usr/bin/env bash
# Runs on the laptop, not a target machine — not part of the
# raw.githubusercontent.com delivery path (CLAUDE.md, "Delivery to target
# machines"). Pushes one machine's laptop copy of summary.csv (pulled by
# pull-results.sh during the opening session) back onto a fresh Ubuntu Live
# session over SSH, BEFORE closing diagnostics runs (toolkit-reference.md,
# step 11).
#
# Why: each live boot starts with an empty results/, so without this,
# diagnostics.sh's STAGE=after run finds no row for the machine, inserts a
# fresh "before" row, and never sets windows_verified or GREEN. With the
# opening row pushed back first, diagnostics.sh updates that row in place,
# and pull-results.sh then brings the complete row home.
#
# Refuses to push unless:
#   - the local summary.csv has the current header and exactly one row;
#   - the target's chassis serial matches that row's machine_serial (so a
#     wrong IP can't send one machine's record to another machine);
#   - there's no summary.csv on the target yet (so a closing run that
#     already happened without the push isn't silently overwritten).

set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: push-summary.sh <target-ip|user@target-ip> <machine-label> [remote-user] [remote-results-dir]

  Same arguments as pull-results.sh.

  target-ip           e.g. 192.0.2.10, or ubuntu@192.0.2.10 (either form works)
  machine-label       local folder whose summary.csv gets pushed — type it
                       deliberately, it's your confirmation of which machine
                       this is
  remote-user         default: ubuntu (ignored if user@ was given in the first arg)
  remote-results-dir  default: results (relative to the remote user's home).
                       Must be the results/ next to where diagnostics.sh will
                       be fetched — i.e. wget it into the home directory.

Local source: ${LE_RELAIS_RESULTS_DIR:-<repo's parent dir>/le_relais_refurb_results}/<machine-label>/summary.csv
USAGE
}

die() {
  echo "ERROR: $*" >&2
  exit 1
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

KEY="$HOME/.ssh/id_ed25519_refurb"
LOCAL_BASE="${LE_RELAIS_RESULTS_DIR:-$DEFAULT_RESULTS_DIR}"
LOCAL_SUMMARY="$LOCAL_BASE/$MACHINE_LABEL/summary.csv"

# Keep in sync with EXPECTED_HEADER in diagnostics.sh and erase-partition.sh.
EXPECTED_HEADER="machine_serial,ciad_number,ram_gb,storage_type,storage_capacity_gb,drive_serial,smart_status,erase_method,erase_result,os_installed,status,date,windows_verified"

# --- Local checks ------------------------------------------------------------
[ -f "$LOCAL_SUMMARY" ] || die "No $LOCAL_SUMMARY — check the machine label, or pull the opening session's results first."

[ "$(head -n1 "$LOCAL_SUMMARY")" = "$EXPECTED_HEADER" ] \
  || die "$LOCAL_SUMMARY doesn't have the current 13-column header — migrate it before pushing."

ROW_COUNT=$(tail -n +2 "$LOCAL_SUMMARY" | grep -c . || true)
[ "$ROW_COUNT" -eq 1 ] \
  || die "$LOCAL_SUMMARY has $ROW_COUNT rows; a per-machine summary.csv should have exactly one. Fix by hand before pushing."

LOCAL_ROW=$(sed -n 2p "$LOCAL_SUMMARY")
LOCAL_SERIAL=$(echo "$LOCAL_ROW" | awk -F',' '{print $1}' | tr -d '"')
LOCAL_CIAD=$(echo "$LOCAL_ROW" | awk -F',' '{print $2}' | tr -d '"')

# --- Remote checks -----------------------------------------------------------
# Same fresh-host-key handling as pull-results.sh (docs/ssh-access.md).
ssh-keygen -R "$TARGET_IP" >/dev/null 2>&1 || true
ssh-keyscan -t ed25519 "$TARGET_IP" >> "$HOME/.ssh/known_hosts" 2>/dev/null

SSH=(ssh -i "$KEY" "${REMOTE_USER}@${TARGET_IP}")

# Same extraction diagnostics.sh uses for machine_serial, so the two can't
# disagree on formatting. The live user has passwordless sudo on Ubuntu Live.
REMOTE_SERIAL=$("${SSH[@]}" "sudo dmidecode -t system" 2>/dev/null \
  | awk -F': ' '/Serial Number/{print $2; exit}')
[ -n "$REMOTE_SERIAL" ] || die "Could not read the target's chassis serial over SSH (sudo dmidecode -t system). Not pushing."

if [ "$REMOTE_SERIAL" != "$LOCAL_SERIAL" ]; then
  die "Target's chassis serial is $REMOTE_SERIAL, but $MACHINE_LABEL/summary.csv is for $LOCAL_SERIAL (CIAD $LOCAL_CIAD). Wrong IP or wrong label — not pushing."
fi

REMOTE_DIR_Q=$(printf '%q' "$REMOTE_RESULTS_DIR")
if "${SSH[@]}" "test -e $REMOTE_DIR_Q/summary.csv"; then
  die "${REMOTE_RESULTS_DIR}/summary.csv already exists on the target — closing diagnostics may already have run without the push. Not overwriting it. Check it (and pull it if it has anything worth keeping) before deciding what to do."
fi

# --- Push --------------------------------------------------------------------
echo "Target serial $REMOTE_SERIAL matches $MACHINE_LABEL (CIAD $LOCAL_CIAD)."
echo "Pushing $LOCAL_SUMMARY -> ${REMOTE_USER}@${TARGET_IP}:${REMOTE_RESULTS_DIR}/summary.csv"

"${SSH[@]}" "mkdir -p $REMOTE_DIR_Q"
scp -i "$KEY" "$LOCAL_SUMMARY" "${REMOTE_USER}@${TARGET_IP}:${REMOTE_RESULTS_DIR}/summary.csv"

echo ""
echo "Done. Now run closing diagnostics on the target (fetched into the same"
echo "directory that contains ${REMOTE_RESULTS_DIR}/), then pull-results.sh."
