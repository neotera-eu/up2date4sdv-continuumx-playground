#!/bin/bash
# Prepare edge host: modules, sysctl, start containerd, import images.

modprobe overlay || true
modprobe br_netfilter || true
sysctl -p /etc/sysctl.d/99-containerd.conf || true

systemctl start containerd
/usr/local/sbin/cx-import-images.sh
