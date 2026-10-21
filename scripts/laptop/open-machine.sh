#!/usr/bin/env bash
# Runs on the laptop, not a target machine — not part of the
# raw.githubusercontent.com delivery path (CLAUDE.md, "Delivery to target
# machines"). Drives one machine's opening pass (toolkit-reference.md steps
# 2–4) over SSH, after enable-ssh.sh (v16+) has been run at the target's
# own keyboard:
#
#   1. Session code from the target's screen → the IP is that machine.
#   2. Identity (machine number, asset tag) typed at the target, checked
#      against its chassis serial.
#   3. Identity checked against the laptop's records (no number, tag or
#      serial under two machines).
#   4. Target's own results/ checked: nothing from another machine, not a
#      machine at closing stage.
#   5. diagnostics.sh + erase-partition.sh fetched at <repo-tag>, checked against
#      this repo's copy of the tag.
#   6. Opening diagnostics.
#   7. Suspend to RAM and back (rtcwake), then erase-partition.sh in a
#      screen session on the target: survives a
#      dropped connection or a sleeping laptop; re-running this script
#      re-attaches. The erase's own checks and prompts are unchanged — you
#      pick the disk and type the drive serial.
#   8. pull-results.sh.
#
# Nothing here erases anything by itself: the only path to an erase is
# erase-partition.sh's typed drive-serial confirmation.

set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: open-machine.sh <target-ip|user@target-ip> <repo-tag>

  target-ip  the IP on the identity card enable-ssh.sh printed on the target
  repo-tag   the repo tag (not the asset tag) to fetch diagnostics.sh /
             erase-partition.sh from (e.g. v17) — must exist in this repo;
             hashes are computed from it

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

ask_yes() {  # ask_yes "question" default(y|n)
  local answer
  read -rp "$1 " answer || die "No answer (end of input) — stopping."
  answer="${answer:-$2}"
  [[ "$answer" =~ ^[Yy] ]]
}

echo "=== 1. Session code ==="
verify_host "$TARGET_IP"

echo "=== 2. Identity typed at the target ==="
read_identity
print_identity

echo "=== 3. Laptop records ==="
registry_check_opening
FOLDER="$RESULTS_BASE/$ID_ASSET"
if [ -d "$FOLDER" ]; then
  echo "Folder $ID_ASSET exists and agrees with this machine (re-run of an opening pass)."
else
  echo "New machine: no folder for $ID_ASSET yet, number and serial not used elsewhere."
fi

echo "=== 4. Target's own results ==="
DIAG_LOG="diag_${ID_NUMBER}_${ID_ASSET}_before.txt"
DIAG_DONE=0
REMOTE_SUMMARY=$(rsh 'cat results/summary.csv 2>/dev/null' || true)
if [ -n "$REMOTE_SUMMARY" ]; then
  ROWS=$(tail -n +2 <<<"$REMOTE_SUMMARY" | grep -c . || true)
  ROW=$(sed -n 2p <<<"$REMOTE_SUMMARY")
  ROW_SERIAL=$(awk -F',' '{print $1}' <<<"$ROW" | tr -d '"')
  ROW_CIAD=$(awk -F',' '{print $2}' <<<"$ROW" | tr -d '"')
  ROW_STATUS=$(awk -F',' '{print $11}' <<<"$ROW" | tr -d '"')
  ROW_VERIFIED=$(awk -F',' '{print $13}' <<<"$ROW" | tr -d '"')
  [ "$ROWS" -eq 1 ] || die "The target's results/summary.csv has $ROWS rows; expected one. Look at it before going on."
  [ "$ROW_SERIAL" = "$ID_SERIAL" ] || die "The target's results/summary.csv is for serial $ROW_SERIAL, not this machine ($ID_SERIAL)."
  [ "$ROW_CIAD" = "$ID_ASSET" ] || die "The target's results/summary.csv is for CIAD $ROW_CIAD, but $ID_ASSET was typed at the target."
  if [ "$ROW_STATUS" = "GREEN" ] || [ -n "$ROW_VERIFIED" ]; then
    die "The target's summary.csv shows a closing pass (status $ROW_STATUS, windows_verified '$ROW_VERIFIED'). This machine is at closing stage — use close-machine.sh, not an opening pass."
  fi
  if rsh "test -f results/$DIAG_LOG"; then
    DIAG_DONE=1
  fi
  echo "Results from earlier in this session agree with this machine (status: ${ROW_STATUS:-<blank>})."
else
  echo "None yet."
fi

# Recorded before anything runs, so close-machine.sh can check the closing
# pass against what was typed at the opening one.
mkdir -p "$FOLDER"
{
  echo "MACHINE_NUMBER=$ID_NUMBER"
  echo "ASSET_TAG=$ID_ASSET"
  echo "CHASSIS_SERIAL=$ID_SERIAL"
  echo "OPENED=$(date -Iseconds)"
  echo "TAG=$TAG"
} > "$FOLDER/identity-opening.env"

echo "=== 5. Fetch target scripts at $TAG ==="
fetch_verified "$TAG" diagnostics.sh erase-partition.sh

echo "=== 6. Opening diagnostics ==="
if [ "$DIAG_DONE" -eq 1 ] && ! ask_yes "Opening diagnostics already ran in this session. Run them again? [y/N]" n; then
  echo "Skipped."
else
  run_diagnostics before
  rsh "test -f results/$DIAG_LOG" || die "diagnostics.sh didn't leave results/$DIAG_LOG. Read its output above."
fi

echo "=== 7. Erase ==="
screen_running() {
  rsh 'screen -ls erase' 2>/dev/null | grep -qE '[0-9]+\.erase[[:space:]]'
}
# Suspend to RAM and back before every erase. A resume resets the SATA link
# without a POST, so the BIOS doesn't reissue its freeze lock (SATA SSD
# FROZEN, methodology.md §4.3; it also cleared the NVMe 0x2001 rejection on
# 032). rtcwake sets an RTC alarm so the target wakes by itself; the kernel's
# suspend counter going up is the proof a suspend really happened.
suspend_resume() {
  local mode before after
  mode=$(rsh 'cat /sys/power/mem_sleep' 2>/dev/null || true)
  echo "Sleep modes on the target: ${mode:-<unknown>}"
  if [[ "$mode" != *"[deep]"* ]]; then
    echo "WARNING: [deep] (S3) isn't selected, so the drive may not be reset. erase-partition.sh will stop if it's still frozen."
  fi
  before=$(rsh 'cat /sys/power/suspend_stats/success' 2>/dev/null || true)
  [[ "$before" =~ ^[0-9]+$ ]] || die "Couldn't read the target's suspend count. Nothing was erased."
  # Started 2 s later by systemd, so this ssh call returns before the network goes down.
  rsh 'sudo systemd-run --quiet --on-active=2 rtcwake -m mem -s 30' \
    || die "Couldn't start the suspend on the target. Nothing was erased."
  echo "Target suspending for about 30 s. If it hasn't woken after a minute, press its power button."
  sleep 10
  for _ in $(seq 1 30); do
    after=$(ssh "${SSH_OPTS[@]}" -o ConnectTimeout=5 -n "$REMOTE_USER@$TARGET_IP" \
      'cat /sys/power/suspend_stats/success' 2>/dev/null || true)
    if [[ "$after" =~ ^[0-9]+$ ]] && [ "$after" -gt "$before" ]; then
      echo "Target suspended and resumed (suspend count $before -> $after)."
      return 0
    fi
    sleep 5
  done
  die "The target didn't come back from suspend over SSH. Wake it with the power button, check its network, and re-run this script. Nothing was erased."
}
while :; do
  if screen_running; then
    echo "An erase is already running on the target — re-attaching."
  else
    ask_yes "Start erase-partition.sh on the target now? [Y/n]" y || break
    suspend_resume
  fi
  echo "To watch or type at the target's console instead, run there:  screen -x erase"
  echo "To leave it running and come back later: Ctrl-A then D, and re-run this script."
  # Attach to the running session (-x: shared with the console if that's
  # attached too), or start it. The inner bash keeps the window open after
  # the erase ends, so its last lines can be read.
  ssh -t "${SSH_OPTS[@]}" "$REMOTE_USER@$TARGET_IP" \
    "if screen -ls erase | grep -qE '[0-9]+\.erase[[:space:]]'; then screen -x erase; else screen -S erase bash -c 'bash erase-partition.sh; echo; echo \"erase-partition.sh finished (exit \$?). Press Enter to close.\"; read -r _'; fi" || true
  if screen_running; then
    echo ""
    echo "The erase is still running on the target (detached or connection lost)."
    echo "Re-run this script with the same arguments to re-attach. Not pulling yet."
    exit 0
  fi
  echo "Each run must end with: exit=0, verify=pass, partition=ok."
  ask_yes "Erase another disk on this machine? [y/N]" n || break
done

echo "=== 8. Pull results ==="
"$SCRIPT_DIR/pull-results.sh" "$REMOTE_USER@$TARGET_IP" "$ID_ASSET"

ERASE_RESULT=$(summary_field "$FOLDER/summary.csv" 9)
echo ""
echo "Machine $ID_NUMBER / $ID_ASSET — erase_result: ${ERASE_RESULT:-<blank>}"
if [ "$ERASE_RESULT" != "pass" ]; then
  echo "WARNING: not ready for the Windows install. Finish the erase (every disk) and re-run this script."
fi
