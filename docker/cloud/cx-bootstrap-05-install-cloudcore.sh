#!/bin/bash
# Install ContinuumX CloudCore.
#
# You may change:
# - --kubeedge-version / image tag
# - --image-repository
# - dnsNames for the CloudHub certificate

: "${CX_HOST_IP:=$(ip -4 -o addr show scope global | awk '{print $4}' | cut -d/ -f1 | head -1)}"

if ! kubectl -n continuumx get deploy cloudcore >/dev/null 2>&1 \
   && ! kubectl -n kubeedge get deploy cloudcore >/dev/null 2>&1; then
  cxadm init \
    --advertise-address="${CX_HOST_IP}" \
    --kubeedge-version=v1.23.0 \
    --image-repository=neotera \
    --kube-config=/root/.kube/config \
    --set cloudCore.image.tag=v1.23.0 \
    --set cloudCore.modules.cloudHub.dnsNames[0]="u2deb-cloud" \
    --set cloudCore.modules.cloudHub.dnsNames[1]="cloud" \
    --set cloudCore.modules.router.enable=true \
    --force
fi

for _ in $(seq 1 90); do
  ss -lnt | grep -q ':10000 ' && break
  sleep 1
done
ss -lnt | grep -q ':10000 '
