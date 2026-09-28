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

echo "Installing openssh-server..."
# --force-confnew: this live image's default sshd_config lacks a
# "Subsystem sftp ..." line, which breaks scp's default SFTP protocol
# ("subsystem request failed on channel 0"). The package's own sshd_config
# has that line, so always take it rather than prompting per machine.
# Confirmed fix 2026-09-28 (see docs/ssh-access.md).
apt install -y -o Dpkg::Options::="--force-confnew" openssh-server

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

TARGET_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
echo
echo "Done. From the laptop:"
echo "  ssh -i ~/.ssh/id_ed25519_refurb ${TARGET_USER}@${TARGET_IP:-<check ip a>}"
echo "  scp -i ~/.ssh/id_ed25519_refurb <file> ${TARGET_USER}@${TARGET_IP:-<ip>}:~/"
