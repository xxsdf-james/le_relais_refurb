#!/usr/bin/env bash
# Runs on the laptop, not a target machine — not part of the
# raw.githubusercontent.com delivery path (CLAUDE.md, "Delivery to target
# machines"). Drives one machine's closing pass (toolkit-reference.md steps
# 11–12) over SSH, after enable-ssh.sh (v16+) has been run at the target's
# own keyboard on the fresh live boot:
#
#   1. Session code from the target's screen → the IP is that machine.
#   2. Identity typed at the target, checked against its chassis serial.
#   3. That identity checked against what open-machine.sh recorded at the
#      opening pass: chassis serial, machine number and asset tag must all
#      agree. Each disagreement is reported on its own line.
#   4. diagnostics.sh fetched at <repo-tag>, checked against this repo's copy.
#   5. push-summary.sh (its own serial / one-row / no-overwrite checks).
#   6. Closing diagnostics.
#   7. pull-results.sh — its GREEN / not-GREEN verdict is the final word.
#
# Only for machines opened with open-machine.sh (they have
# identity-opening.env). Machines opened before v16: v15 manual steps.

set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: close-machine.sh <target-ip|user@target-ip> <repo-tag>

  target-ip  the IP on the identity card enable-ssh.sh printed on the target
  repo-tag   the repo tag (not the asset tag) to fetch diagnostics.sh from (e.g. v17)

Run enable-ssh.sh at the target's keyboard first. You'll be asked for the
session code on its screen.
USAGE
}

if [ "$#" -ne 2 ]; then
  usage
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-target.sh
source "$SCRIPT_DIR/lib-target.sh"

parse_target "$1"
TAG="$2"
check_tag "$TAG"

echo "=== 1. Session code ==="
verify_host "$TARGET_IP"

echo "=== 2. Identity typed at the target ==="
read_identity
print_identity

echo "=== 3. Opening record ==="
FOLDER="$RESULTS_BASE/$ID_ASSET"
if [ ! -d "$FOLDER" ]; then
  for dir in "$RESULTS_BASE"/*/; do
    if [ -f "$dir/summary.csv" ] && [ "$(summary_field "$dir/summary.csv" 1)" = "$ID_SERIAL" ]; then
      die "No folder for asset tag $ID_ASSET, but this machine (serial $ID_SERIAL) is on record as $(basename "$dir"). Asset tag mistyped at the target? Re-run enable-ssh.sh there."
    fi
  done
  die "No folder for asset tag $ID_ASSET, and serial $ID_SERIAL isn't on record anywhere. Check the sticker and re-run enable-ssh.sh at the target."
fi
OPENING="$FOLDER/identity-opening.env"
[ -f "$OPENING" ] || die "$ID_ASSET was opened before v16 (no identity-opening.env). Close it with the v15 manual steps."
[ -f "$FOLDER/summary.csv" ] || die "$ID_ASSET has no summary.csv — the opening pull never happened?"

OPEN_NUMBER=$(sed -n 's/^MACHINE_NUMBER=//p' "$OPENING")
OPEN_SERIAL=$(sed -n 's/^CHASSIS_SERIAL=//p' "$OPENING")
REC_SERIAL=$(summary_field "$FOLDER/summary.csv" 1)
REC_CIAD=$(summary_field "$FOLDER/summary.csv" 2)
REC_ERASE=$(summary_field "$FOLDER/summary.csv" 9)

PROBLEMS=()
[ "$ID_SERIAL" = "$REC_SERIAL" ] \
  || PROBLEMS+=("Chassis serial: this machine is $ID_SERIAL, $ID_ASSET was opened as $REC_SERIAL — not the same machine.")
[ "$ID_NUMBER" = "$OPEN_NUMBER" ] \
  || PROBLEMS+=("Machine number: $ID_NUMBER typed at the target, $ID_ASSET was opened as $OPEN_NUMBER.")
[ "$ID_ASSET" = "$REC_CIAD" ] \
  || PROBLEMS+=("Asset tag: summary.csv records CIAD $REC_CIAD for folder $ID_ASSET.")
[ "$OPEN_SERIAL" = "$REC_SERIAL" ] \
  || PROBLEMS+=("Laptop records disagree: identity-opening.env says serial $OPEN_SERIAL, summary.csv says $REC_SERIAL.")
[ "$REC_ERASE" = "pass" ] \
  || PROBLEMS+=("The opening record's erase_result is '${REC_ERASE:-<blank>}', not pass.")
if [ "${#PROBLEMS[@]}" -gt 0 ]; then
  printf '  - %s\n' "${PROBLEMS[@]}" >&2
  die "Closing pass refused (above). Nothing was sent to the target."
fi
echo "Serial, machine number and asset tag all match the opening record."

echo "=== 4. Fetch diagnostics.sh at $TAG ==="
fetch_verified "$TAG" diagnostics.sh

echo "=== 5. Push the opening summary.csv ==="
# A re-run after the push but before closing diagnostics finds the same
# file already there; anything else is push-summary.sh's to refuse.
REMOTE_SUMMARY=$(rsh 'cat results/summary.csv 2>/dev/null' || true)
if [ -n "$REMOTE_SUMMARY" ] && [ "$REMOTE_SUMMARY" = "$(cat "$FOLDER/summary.csv")" ]; then
  echo "Already pushed in this session."
else
  "$SCRIPT_DIR/push-summary.sh" "$REMOTE_USER@$TARGET_IP" "$ID_ASSET"
fi

echo "=== 6. Closing diagnostics ==="
run_diagnostics after

echo "=== 7. Pull results ==="
"$SCRIPT_DIR/pull-results.sh" "$REMOTE_USER@$TARGET_IP" "$ID_ASSET"
