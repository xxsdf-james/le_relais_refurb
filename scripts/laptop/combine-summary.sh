#!/usr/bin/env bash
# Runs on the laptop, not a target machine. Stacks every per-machine
# <machine-label>/summary.csv (written by pull-results.sh) under the results
# directory into one CSV: one header, one row per machine. No merging logic —
# each machine's single row is already complete, because push-summary.sh
# sends the opening row back before closing diagnostics updates it.
#
# Refuses to write the output if any machine file has the wrong header or
# not exactly one row, or if the same machine_serial appears in more than
# one folder (e.g. the same machine pulled under two different labels).
#
# Appends two columns the per-machine files don't have: wifi_card (yes / no /
# unknown), read from the lspci and lshw output in that folder's diag_*.txt
# logs, and machine_number, the 3-digit number typed as "Machine ID/label"
# into diagnostics.sh / erase-partition.sh, read from the diag_*/erase_*
# log filenames. They're only in the combined file, so the per-machine schema
# shared with diagnostics.sh and erase-partition.sh is unchanged.
#
# Also refuses if a folder's logs carry more than one machine_number, or the
# same number appears in more than one folder.

set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: combine-summary.sh [output-file]

  output-file  default: <results dir>/summary-combined.csv

Reads: ${LE_RELAIS_RESULTS_DIR:-<repo's parent dir>/le_relais_refurb_results}/*/summary.csv
USAGE
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DEFAULT_RESULTS_DIR="$(dirname "$REPO_ROOT")/le_relais_refurb_results"

LOCAL_BASE="${LE_RELAIS_RESULTS_DIR:-$DEFAULT_RESULTS_DIR}"
OUTPUT="${1:-$LOCAL_BASE/summary-combined.csv}"

# Keep in sync with EXPECTED_HEADER in diagnostics.sh and erase-partition.sh.
EXPECTED_HEADER="machine_serial,ciad_number,ram_gb,storage_type,storage_capacity_gb,drive_serial,smart_status,erase_method,erase_result,os_installed,status,date,windows_verified"

# Combined file only — not part of the per-machine schema above.
COMBINED_HEADER="$EXPECTED_HEADER,wifi_card,machine_number"

# yes:     lspci lists a "Network controller" (the PCI class Wi-Fi cards use;
#          wired cards are "Ethernet controller"), or lshw lists a network-class
#          device described as wireless (also catches USB Wi-Fi adapters).
#          Bluetooth is lshw class "communication", so it doesn't count.
# no:      the logs list wired network hardware but nothing wireless, so the
#          scan ran and found no card.
# unknown: no diag log, or no network hardware listed at all (e.g. lspci/lshw
#          missing because the live session couldn't install them). Never
#          reported as "no", since nothing was actually checked.
# A card disabled in the BIOS doesn't show up in lspci/lshw and reads as "no".
wifi_card() {
  local dir="$1" logs
  logs=("$dir"/diag_*.txt)
  [ "${#logs[@]}" -gt 0 ] || { echo unknown; return; }
  if cat "${logs[@]}" | grep -qE '^[0-9a-f:.]+ Network controller:' \
     || cat "${logs[@]}" | grep -E '^/[^ ]* +([^ ]+ +)?network ' | grep -qiE 'wireless|wi-fi|wlan|802\.11'; then
    echo yes
  elif cat "${logs[@]}" | grep -qE '^[0-9a-f:.]+ Ethernet controller:|^/[^ ]* +([^ ]+ +)?network '; then
    echo no
  else
    echo unknown
  fi
}

# Prints the distinct 3-digit numbers in the folder's log filenames
# (diag_<NNN>_<CIAD>_<stage>.txt, erase_<NNN>_<CIAD>.txt), one per line.
# Exactly one is expected; none or several is reported by the caller.
machine_numbers() {
  local dir="$1" f
  for f in "$dir"/diag_*.txt "$dir"/erase_*.txt; do
    basename "$f"
  done | sed -nE 's/^(diag|erase)_([0-9]{3})_.*\.txt$/\2/p' | sort -u
}

shopt -s nullglob
FILES=("$LOCAL_BASE"/*/summary.csv)
[ "${#FILES[@]}" -gt 0 ] || { echo "ERROR: no */summary.csv under $LOCAL_BASE" >&2; exit 1; }

PROBLEMS=0
TMP_OUT=$(mktemp)
echo "$COMBINED_HEADER" > "$TMP_OUT"
declare -A SEEN_SERIAL
declare -A SEEN_NUMBER

for f in "${FILES[@]}"; do
  label=$(basename "$(dirname "$f")")
  if [ "$(head -n1 "$f")" != "$EXPECTED_HEADER" ]; then
    echo "PROBLEM: $label — header doesn't match the current 13-column schema." >&2
    PROBLEMS=$((PROBLEMS + 1))
    continue
  fi
  rows=$(tail -n +2 "$f" | grep -c . || true)
  if [ "$rows" -ne 1 ]; then
    echo "PROBLEM: $label — $rows rows (expected exactly 1)." >&2
    PROBLEMS=$((PROBLEMS + 1))
    continue
  fi
  row=$(sed -n 2p "$f")
  serial=$(echo "$row" | awk -F',' '{print $1}' | tr -d '"')
  if [ -n "${SEEN_SERIAL[$serial]:-}" ]; then
    echo "PROBLEM: machine_serial $serial is in both ${SEEN_SERIAL[$serial]} and $label — same machine under two labels?" >&2
    PROBLEMS=$((PROBLEMS + 1))
    continue
  fi
  SEEN_SERIAL[$serial]="$label"
  numbers=$(machine_numbers "$(dirname "$f")")
  if [ "$(echo "$numbers" | grep -c .)" -gt 1 ]; then
    echo "PROBLEM: $label — logs carry more than one machine number: $(echo $numbers)." >&2
    PROBLEMS=$((PROBLEMS + 1))
    continue
  fi
  number="$numbers"
  if [ -z "$number" ]; then
    echo "NOTE: $label — machine_number blank (no diag_<NNN>_* / erase_<NNN>_* log in the folder)." >&2
  elif [ -n "${SEEN_NUMBER[$number]:-}" ]; then
    echo "PROBLEM: machine number $number is in both ${SEEN_NUMBER[$number]} and $label — typo when entering the label?" >&2
    PROBLEMS=$((PROBLEMS + 1))
    continue
  else
    SEEN_NUMBER[$number]="$label"
  fi
  wifi=$(wifi_card "$(dirname "$f")")
  [ "$wifi" != unknown ] || echo "NOTE: $label — wifi_card unknown (no diag log, or no network hardware listed in it)." >&2
  echo "$row,\"$wifi\",\"$number\"" >> "$TMP_OUT"
done

if [ "$PROBLEMS" -gt 0 ]; then
  rm -f "$TMP_OUT"
  echo "" >&2
  echo "$PROBLEMS problem(s) — nothing written. Fix them and re-run." >&2
  exit 1
fi

mv "$TMP_OUT" "$OUTPUT"
echo "Wrote $OUTPUT ($(( $(wc -l < "$OUTPUT") - 1 )) machines)."
