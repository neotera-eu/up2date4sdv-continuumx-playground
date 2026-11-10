#!/usr/bin/env bash
# Host prep before starting the playground (rootless Podman / Docker).
#
# Kernel modules cannot be loaded from inside the containers (rootless
# user namespaces -> modprobe returns "Operation not permitted").
# Load them on the real host here so cloud/edge networking works on any
# Linux distro (Fedora, Debian, Ubuntu, ...).

set -euo pipefail

need_instances=1024
need_watches=1048576

run() {
  if [[ "$(id -u)" -eq 0 ]]; then
    "$@"
    return
  fi
  # Prefer passwordless sudo, then interactive sudo, then run0 (Fedora).
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
