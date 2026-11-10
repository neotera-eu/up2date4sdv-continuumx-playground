#!/bin/bash
# Prepare edge host: sysctl, start containerd, import images.
#
# Kernel modules (overlay, br_netfilter) must already be loaded on the
# real host by docker/host-prep.sh - containers cannot modprobe under
# rootless Podman/Docker.

# Best-effort only; host-prep.sh is the real loader.
modprobe overlay 2>/dev/null || true
modprobe br_netfilter 2>/dev/null || true
sysctl -p /etc/sysctl.d/99-containerd.conf 2>/dev/null || true

if [[ ! -d /sys/module/br_netfilter ]] && [[ ! -e /proc/sys/net/bridge/bridge-nf-call-iptables ]]; then
  echo "warning: br_netfilter is not available in this container."
  echo "  run 'make run' (or docker/host-prep.sh) on the host first."
fi

systemctl start containerd
/usr/local/sbin/cx-import-images.sh
