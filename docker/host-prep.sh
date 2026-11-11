#!/usr/bin/env bash
# Host prep before starting the playground (rootless Podman / Docker).
#
# Kernel modules cannot be loaded from inside the containers (rootless
# user namespaces -> modprobe returns "Operation not permitted").
# Load them on the real host here so cloud/edge networking works on any
# Linux distro (Fedora, Debian, Ubuntu, ...).
#
# Also checks /etc/hosts for names that collide with this stack. If found,
# asks before backing up to /etc/hosts.backup and writing a clean file.
# Restore later with: make revert

set -euo pipefail

need_instances=1024
need_watches=1048576
HOSTS_FILE=/etc/hosts
HOSTS_BACKUP=/etc/hosts.backup

# Hostnames this playground (and the VM docs) use. Stale mappings here
# (e.g. old 192.168.56.x VirtualBox entries) break resolution.
CONFLICT_NAMES=(
  cloud
  mqtt-broker
  u2deb-cloud
  u2deb-edge
  u2deb-cloud.local
  u2deb-edge.local
  u2deb-cloud.lan
  u2deb-edge.lan
)

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
    echo "host prep needs root once (sudo) to load kernel modules + sysctls"
    sudo "$@"
    return
  fi
  if command -v run0 >/dev/null 2>&1; then
    echo "host prep needs root once (run0) to load kernel modules + sysctls"
    run0 "$@"
    return
  fi
  echo "error: need root, sudo, or run0 to prepare the host" >&2
  exit 1
}

ask_yes_no() {
  local prompt="$1"
  local reply=
  if [[ ! -t 0 ]] && [[ -r /dev/tty ]]; then
    printf '%s' "$prompt" >/dev/tty
    read -r reply </dev/tty || true
  else
    printf '%s' "$prompt"
    read -r reply || true
  fi
  [[ "$reply" == [yY] || "$reply" == [yY][eE][sS] ]]
}

find_host_conflicts() {
  local names_csv
  [[ -r "$HOSTS_FILE" ]] || return 0
  # Whole-token match on hostnames (field 2+), ignore comments/blank.
  names_csv="$(IFS=,; echo "${CONFLICT_NAMES[*]}")"
  awk -v names="$names_csv" '
    BEGIN {
      n = split(names, want, ",")
      for (i = 1; i <= n; i++) bad[want[i]] = 1
    }
    /^[[:space:]]*#/ { next }
    NF == 0 { next }
    {
      for (i = 2; i <= NF; i++) {
        gsub(/\r/, "", $i)
        if ($i ~ /^#/) break
        if ($i in bad) { print; next }
      }
    }
  ' "$HOSTS_FILE"
}

write_clean_hosts() {
  local host short
  host="$(hostname -f 2>/dev/null || hostname 2>/dev/null || echo localhost)"
  short="$(hostname -s 2>/dev/null || echo localhost)"

  # Minimal portable hosts file. Keep the machine hostname on 127.0.1.1
  # (Debian/Ubuntu style) when it is not just "localhost".
  {
    echo "# Written by continuumx-playground host-prep.sh"
    echo "# Previous file saved as ${HOSTS_BACKUP}"
    echo "127.0.0.1 localhost"
    echo "::1 localhost ip6-localhost ip6-loopback"
    echo "ff02::1 ip6-allnodes"
    echo "ff02::2 ip6-allrouters"
    if [[ -n "$short" && "$short" != localhost ]]; then
      if [[ "$host" != "$short" && "$host" != localhost ]]; then
        echo "127.0.1.1 ${host} ${short}"
      else
        echo "127.0.1.1 ${short}"
      fi
    fi
  } | run tee "$HOSTS_FILE" >/dev/null
}

ensure_hosts_ok() {
  local conflicts
  conflicts="$(find_host_conflicts || true)"
  if [[ -z "$conflicts" ]]; then
    echo "/etc/hosts: no playground name conflicts"
    return 0
  fi

  echo ""
  echo "WARNING: /etc/hosts has entries that can break this playground"
  echo "(stale cloud / edge / mqtt / VirtualBox names):"
  echo "--------------------------------------------------------------"
  printf '%s\n' "$conflicts"
  echo "--------------------------------------------------------------"
  echo "Recommended: backup to ${HOSTS_BACKUP} and replace with a clean file."
  echo "You can restore later with: make revert"
  echo ""

  if ! ask_yes_no "Backup /etc/hosts and replace with a clean version? [y/N] "; then
    echo "error: refused hosts cleanup; fix /etc/hosts or re-run make run" >&2
    exit 1
  fi

  if [[ -e "$HOSTS_BACKUP" ]]; then
    echo "keeping existing backup ${HOSTS_BACKUP} (not overwritten)"
  else
    run cp -a "$HOSTS_FILE" "$HOSTS_BACKUP"
    echo "backed up ${HOSTS_FILE} -> ${HOSTS_BACKUP}"
  fi

  write_clean_hosts
  echo "wrote clean ${HOSTS_FILE}"
}

module_loaded() {
  local name="$1"
  [[ -d "/sys/module/${name}" ]] || grep -q "^${name} " /proc/modules 2>/dev/null
}

ensure_module() {
  local name="$1"
  if module_loaded "$name"; then
    echo "module ${name}: already loaded"
    return 0
  fi
  if ! run modprobe "$name"; then
    echo "error: failed to load kernel module '${name}' on the host" >&2
    echo "  containers cannot load modules under rootless Podman/Docker." >&2
    echo "  install kernel modules for $(uname -r) and re-run: make run" >&2
    exit 1
  fi
  if ! module_loaded "$name"; then
    echo "error: modprobe ${name} returned success but module is not loaded" >&2
    exit 1
  fi
  echo "module ${name}: loaded"
}

ensure_hosts_ok

# overlay: container storage; br_netfilter: kube-proxy / CNI iptables on bridges
ensure_module overlay
ensure_module br_netfilter

run tee /etc/modules-load.d/continuumx-playground.conf >/dev/null <<'EOF'
overlay
br_netfilter
EOF

run tee /etc/sysctl.d/99-continuumx-playground.conf >/dev/null <<EOF
fs.inotify.max_user_instances=${need_instances}
fs.inotify.max_user_watches=${need_watches}
net.ipv4.ip_forward=1
net.bridge.bridge-nf-call-iptables=1
net.bridge.bridge-nf-call-ip6tables=1
EOF

run sysctl -w "fs.inotify.max_user_instances=${need_instances}"
run sysctl -w "fs.inotify.max_user_watches=${need_watches}"
run sysctl -w net.ipv4.ip_forward=1
# These keys only exist after br_netfilter is loaded.
run sysctl -w net.bridge.bridge-nf-call-iptables=1
run sysctl -w net.bridge.bridge-nf-call-ip6tables=1

echo "host prep complete"
