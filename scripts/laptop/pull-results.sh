#!/usr/bin/env bash
# Runs on the laptop, not a target machine — not part of the
# raw.githubusercontent.com delivery path (CLAUDE.md, "Delivery to target
# machines"). Pulls one machine's results/ (diag_*.txt + erase_*.txt +
# summary.csv) from an Ubuntu Live session over SSH, per docs/ssh-access.md.
#
# Does NOT merge pulled summary.csv rows into a single master file across
# machines/sessions — that merge strategy is still an open decision
# (CLAUDE.md, "Open items"). Each pull is kept separate, under the source
# machine's IP, so nothing is silently combined or overwritten until that's
# settled.

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

KEY="$HOME/.ssh/id_ed25519_refurb"
LOCAL_BASE="${LE_RELAIS_RESULTS_DIR:-$DEFAULT_RESULTS_DIR}"
LOCAL_DEST="$LOCAL_BASE/$MACHINE_LABEL"

mkdir -p "$LOCAL_DEST"

# Each live-session boot has a fresh, unpersisted host key (docs/ssh-access.md,
# "REMOTE HOST IDENTIFICATION HAS CHANGED"), and the interactive accept prompt
# for a new key doesn't reliably get answered when scp runs nested in a
# script (confirmed 2026-09-28) — so replace whatever's cached for this IP
# with a freshly scanned key every time, non-interactively.
ssh-keygen -R "$TARGET_IP" >/dev/null 2>&1 || true
ssh-keyscan -t ed25519 "$TARGET_IP" >> "$HOME/.ssh/known_hosts" 2>/dev/null

echo "Pulling from ${REMOTE_USER}@${TARGET_IP}:${REMOTE_RESULTS_DIR}/ -> $LOCAL_DEST"

if ! scp -i "$KEY" "${REMOTE_USER}@${TARGET_IP}:${REMOTE_RESULTS_DIR}/diag_*.txt" "$LOCAL_DEST/" 2>/dev/null; then
  echo "No diag_*.txt matched (fine if this pull is erase-only, or that stage hasn't run yet)."
fi

# erase-partition.sh names its report erase_${MACHINE_ID}_${CIAD_NUMBER}.txt
# — a different prefix from diagnostics.sh's diag_*.txt, so it needs its own
# glob. (Bug fixed 2026-09-28: this script only ever fetched diag_*.txt,
# so an erase-only pull silently came back with nothing — not an SSH or
# results/ path problem, just a missing pattern here.)
if ! scp -i "$KEY" "${REMOTE_USER}@${TARGET_IP}:${REMOTE_RESULTS_DIR}/erase_*.txt" "$LOCAL_DEST/" 2>/dev/null; then
  echo "No erase_*.txt matched (fine if this pull is diagnostics-only, or that stage hasn't run yet)."
fi

SUMMARY_DEST="$LOCAL_DEST/summary.csv.${TARGET_IP}"
scp -i "$KEY" "${REMOTE_USER}@${TARGET_IP}:${REMOTE_RESULTS_DIR}/summary.csv" "$SUMMARY_DEST"

echo ""
echo "Done."
echo "Logs        : $LOCAL_DEST (diag_*.txt and/or erase_*.txt, whichever stages have run)"
echo "Summary rows: $SUMMARY_DEST (per-source-IP, not merged into a master file)"
