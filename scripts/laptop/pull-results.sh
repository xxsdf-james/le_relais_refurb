#!/usr/bin/env bash
# Runs on the laptop, not a target machine — not part of the
# raw.githubusercontent.com delivery path (CLAUDE.md, "Delivery to target
# machines"). Pulls one machine's results/ (diag_*.txt + summary.csv) from
# an Ubuntu Live session over SSH, per docs/ssh-access.md.
#
# Does NOT merge pulled summary.csv rows into a single master file across
# machines/sessions — that merge strategy is still an open decision
# (CLAUDE.md, "Open items"). Each pull is kept separate, under the source
# machine's IP, so nothing is silently combined or overwritten until that's
# settled.

set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: pull-results.sh <target-ip> <machine-label> [remote-user] [remote-results-dir]

  target-ip           e.g. 192.168.8.18
  machine-label       local folder name to file this machine's results under
  remote-user         default: ubuntu
  remote-results-dir  default: results (relative to the remote user's home,
                       resolved by the SFTP server — safe regardless of scp's
                       own tilde-expansion behavior). diagnostics.sh prints
                       the exact absolute path at the end of its run
                       ("Summary row in: ...") if this default doesn't match.

Local destination: ${LE_RELAIS_RESULTS_DIR:-$HOME/le-relais-results}/<machine-label>/
Never the repo — see CLAUDE.md, "Repo layout": real results don't go in git.
USAGE
}

if [ "$#" -lt 2 ]; then
  usage
  exit 1
fi

TARGET_IP="$1"
MACHINE_LABEL="$2"
REMOTE_USER="${3:-ubuntu}"
REMOTE_RESULTS_DIR="${4:-results}"

KEY="$HOME/.ssh/id_ed25519_refurb"
LOCAL_BASE="${LE_RELAIS_RESULTS_DIR:-$HOME/le-relais-results}"
LOCAL_DEST="$LOCAL_BASE/$MACHINE_LABEL"

mkdir -p "$LOCAL_DEST"

echo "Pulling from ${REMOTE_USER}@${TARGET_IP}:${REMOTE_RESULTS_DIR}/ -> $LOCAL_DEST"

if ! scp -i "$KEY" "${REMOTE_USER}@${TARGET_IP}:${REMOTE_RESULTS_DIR}/diag_*.txt" "$LOCAL_DEST/" 2>/dev/null; then
  echo "No diag_*.txt matched (fine if this pull is erase-only, or that stage hasn't run yet)."
fi

SUMMARY_DEST="$LOCAL_DEST/summary.csv.${TARGET_IP}"
scp -i "$KEY" "${REMOTE_USER}@${TARGET_IP}:${REMOTE_RESULTS_DIR}/summary.csv" "$SUMMARY_DEST"

echo ""
echo "Done."
echo "Logs        : $LOCAL_DEST"
echo "Summary rows: $SUMMARY_DEST (per-source-IP, not merged into a master file)"
