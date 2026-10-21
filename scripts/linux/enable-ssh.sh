#!/usr/bin/env bash
# enable-ssh.sh — turn on key-only SSH access on a target machine's live
# session, authorized against a GitHub account's public keys
# (https://github.com/<user>.keys). Installs packages and starts a service
# only — no disk or sanitization changes of any kind.
#
# Run this ON THE TARGET MACHINE (Ubuntu Live session) — never on the dev
# laptop. See docs/ssh-access.md for the full workflow (laptop-side key
# setup and connecting).
#
# v16 (2026-10-21): also records this machine's identity for the
# laptop-driven passes (scripts/laptop/open-machine.sh, close-machine.sh).
#   - Asks for the machine number and the asset tag (CIAD sticker), each
#     typed twice, here at the machine's own keyboard: being physically at
#     the box is what ties the stickers to this session.
#   - Writes them, the chassis serial (dmidecode) and the session code to
#     ~/results/identity.env. diagnostics.sh and erase-partition.sh take the
#     number and asset tag from that file instead of prompting.
#   - Prints an identity card with the SESSION CODE: the first 6 hex
#     characters of the SHA-256 of this boot's ed25519 host key. The laptop
#     computes the same code from the key it actually connects to, and asks
#     for it before doing anything — that proves the IP it was given is
#     this machine.
#   - Also installs screen (already on the 26.04.1 image; a no-op there),
#     which open-machine.sh runs the erase in.
#
# Usage: sudo bash enable-ssh.sh <github-username>
# Example: sudo bash enable-ssh.sh xxsdf-james

set -eu

if [ "$(id -u)" -ne 0 ]; then
  echo "Run this with sudo: sudo bash enable-ssh.sh <github-username>" >&2
  exit 1
fi

GITHUB_USER="${1:?Usage: sudo bash enable-ssh.sh <github-username>}"

# The script runs as root (needed for apt/systemctl), but the authorized_keys
# file has to go in the INVOKING user's home — that's who you actually log
# in as (e.g. "ubuntu"), not root.
TARGET_USER="${SUDO_USER:-$(logname 2>/dev/null || echo root)}"
TARGET_HOME=$(getent passwd "$TARGET_USER" | cut -d: -f6)

# Asks for a value twice; both entries must match and fit the pattern.
# Spaces are dropped and letters uppercased before comparing.
ask_twice() {
  local prompt="$1" pattern="$2" first second
  while :; do
    read -rp "$prompt: " first || exit 1
    first=$(echo "$first" | tr -d '[:space:]' | tr '[:lower:]' '[:upper:]')
    if ! [[ "$first" =~ $pattern ]]; then
      echo "  '$first' doesn't look right — try again." >&2
      continue
    fi
    read -rp "$prompt (again): " second || exit 1
    second=$(echo "$second" | tr -d '[:space:]' | tr '[:lower:]' '[:upper:]')
    if [ "$first" = "$second" ]; then
      echo "$first"
      return
    fi
    echo "  The two entries differ — start this one again." >&2
  done
}

echo "Read these off the stickers on THIS machine."
MACHINE_NUMBER=$(ask_twice "Machine number (3 digits)" '^[0-9]{3}$')
ASSET_TAG=$(ask_twice "Asset tag (CIAD sticker, e.g. CIAD7562, FR1589)" '^[A-Z0-9]{3,12}$')

CHASSIS_SERIAL=$(dmidecode -t system 2>/dev/null | awk -F': ' '/Serial Number/{print $2; exit}')
CHASSIS_SERIAL="${CHASSIS_SERIAL:-unknown}"

echo "Installing openssh-server and screen..."
# --force-confnew: this live image's default sshd_config lacks a
# "Subsystem sftp ..." line, which breaks scp's default SFTP protocol
# ("subsystem request failed on channel 0"). The package's own sshd_config
# has that line, so always take it rather than prompting per machine.
# Confirmed fix 2026-09-28 (see docs/ssh-access.md).
apt install -y -o Dpkg::Options::="--force-confnew" openssh-server screen

echo "Fetching https://github.com/${GITHUB_USER}.keys into ${TARGET_HOME}/.ssh/authorized_keys ..."
install -d -m 700 -o "$TARGET_USER" -g "$TARGET_USER" "$TARGET_HOME/.ssh"
if command -v curl >/dev/null 2>&1; then
  curl -fsSL "https://github.com/${GITHUB_USER}.keys" -o "$TARGET_HOME/.ssh/authorized_keys"
else
  wget -qO "$TARGET_HOME/.ssh/authorized_keys" "https://github.com/${GITHUB_USER}.keys"
fi
chown "$TARGET_USER:$TARGET_USER" "$TARGET_HOME/.ssh/authorized_keys"
chmod 600 "$TARGET_HOME/.ssh/authorized_keys"

echo "Enabling and starting ssh..."
systemctl enable --now ssh

# Same computation as session_code() in scripts/laptop/lib-target.sh: the
# SHA-256 of the raw key blob (what ssh-keygen -l shows in base64), as hex.
SESSION_CODE=$(awk '{print $2}' /etc/ssh/ssh_host_ed25519_key.pub | base64 -d \
  | sha256sum | cut -c1-6 | tr '[:lower:]' '[:upper:]')

# Lives next to diagnostics.sh's results/, which is where the scripts read it.
install -d -o "$TARGET_USER" -g "$TARGET_USER" "$TARGET_HOME/results"
cat > "$TARGET_HOME/results/identity.env" <<EOF
MACHINE_NUMBER=$MACHINE_NUMBER
ASSET_TAG=$ASSET_TAG
CHASSIS_SERIAL=$CHASSIS_SERIAL
SESSION_CODE=$SESSION_CODE
EOF
chown "$TARGET_USER:$TARGET_USER" "$TARGET_HOME/results/identity.env"

TARGET_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
echo
echo "  ================================================"
echo "    Machine number : $MACHINE_NUMBER"
echo "    Asset tag      : $ASSET_TAG"
echo "    Chassis serial : $CHASSIS_SERIAL"
echo "    IP address     : ${TARGET_IP:-<check ip a>}"
echo
echo "    SESSION CODE   :   $SESSION_CODE"
echo "  ================================================"
echo
[ "$CHASSIS_SERIAL" = "unknown" ] && echo "WARNING: could not read the chassis serial — the laptop scripts will refuse this machine."
echo "From the laptop (it will ask for the session code above):"
echo "  opening: scripts/laptop/open-machine.sh ${TARGET_IP:-<ip>} <tag>"
echo "  closing: scripts/laptop/close-machine.sh ${TARGET_IP:-<ip>} <tag>"
