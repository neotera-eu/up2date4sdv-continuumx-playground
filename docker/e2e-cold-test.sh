#!/usr/bin/env bash
# Run a few cold starts and check end-to-end (nodes + ServiceBus).
#
# Usage (from docker/):
#   ./e2e-cold-test.sh

set -euo pipefail
cd "$(dirname "$0")"

CLOUD=continuumx-playground_cloud_1
EDGE=continuumx-playground_edge_1
PASS=0
FAIL=0

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }

wait_ready() {
  local timeout="${1:-240}"
  local start now elapsed
  start=$(date +%s)
  while true; do
    now=$(date +%s); elapsed=$((now - start))
    local c_ready=no e_core=na r9443=no c_boot=na e_boot=na
    podman exec "$CLOUD" test -f /var/cx-join/cloud-ready 2>/dev/null && c_ready=yes || true
    c_boot=$(podman exec "$CLOUD" systemctl is-active cx-bootstrap 2>/dev/null || echo na)
    e_boot=$(podman exec "$EDGE" systemctl is-active cx-bootstrap 2>/dev/null || echo na)
    e_core=$(podman exec "$EDGE" systemctl is-active edgecore 2>/dev/null || echo na)
    podman exec "$CLOUD" bash -c 'ss -lnt 2>/dev/null | grep -q ":9443 "' 2>/dev/null && r9443=yes || true

    log "t+${elapsed}s cloud-boot=$c_boot ready=$c_ready :9443=$r9443 edge-boot=$e_boot edgecore=$e_core"

    if [[ "$c_boot" == failed || "$e_boot" == failed ]]; then
      log "bootstrap FAILED"
      podman exec "$CLOUD" journalctl -u cx-bootstrap -n 40 --no-pager 2>&1 | tail -50 || true
      podman exec "$EDGE" journalctl -u cx-bootstrap -n 40 --no-pager 2>&1 | tail -50 || true
      return 1
    fi

    if [[ "$c_ready" == yes && "$r9443" == yes && "$e_core" == active && \
          ("$c_boot" == active || "$c_boot" == inactive) && \
          ("$e_boot" == active || "$e_boot" == inactive) ]]; then
      log "stack ready in ${elapsed}s"
      sleep 8
      return 0
    fi

    if [[ "$elapsed" -ge "$timeout" ]]; then
      log "TIMEOUT after ${elapsed}s"
      podman exec "$CLOUD" journalctl -u cx-bootstrap -n 50 --no-pager 2>&1 | tail -60 || true
      podman exec "$EDGE" journalctl -u cx-bootstrap -n 40 --no-pager 2>&1 | tail -50 || true
      return 1
    fi
    sleep 5
  done
}

verify_e2e() {
  local label="$1"
  log "=== verify: $label ==="

  podman exec "$CLOUD" kubectl get nodes -o wide
  local nodes
  nodes=$(podman exec "$CLOUD" kubectl get nodes --no-headers 2>/dev/null | wc -l)
  [[ "$nodes" -ge 2 ]] || { log "FAIL: expected 2 nodes, got $nodes"; return 1; }

  podman exec "$EDGE" getent hosts cloud u2deb-cloud mqtt-broker >/dev/null
  podman exec "$EDGE" bash -c 'grep -q "mqttMode: 2" /etc/kubeedge/config/edgecore.yaml'
  podman exec "$EDGE" bash -c 'grep -A4 "serviceBus:" /etc/kubeedge/config/edgecore.yaml | grep -q "enable: true"'

  curl -sfS http://127.0.0.1:3000/api/health >/dev/null

  local ok=0 resp
  for a in 1 2 3 4 5 6; do
    resp=$(curl -sS -X POST http://127.0.0.1:3000/api/trigger \
      -H 'content-type: application/json' \
      -d "{\"msg\":\"$label attempt $a\"}" || true)
    log "trigger$a=$resp"
    if echo "$resp" | grep -q '"ok":true'; then
      ok=1
      break
    fi
    sleep 4
  done
  [[ "$ok" == 1 ]] || { log "FAIL: ServiceBus trigger"; return 1; }

  podman exec "$EDGE" bash -c 'timeout 3 bash -c "echo >/dev/tcp/mqtt-broker/1883"' 2>/dev/null \
    || podman exec "$EDGE" bash -c 'getent hosts mqtt-broker >/dev/null'

  log "PASS: $label"
  return 0
}

cold_start() {
  local n="$1"
  log "######## COLD START #$n ########"
  bash ./host-prep.sh >/dev/null
  podman compose down -v --remove-orphans
  podman compose up -d
  wait_ready 300
  verify_e2e "cold-$n"
}

log "building images"
podman compose build cloud edge servicebus-demo

for i in 1 2 3; do
  if cold_start "$i"; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    log "cold start #$i failed -- aborting further runs"
    break
  fi
done

log "######## SUMMARY: pass=$PASS fail=$FAIL ########"
[[ "$FAIL" -eq 0 && "$PASS" -ge 3 ]]
