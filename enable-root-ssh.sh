#!/usr/bin/env bash
set -Eeuo pipefail

# Enable direct root SSH login with the existing cloud user's SSH public keys.
# Usage: sudo bash enable-root-ssh.sh [source-user]

SOURCE_USER="${1:-ubuntu}"

if [[ "${EUID}" -ne 0 ]]; then
  echo "Error: run this script as root (sudo -i) or with sudo." >&2
  exit 1
fi

SOURCE_HOME="$(getent passwd "${SOURCE_USER}" | cut -d: -f6)"
if [[ -z "${SOURCE_HOME}" ]]; then
  echo "Error: user '${SOURCE_USER}' does not exist." >&2
  exit 1
fi

SOURCE_KEYS="${SOURCE_HOME}/.ssh/authorized_keys"
ROOT_SSH_DIR="/root/.ssh"
ROOT_KEYS="${ROOT_SSH_DIR}/authorized_keys"

if [[ ! -s "${SOURCE_KEYS}" ]]; then
  echo "Error: no SSH keys found in ${SOURCE_KEYS}." >&2
  exit 1
fi

install -d -m 700 -o root -g root "${ROOT_SSH_DIR}"

if [[ -e "${ROOT_KEYS}" ]]; then
  cp -a "${ROOT_KEYS}" "${ROOT_KEYS}.bak.$(date -u +%Y%m%dT%H%M%SZ)"
fi

TEMP_KEYS="$(mktemp "${ROOT_SSH_DIR}/authorized_keys.XXXXXX")"
trap 'rm -f "${TEMP_KEYS}"' EXIT

# Gcore/cloud images prepend a forced command that rejects root login.
# Keep only the public-key portion of every valid authorized_keys entry.
awk '
  /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
  {
    for (i = 1; i <= NF; i++) {
      if ($i ~ /^(ssh-(ed25519|rsa|dss)|ecdsa-sha2-|sk-ssh-ed25519@openssh\.com|sk-ecdsa-sha2-)/) {
        for (j = i; j <= NF; j++) {
          printf "%s%s", $j, (j < NF ? " " : ORS)
        }
        break
      }
    }
  }
' "${SOURCE_KEYS}" | awk '!seen[$0]++' > "${TEMP_KEYS}"

if [[ ! -s "${TEMP_KEYS}" ]]; then
  echo "Error: no supported public keys could be extracted." >&2
  exit 1
fi

install -m 600 -o root -g root "${TEMP_KEYS}" "${ROOT_KEYS}"

SSH_DROPIN_DIR="/etc/ssh/sshd_config.d"
SSH_DROPIN="${SSH_DROPIN_DIR}/00-root-key-login.conf"
install -d -m 755 "${SSH_DROPIN_DIR}"
printf '%s\n' \
  '# Allow root login with SSH keys; root password login remains disabled.' \
  'PermitRootLogin prohibit-password' > "${SSH_DROPIN}"
chmod 644 "${SSH_DROPIN}"

if ! sshd -t; then
  echo "Error: SSH configuration test failed; removing ${SSH_DROPIN}." >&2
  rm -f "${SSH_DROPIN}"
  exit 1
fi

systemctl reload ssh 2>/dev/null || systemctl reload sshd

echo "Done: root SSH key login is enabled using keys from '${SOURCE_USER}'."
echo "Test it in a new terminal before closing this session:"
echo "  ssh root@YOUR_SERVER_IP"
