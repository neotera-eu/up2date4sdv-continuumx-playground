#!/bin/bash
# Prepare cloud host: modules, sysctl, detect IP, start containerd, import images.

mkdir -p /var/lib/cx-playground /var/cx-join /root/.kube
swapoff -a || true
modprobe overlay || true
modprobe br_netfilter || true
sysctl -p /etc/sysctl.d/k8s.conf || true

CX_HOST_IP=$(ip -4 -o addr show scope global | awk '{print $4}' | cut -d/ -f1 | head -1)
[[ -n "$CX_HOST_IP" ]]
export CX_HOST_IP
echo "CX_HOST_IP=${CX_HOST_IP}"

if ! grep -qE "[[:space:]]u2deb-cloud([[:space:]]|$)" /etc/hosts; then
  echo "${CX_HOST_IP} u2deb-cloud cloud" >> /etc/hosts || true
fi

systemctl start containerd
/usr/local/sbin/cx-import-images.sh
