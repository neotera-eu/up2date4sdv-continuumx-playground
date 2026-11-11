#!/bin/bash
# Start the Virtual Ethernet mapper once EdgeCore DMI socket exists.

echo "waiting for EdgeCore DMI socket /etc/kubeedge/dmi.sock"
for _ in $(seq 1 60); do
  [[ -S /etc/kubeedge/dmi.sock ]] && break
  sleep 1
done
if [[ ! -S /etc/kubeedge/dmi.sock ]]; then
  echo "error: /etc/kubeedge/dmi.sock not found; DeviceTwin/DMI not ready"
  journalctl -u edgecore -n 40 --no-pager || true
  exit 1
fi

systemctl enable continuumx-virtual-ethernet.service
systemctl restart continuumx-virtual-ethernet.service

for _ in $(seq 1 30); do
  systemctl is-active --quiet continuumx-virtual-ethernet && break
  sleep 1
done

if ! systemctl is-active --quiet continuumx-virtual-ethernet; then
  echo "error: continuumx-virtual-ethernet failed to start"
  journalctl -u continuumx-virtual-ethernet -n 50 --no-pager || true
  exit 1
fi

echo "mapper active; socket=$(ls -l /etc/kubeedge/virtual-ethernet.sock 2>/dev/null || echo pending)"
