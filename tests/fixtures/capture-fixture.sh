#!/usr/bin/env bash
# capture-fixture.sh — dump raw hardware diagnostic output to one log file, to be
# split by hand into tests/fixtures/<machine>/ per tests/fixtures/README.md.
#
# Read-only. Runs lsblk, dmidecode, smartctl, and nvme id-ctrl (NVMe only) — the
# same detection logic scripts/linux/diagnostics.sh uses to pick the primary drive
# and classify it. Issues no sanitization command, NVMe or otherwise.
#
# Run this on the TARGET machine's Ubuntu Live session — never on the dev laptop.
#
# Usage:
#   sudo bash capture-fixture.sh > 00X-<drive-type>-capture.log 2>&1

set -u

have() { command -v "$1" >/dev/null 2>&1; }

section() {
  echo
  echo "===== BEGIN: $1 ====="
}
endsection() {
  echo "===== END: $1 ====="
}

# --- Identify the primary drive: same detection as diagnostics.sh ------------
PRIMARY_DEV=""
STORAGE_TYPE="unknown"

NVME_DEV=$(ls /dev/nvme?n1 2>/dev/null | head -n1)
if [ -n "$NVME_DEV" ]; then
  PRIMARY_DEV="$NVME_DEV"
  STORAGE_TYPE="NVMe"
elif have lsblk; then
  CANDIDATE=$(lsblk -dno NAME,TYPE,TRAN,RM 2>/dev/null | awk '$2=="disk" && $3!="usb" && $4==0 {print $1; exit}')
  if [ -n "$CANDIDATE" ]; then
    PRIMARY_DEV="/dev/$CANDIDATE"
    ROTA=$(lsblk -dno ROTA "$PRIMARY_DEV" 2>/dev/null | tr -d '[:space:]')
    if [ "$ROTA" = "1" ]; then
      STORAGE_TYPE="SATA HDD (rotational)"
    else
      STORAGE_TYPE="SATA SSD (non-rotational)"
    fi
  fi
fi

section "detected primary device"
echo "device : ${PRIMARY_DEV:-none}"
echo "type   : $STORAGE_TYPE"
endsection "detected primary device"

if [ -z "$PRIMARY_DEV" ]; then
  echo "Could not detect a primary device automatically — check 'lsblk -f' manually and re-run with the device hardcoded." >&2
  exit 1
fi

section "lsblk -J"
lsblk -J
endsection "lsblk -J"

section "lsblk -dno NAME,TYPE,TRAN,RM,ROTA"
lsblk -dno NAME,TYPE,TRAN,RM,ROTA
endsection "lsblk -dno NAME,TYPE,TRAN,RM,ROTA"

section "sudo dmidecode -t system"
sudo dmidecode -t system
endsection "sudo dmidecode -t system"

section "sudo dmidecode -t memory"
sudo dmidecode -t memory
endsection "sudo dmidecode -t memory"

if [ "$STORAGE_TYPE" = "NVMe" ] && have nvme; then
  section "sudo nvme id-ctrl $PRIMARY_DEV"
  sudo nvme id-ctrl "$PRIMARY_DEV"
  endsection "sudo nvme id-ctrl $PRIMARY_DEV"
fi

if have smartctl; then
  section "sudo smartctl -i $PRIMARY_DEV"
  sudo smartctl -i "$PRIMARY_DEV"
  endsection "sudo smartctl -i $PRIMARY_DEV"
fi

echo
echo "Capture complete. Split this log by the '===== BEGIN/END: <cmd> =====' markers"
echo "into tests/fixtures/<machine>/{lsblk.json,lsblk-summary.txt,dmidecode-system.txt,"
echo "dmidecode-memory.txt,nvme-id-ctrl.txt,smartctl-i.txt,device.txt} per"
echo "tests/fixtures/README.md. The device path is in the 'detected primary device'"
echo "section above — that's what goes in device.txt."
