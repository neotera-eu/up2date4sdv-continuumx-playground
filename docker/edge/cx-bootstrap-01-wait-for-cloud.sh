#!/bin/bash
# Wait until cloud published the join token and cloud-ready flag.

echo "waiting for cloud"
for _ in $(seq 1 180); do
  [[ -s /var/cx-join/token && -f /var/cx-join/cloud-ready ]] && break
  sleep 2
done
[[ -s /var/cx-join/token ]]
[[ -f /var/cx-join/cloudcore-ca.crt ]] && cp /var/cx-join/cloudcore-ca.crt /tmp/cloudcore-ca.crt
