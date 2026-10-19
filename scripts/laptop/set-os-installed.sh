#!/usr/bin/env bash
# Runs on the laptop, not a target machine. Fills the os_installed column
# (column 10) of per-machine <machine-label>/summary.csv files, which no
# other script writes (diagnostics.sh and erase-partition.sh only carry it
# over). Only touches rows with windows_verified = "verified".
#
# Two ways to pick machines:
#   --labels L1 L2 ...    these machine folders only
#   --all-verified-empty  every verified machine whose os_installed is empty
#
# Never overwrites a different non-empty value unless --force is given, so
# running the --labels pass for newer installs first and the
# --all-verified-empty pass second can't relabel them.
#
# Each file it changes is backed up as summary.csv.<timestamp>.bak first.
# Run combine-summary.sh afterwards to refresh summary-combined.csv.
#
# Caveat: pull-results.sh replaces a machine's summary.csv with the target's
# copy, which has no os_installed — re-run this after any later pull.

set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: set-os-installed.sh [--force] <os-string> --labels <machine-label>...
       set-os-installed.sh [--force] <os-string> --all-verified-empty

  os-string  e.g. "Windows 11 25H2"

Example (2026-10 batch: every machine on 25H2):
  set-os-installed.sh "Windows 11 25H2" --all-verified-empty

Reads/writes: ${LE_RELAIS_RESULTS_DIR:-<repo's parent dir>/le_relais_refurb_results}/<label>/summary.csv
USAGE
}

FORCE=0
if [ "${1:-}" = "--force" ]; then FORCE=1; shift; fi
[ "$#" -ge 2 ] || { usage; exit 1; }
OS="$1"; MODE="$2"; shift 2

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LOCAL_BASE="${LE_RELAIS_RESULTS_DIR:-$(dirname "$REPO_ROOT")/le_relais_refurb_results}"

# Keep in sync with EXPECTED_HEADER in diagnostics.sh and erase-partition.sh.
EXPECTED_HEADER="machine_serial,ciad_number,ram_gb,storage_type,storage_capacity_gb,drive_serial,smart_status,erase_method,erase_result,os_installed,status,date,windows_verified"

case "$MODE" in
  --labels)
    [ "$#" -ge 1 ] || { usage; exit 1; }
    FILES=(); for l in "$@"; do FILES+=("$LOCAL_BASE/$l/summary.csv"); done ;;
  --all-verified-empty)
    [ "$#" -eq 0 ] || { usage; exit 1; }
    FILES=("$LOCAL_BASE"/*/summary.csv) ;;
  *) usage; exit 1 ;;
esac

TS=$(date +%Y%m%d-%H%M%S)
CHANGED=0
for f in "${FILES[@]}"; do
  label=$(basename "$(dirname "$f")")
  if [ ! -f "$f" ]; then echo "SKIP $label: no summary.csv"; continue; fi
  if [ "$(head -n1 "$f")" != "$EXPECTED_HEADER" ] || [ "$(wc -l < "$f")" -ne 2 ]; then
    echo "SKIP $label: unexpected header or row count"; continue
  fi
  row=$(sed -n 2p "$f")
  nf=$(echo "$row" | awk -F',' '{print NF}')
  verified=$(echo "$row" | awk -F',' '{gsub(/"/,"",$13); print $13}')
  current=$(echo "$row" | awk -F',' '{gsub(/"/,"",$10); print $10}')
  if [ "$nf" -ne 13 ]; then echo "SKIP $label: $nf fields, expected 13"; continue; fi
  if [ "$verified" != "verified" ]; then
    [ "$MODE" = "--labels" ] && echo "SKIP $label: not windows_verified yet"
    continue
  fi
  if [ "$current" = "$OS" ]; then
    [ "$MODE" = "--labels" ] && echo "OK   $label: already $OS"
    continue
  fi
  if [ -n "$current" ]; then
    if [ "$MODE" = "--all-verified-empty" ]; then continue; fi
    if [ "$FORCE" -ne 1 ]; then
      echo "SKIP $label: os_installed is already \"$current\" (use --force to replace)"; continue
    fi
  fi
  cp -p "$f" "$f.$TS.bak"
  awk -F',' -v OFS=',' -v os="\"$OS\"" 'NR==2{$10=os} {print}' "$f" > "$f.tmp"
  cat "$f.tmp" > "$f"   # keeps the original file's permissions
  rm "$f.tmp"
  echo "SET  $label: ${current:-(empty)} -> $OS"
  CHANGED=$((CHANGED+1))
done

echo "$CHANGED file(s) changed (backups: summary.csv.$TS.bak). Run combine-summary.sh next."
