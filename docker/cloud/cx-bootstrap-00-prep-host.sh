#!/bin/bash
# Prepare cloud host: sysctl, detect IP, start containerd, import images.
#
# Kernel modules (overlay, br_netfilter) must already be loaded on the
# real host by docker/host-prep.sh - containers cannot modprobe under
# rootless Podman/Docker.

mkdir -p /var/lib/cx-playground /var/cx-join /root/.kube

# Best-effort only; host-prep.sh is the real loader.
modprobe overlay 2>/dev/null || true
modprobe br_netfilter 2>/dev/null || true
sysctl -p /etc/sysctl.d/k8s.conf 2>/dev/null || true

if [[ ! -d /sys/module/br_netfilter ]] && [[ ! -e /proc/sys/net/bridge/bridge-nf-call-iptables ]]; then
  echo "warning: br_netfilter is not available in this container."
  echo "  run 'make run' (or docker/host-prep.sh) on the host first."
fi

CX_HOST_IP=$(ip -4 -o addr show scope global | awk '{print $4}' | cut -d/ -f1 | head -1)
[[ -n "$CX_HOST_IP" ]]
export CX_HOST_IP
echo "CX_HOST_IP=${CX_HOST_IP}"

if ! grep -qE "[[:space:]]u2deb-cloud([[:space:]]|$)" /etc/hosts; then
  echo "${CX_HOST_IP} u2deb-cloud cloud" >> /etc/hosts || true
fi

systemctl start containerd
/usr/local/sbin/cx-import-images.sh
