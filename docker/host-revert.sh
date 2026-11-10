#!/usr/bin/env bash
# Restore /etc/hosts from the backup created by host-prep.sh.

set -euo pipefail

HOSTS_FILE=/etc/hosts
HOSTS_BACKUP=/etc/hosts.backup

run() {
  if [[ "$(id -u)" -eq 0 ]]; then
    "$@"
    return
  fi
  if command -v sudo >/dev/null 2>&1; then
    if sudo -n true 2>/dev/null; then
      sudo "$@"
      return
    fi
    echo "revert needs root once (sudo) to restore /etc/hosts"
    sudo "$@"
    return
  fi
  if command -v run0 >/dev/null 2>&1; then
    echo "revert needs root once (run0) to restore /etc/hosts"
    run0 "$@"
    return
  fi
  echo "error: need root, sudo, or run0 to restore /etc/hosts" >&2
  exit 1
}

if [[ ! -e "$HOSTS_BACKUP" ]]; then
  echo "no backup found at ${HOSTS_BACKUP} - nothing to revert"
  exit 0
fi

run cp -a "$HOSTS_BACKUP" "$HOSTS_FILE"
echo "restored ${HOSTS_FILE} from ${HOSTS_BACKUP}"
