#!/bin/bash
# Join ContinuumX CloudCore (skipped if already joined).
#
# You may change:
# - --cloudcore-ipport (must match cloud hostname / DNS)
# - --kubeedge-version / --image-repository

if [[ ! -f /etc/kubeedge/config/edgecore.yaml ]]; then
  cxadm join \
    --cloudcore-ipport=u2deb-cloud:10000 \
    --token="$(cat /var/cx-join/token)" \
    --kubeedge-version=v1.23.0 \
    --image-repository=neotera \
    --cgroupdriver=systemd \
    --remote-runtime-endpoint=unix:///run/containerd/containerd.sock
fi
