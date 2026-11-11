#!/bin/bash
# Start the Virtual Ethernet mapper once EdgeCore DMI + Virtual ECU sockets exist.

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

echo "waiting for Virtual ECU socket /run/continuumx-virtual-ecu/ecu.sock"
for _ in $(seq 1 40); do
  [[ -S /run/continuumx-virtual-ecu/ecu.sock ]] && break
  sleep 0.5
done
if [[ ! -S /run/continuumx-virtual-ecu/ecu.sock ]]; then
  echo "error: Virtual ECU socket missing"
  journalctl -u continuumx-virtual-ecu -n 40 --no-pager || true
  exit 1
fi

# Disable legacy unit name if an older image left it enabled.
systemctl disable --now continuumx-virtual-ethernet.service 2>/dev/null || true

systemctl enable continuumx-virtual-ethernet-mapper.service
systemctl restart continuumx-virtual-ethernet-mapper.service

for _ in $(seq 1 30); do
  systemctl is-active --quiet continuumx-virtual-ethernet-mapper && break
  sleep 1
done

if ! systemctl is-active --quiet continuumx-virtual-ethernet-mapper; then
  echo "error: continuumx-virtual-ethernet-mapper failed to start"
  journalctl -u continuumx-virtual-ethernet-mapper -n 50 --no-pager || true
  exit 1
fi

echo "mapper active; socket=$(ls -l /etc/kubeedge/virtual-ethernet-mapper.sock 2>/dev/null || echo pending)"
