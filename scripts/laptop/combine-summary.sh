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

shopt -s nullglob
FILES=("$LOCAL_BASE"/*/summary.csv)
[ "${#FILES[@]}" -gt 0 ] || { echo "ERROR: no */summary.csv under $LOCAL_BASE" >&2; exit 1; }

PROBLEMS=0
TMP_OUT=$(mktemp)
echo "$EXPECTED_HEADER" > "$TMP_OUT"
declare -A SEEN_SERIAL

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
  echo "$row" >> "$TMP_OUT"
done

if [ "$PROBLEMS" -gt 0 ]; then
  rm -f "$TMP_OUT"
  echo "" >&2
  echo "$PROBLEMS problem(s) — nothing written. Fix them and re-run." >&2
  exit 1
fi

mv "$TMP_OUT" "$OUTPUT"
echo "Wrote $OUTPUT ($(( $(wc -l < "$OUTPUT") - 1 )) machines)."
