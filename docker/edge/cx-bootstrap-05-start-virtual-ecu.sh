#!/bin/bash
# Start the official Virtual Thermal ECU (Unix-socket HTTP API).

systemctl enable continuumx-virtual-ecu.service
systemctl restart continuumx-virtual-ecu.service

echo "waiting for /run/continuumx-virtual-ecu/ecu.sock"
for _ in $(seq 1 40); do
  if [[ -S /run/continuumx-virtual-ecu/ecu.sock ]] \
     && curl -sfS --max-time 1 --unix-socket /run/continuumx-virtual-ecu/ecu.sock \
          http://localhost/v1/health >/dev/null; then
    curl -sfS --unix-socket /run/continuumx-virtual-ecu/ecu.sock http://localhost/v1/health
    echo
    exit 0
  fi
  sleep 0.5
done

echo "error: continuumx-virtual-ecu failed to become healthy"
journalctl -u continuumx-virtual-ecu -n 50 --no-pager || true
systemctl status continuumx-virtual-ecu --no-pager || true
exit 1
