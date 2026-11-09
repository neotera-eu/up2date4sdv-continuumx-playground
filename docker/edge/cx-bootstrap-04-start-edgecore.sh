#!/bin/bash
# Restart edgecore so config patches are applied, then check it is active.

systemctl enable edgecore
systemctl restart edgecore
for _ in $(seq 1 30); do
  systemctl is-active --quiet edgecore && break
  sleep 1
done
if ! systemctl is-active --quiet edgecore; then
  journalctl -u edgecore -n 80 --no-pager || true
  exit 1
fi
