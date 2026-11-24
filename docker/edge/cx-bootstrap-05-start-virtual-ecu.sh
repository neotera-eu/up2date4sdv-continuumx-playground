#!/bin/bash
# Start both official Virtual ECUs. Firmware comes only from firmware-catalog.

/usr/local/libexec/continuumx/fetch-ecu-from-catalog.sh virtual-thermal-ecu sim-1.0.0 --install-active
/usr/local/libexec/continuumx/fetch-ecu-from-catalog.sh virtual-tire-pressure-ecu sim-1.0.0 --install-active

systemctl disable --now continuumx-virtual-ecu.service 2>/dev/null || true

systemctl enable continuumx-virtual-thermal-ecu.service
systemctl enable continuumx-virtual-tire-ecu.service
systemctl restart continuumx-virtual-thermal-ecu.service
systemctl restart continuumx-virtual-tire-ecu.service

wait_ecu() {
  local unit="$1" sock="$2"
  echo "waiting for ${sock}"
  for _ in $(seq 1 40); do
    if [[ -S "$sock" ]] \
       && curl -sfS --max-time 1 --unix-socket "$sock" http://localhost/v1/health >/dev/null; then
      curl -sfS --unix-socket "$sock" http://localhost/v1/health
      echo
      return 0
    fi
    sleep 0.5
  done
  echo "error: ${unit} failed to become healthy"
  journalctl -u "$unit" -n 50 --no-pager || true
  systemctl status "$unit" --no-pager || true
  return 1
}

wait_ecu continuumx-virtual-thermal-ecu /run/continuumx-virtual-thermal-ecu/ecu.sock
wait_ecu continuumx-virtual-tire-ecu /run/continuumx-virtual-tire-ecu/ecu.sock
