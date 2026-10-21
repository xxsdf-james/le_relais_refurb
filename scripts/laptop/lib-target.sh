#!/usr/bin/env bash
# lib-target.sh — sourced, not run, by the other scripts in scripts/laptop/.
# Runs on the laptop, not a target machine — not part of the
# raw.githubusercontent.com delivery path (CLAUDE.md, "Delivery to target
# machines").
#
# Identity checks for talking to a target's Ubuntu Live session over SSH:
#   - Session code: enable-ssh.sh (v16+) prints the first 6 hex characters
#     of the SHA-256 of that boot's ed25519 host key on the target's screen.
#     verify_host computes the same code from the key that actually answers
#     at the IP, and asks for it. A match proves the IP is the machine whose
#     screen you read. The key is then pinned (one file per IP under
#     <results dir>/.known_hosts/), and every later ssh/scp refuses any other
#     key (StrictHostKeyChecking=yes) — a new boot or a different machine at
#     that IP means typing the new code, never a silent re-scan.
#   - read_identity: the machine number / asset tag typed at the target's
#     keyboard (results/identity.env), checked against the chassis serial
#     dmidecode reads now.
#   - registry_check_opening: the laptop's own records, so a number, asset
#     tag or chassis serial can't end up under two machines.
#   - fetch_verified: target scripts fetched at a tag and checked against
#     hashes computed from this repo's own copy of that tag.

REFURB_KEY="$HOME/.ssh/id_ed25519_refurb"
RAW_BASE="https://raw.githubusercontent.com/xxsdf-james/le_relais_refurb/refs/tags"
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_REPO_ROOT="$(cd "$LIB_DIR/../.." && pwd)"
RESULTS_BASE="${LE_RELAIS_RESULTS_DIR:-$(dirname "$LIB_REPO_ROOT")/le_relais_refurb_results}"
PIN_DIR="$RESULTS_BASE/.known_hosts"

declare -F die >/dev/null || die() {
  echo "ERROR: $*" >&2
  exit 1
}

# Sets REMOTE_USER and TARGET_IP from "ip" or "user@ip".
parse_target() {
  if [[ "$1" == *"@"* ]]; then
    REMOTE_USER="${1%%@*}"
    TARGET_IP="${1#*@}"
  else
    REMOTE_USER="ubuntu"
    TARGET_IP="$1"
  fi
  [[ "$TARGET_IP" =~ ^[0-9A-Za-z.:-]+$ ]] || die "'$TARGET_IP' doesn't look like an IP address."
}

# --- Session code and host-key pinning ----------------------------------------

# Prints the target's ed25519 key as a known_hosts line ("ip ssh-ed25519 AAAA...").
scan_key() {
  ssh-keyscan -t ed25519 "$1" 2>/dev/null | grep -v '^#' | head -n1
}

# Same computation as enable-ssh.sh: SHA-256 of the raw key blob, first 6 hex.
session_code() {
  awk '{print $3}' <<<"$1" | base64 -d | sha256sum | cut -c1-6 | tr '[:lower:]' '[:upper:]'
}

# Last 6 characters of the "SHA256:..." fingerprint ssh-keygen -l prints —
# for a target whose enable-ssh.sh predates v16 and shows no session code.
fingerprint_tail() {
  local fp
  fp=$(ssh-keygen -lf - <<<"$1" | awk '{print $2}')
  echo "${fp: -6}"
}

set_ssh_opts() {
  SSH_OPTS=(-i "$REFURB_KEY" -o IdentitiesOnly=yes -o BatchMode=yes
            -o HostKeyAlgorithms=ssh-ed25519 -o StrictHostKeyChecking=yes
            -o UserKnownHostsFile="$PIN_DIR/$1" -o GlobalKnownHostsFile=/dev/null)
}

# Asks for the session code shown on the target's screen; pins the key on a match.
verify_host() {
  local ip="$1" scan code fp_tail typed attempt
  scan=$(scan_key "$ip")
  [ -n "$scan" ] || die "No SSH answer from $ip. Has enable-ssh.sh finished on the target? Is the IP right?"
  code=$(session_code "$scan")
  fp_tail=$(fingerprint_tail "$scan")
  for attempt in 1 2 3; do
    read -rp "Session code on the target's screen (for $ip): " typed \
      || die "No answer (end of input) — stopping. Run this in a terminal, not with !. Nothing was sent to $ip."
    typed=$(echo "$typed" | tr -d '[:space:]')
    if [ "$(echo "$typed" | tr '[:lower:]' '[:upper:]')" = "$code" ] || [ "$typed" = "$fp_tail" ]; then
      mkdir -p "$PIN_DIR"
      echo "$scan" > "$PIN_DIR/$ip"
      set_ssh_opts "$ip"
      echo "Session code matches: $ip is the machine whose screen you read."
      return 0
    fi
    echo "That doesn't match the machine answering at $ip (attempt $attempt of 3)."
  done
  echo "No session code on the target (enable-ssh.sh older than v16)? Run this there:" >&2
  echo "  ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub" >&2
  echo "and type the last 6 characters of its SHA256:... value instead." >&2
  die "Session code didn't match. Check the IP on the target's screen. Nothing was sent to $ip."
}

# Uses the pinned key if the machine at the IP still presents it; otherwise
# (no pin yet, new boot, different machine) asks for the session code.
ensure_host() {
  local ip="$1" scan
  if [ -f "$PIN_DIR/$ip" ]; then
    scan=$(scan_key "$ip")
    if [ -n "$scan" ] && [ "$(awk '{print $2, $3}' <<<"$scan")" = "$(awk '{print $2, $3}' "$PIN_DIR/$ip")" ]; then
      set_ssh_opts "$ip"
      return 0
    fi
    echo "The machine at $ip no longer presents the key verified earlier (new boot, or a different machine)."
  fi
  verify_host "$ip"
}

# Runs a command on the target. -n: never reads the laptop's stdin, so it
# can't swallow answers meant for a prompt in the calling script.
rsh() {
  ssh "${SSH_OPTS[@]}" -n "$REMOTE_USER@$TARGET_IP" "$@"
}

# --- Identity --------------------------------------------------------------------

# Sets ID_NUMBER, ID_ASSET, ID_SERIAL from the target's results/identity.env,
# and checks the serial against what dmidecode reads now.
read_identity() {
  local content live_serial
  content=$(rsh 'cat results/identity.env' 2>/dev/null) \
    || die "No results/identity.env on the target. Run enable-ssh.sh (v16 or later) there first."
  ID_NUMBER=$(sed -n 's/^MACHINE_NUMBER=//p' <<<"$content")
  ID_ASSET=$(sed -n 's/^ASSET_TAG=//p' <<<"$content")
  ID_SERIAL=$(sed -n 's/^CHASSIS_SERIAL=//p' <<<"$content")
  [[ "$ID_NUMBER" =~ ^[0-9]{3}$ ]] || die "Target's identity.env has a malformed machine number '$ID_NUMBER'. Re-run enable-ssh.sh there."
  [[ "$ID_ASSET" =~ ^[A-Z0-9]{3,12}$ ]] || die "Target's identity.env has a malformed asset tag '$ID_ASSET'. Re-run enable-ssh.sh there."
  { [ -n "$ID_SERIAL" ] && [ "$ID_SERIAL" != "unknown" ]; } \
    || die "The target couldn't read its chassis serial, so it can't be matched to a record. Do this machine by hand."
  live_serial=$(rsh 'sudo dmidecode -t system' 2>/dev/null | awk -F': ' '/Serial Number/{print $2; exit}' || true)
  [ "$live_serial" = "$ID_SERIAL" ] \
    || die "Target's identity.env is for chassis serial $ID_SERIAL, but the machine reads $live_serial now. Re-run enable-ssh.sh there."
}

print_identity() {
  echo ""
  echo "  Machine number : $ID_NUMBER"
  echo "  Asset tag      : $ID_ASSET"
  echo "  Chassis serial : $ID_SERIAL"
  echo ""
}

# --- Laptop records ----------------------------------------------------------------

# Prints the distinct 3-digit numbers in the folder's log filenames
# (diag_<NNN>_<CIAD>_<stage>.txt, erase_<NNN>_<CIAD>.txt), one per line.
# Exactly one is expected; none or several is reported by the caller.
machine_numbers() {
  local dir="$1" f
  for f in "$dir"/diag_*.txt "$dir"/erase_*.txt; do
    if [ -e "$f" ]; then basename "$f"; fi
  done | sed -nE 's/^(diag|erase)_([0-9]{3})_.*\.txt$/\2/p' | sort -u
}

# Column N of a per-machine summary.csv's single row, quotes stripped.
summary_field() {
  sed -n 2p "$1" | awk -F',' -v c="$2" '{print $c}' | tr -d '"'
}

# Opening pass: the number, asset tag and serial must be new to every other
# folder, and agree with this asset tag's own folder if it already exists.
registry_check_opening() {
  local dir name problems=() nums
  for dir in "$RESULTS_BASE"/*/; do
    name=$(basename "$dir")
    [ "$name" = "$ID_ASSET" ] && continue
    if [ -f "$dir/summary.csv" ] && [ "$(summary_field "$dir/summary.csv" 1)" = "$ID_SERIAL" ]; then
      problems+=("This machine (serial $ID_SERIAL) is already on record under asset tag $name.")
    fi
    if machine_numbers "$dir" | grep -qx "$ID_NUMBER"; then
      problems+=("Machine number $ID_NUMBER is already used by $name.")
    fi
  done
  dir="$RESULTS_BASE/$ID_ASSET"
  if [ -f "$dir/summary.csv" ] && [ "$(summary_field "$dir/summary.csv" 1)" != "$ID_SERIAL" ]; then
    problems+=("Folder $ID_ASSET is for serial $(summary_field "$dir/summary.csv" 1), but this machine's is $ID_SERIAL.")
  fi
  nums=$(machine_numbers "$dir" | tr '\n' ' ')
  if [ -n "$nums" ] && [ "$nums" != "$ID_NUMBER " ]; then
    problems+=("Folder $ID_ASSET's logs are for machine number ${nums% }, not $ID_NUMBER.")
  fi
  if [ "${#problems[@]}" -gt 0 ]; then
    printf '  - %s\n' "${problems[@]}" >&2
    die "The identity typed at the target conflicts with the laptop's records (above). Check the stickers; re-run enable-ssh.sh there if it was mistyped."
  fi
}

# --- Fetching target scripts --------------------------------------------------------

check_tag() {
  [[ "$1" =~ ^[A-Za-z0-9._-]+$ ]] || die "'$1' isn't a valid tag name."
  git -C "$LIB_REPO_ROOT" rev-parse -q --verify "refs/tags/$1^{commit}" >/dev/null \
    || die "Tag $1 isn't in this repo. Nothing was sent to the target."
}

# Fetches scripts/linux/<file> at <tag> into the target's home directory and
# checks it against the hash of this repo's own copy of the tag. A file
# that's already there with the right hash is left alone, and a download goes
# to <file>.part first, so a script still running in screen is never
# overwritten mid-run.
fetch_verified() {
  local tag="$1" file hash url
  shift
  for file in "$@"; do
    git -C "$LIB_REPO_ROOT" cat-file -e "$tag:scripts/linux/$file" 2>/dev/null \
      || die "scripts/linux/$file doesn't exist at tag $tag."
    hash=$(git -C "$LIB_REPO_ROOT" show "$tag:scripts/linux/$file" | sha256sum | cut -d' ' -f1)
    url="$RAW_BASE/$tag/scripts/linux/$file"
    rsh "if echo '$hash  $file' | sha256sum -c --quiet >/dev/null 2>&1; then
           echo '  $file: already there, checksum OK'
         else
           wget -q -O '$file.part' '$url' || { echo '  $file: download failed'; exit 1; }
           if echo '$hash  $file.part' | sha256sum -c --quiet >/dev/null 2>&1; then
             mv '$file.part' '$file' && echo '  $file: fetched, checksum OK'
           else
             echo '  $file: CHECKSUM MISMATCH, not used'; exit 1
           fi
         fi" || die "Could not fetch a verified $file onto the target (expected SHA-256 $hash)."
  done
}

# Pipes the stage answer into diagnostics.sh, which takes the machine number
# and CIAD from results/identity.env (diagnostics.sh v0.12+).
run_diagnostics() {
  printf '%s\n' "$1" | ssh "${SSH_OPTS[@]}" "$REMOTE_USER@$TARGET_IP" 'bash diagnostics.sh'
}
