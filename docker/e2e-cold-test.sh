#!/usr/bin/env bash
# Run cold start(s) and check end-to-end
# (nodes + ServiceBus + Virtual ECU + mapper + firmware twin OTA).
#
# Usage (from docker/):
#   ./e2e-cold-test.sh

set -euo pipefail
cd "$(dirname "$0")"

CLOUD=continuumx-playground_cloud_1
EDGE=continuumx-playground_edge_1
DEVICE=automotive-thermal-ecu-fw-001
PASS=0
FAIL=0

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }

ecu_health_version() {
  podman exec "$EDGE" curl -sfS --max-time 2 \
    --unix-socket /run/continuumx-virtual-ecu/ecu.sock \
    http://localhost/v1/health 2>/dev/null \
    | python3 -c 'import sys,json; print(json.load(sys.stdin).get("firmwareVersion",""))' 2>/dev/null || true
}

wait_ready() {
  local timeout="${1:-240}"
  local start now elapsed
  start=$(date +%s)
  while true; do
    now=$(date +%s); elapsed=$((now - start))
    local c_ready=no e_core=na r9443=no c_boot=na e_boot=na mapper=na ecu=na
    podman exec "$CLOUD" test -f /var/cx-join/cloud-ready 2>/dev/null && c_ready=yes || true
    c_boot=$(podman exec "$CLOUD" systemctl is-active cx-bootstrap 2>/dev/null || true)
    e_boot=$(podman exec "$EDGE" systemctl is-active cx-bootstrap 2>/dev/null || true)
    e_core=$(podman exec "$EDGE" systemctl is-active edgecore 2>/dev/null || true)
    mapper=$(podman exec "$EDGE" systemctl is-active continuumx-virtual-ethernet-mapper 2>/dev/null || true)
    ecu=$(podman exec "$EDGE" systemctl is-active continuumx-virtual-ecu 2>/dev/null || true)
    c_boot=${c_boot:-na}; e_boot=${e_boot:-na}; e_core=${e_core:-na}
    mapper=${mapper:-na}; ecu=${ecu:-na}
    podman exec "$CLOUD" bash -c 'ss -lnt 2>/dev/null | grep -q ":9443 "' 2>/dev/null && r9443=yes || true

    log "t+${elapsed}s cloud-boot=$c_boot ready=$c_ready :9443=$r9443 edge-boot=$e_boot edgecore=$e_core ecu=$ecu mapper=$mapper"

    if [[ "$c_boot" == failed || "$e_boot" == failed ]]; then
      log "bootstrap FAILED"
      podman exec "$CLOUD" journalctl -u cx-bootstrap -n 40 --no-pager 2>&1 | tail -50 || true
      podman exec "$EDGE" journalctl -u cx-bootstrap -n 40 --no-pager 2>&1 | tail -50 || true
      return 1
    fi

    if [[ "$c_ready" == yes && "$r9443" == yes && "$e_core" == active && \
          "$ecu" == active && "$mapper" == active && \
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
      podman exec "$EDGE" journalctl -u continuumx-virtual-ecu -n 40 --no-pager 2>&1 | tail -40 || true
      podman exec "$EDGE" journalctl -u continuumx-virtual-ethernet-mapper -n 40 --no-pager 2>&1 | tail -40 || true
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

  # Virtual ECU + mapper
  podman exec "$EDGE" systemctl is-active --quiet continuumx-virtual-ecu \
    || { log "FAIL: virtual-ecu inactive"; return 1; }
  podman exec "$EDGE" systemctl is-active --quiet continuumx-virtual-ethernet-mapper \
    || { log "FAIL: mapper inactive"; return 1; }
  podman exec "$EDGE" bash -c 'test -S /etc/kubeedge/dmi.sock' \
    || { log "FAIL: missing dmi.sock"; return 1; }
  podman exec "$EDGE" bash -c 'test -S /run/continuumx-virtual-ecu/ecu.sock' \
    || { log "FAIL: missing ecu.sock"; return 1; }

  local ver
  ver="$(ecu_health_version)"
  log "ecu health firmwareVersion=${ver}"
  [[ "$ver" == "sim-1.0.0" || "$ver" == "sim-1.1.0" ]] \
    || { log "FAIL: unexpected ECU version '${ver}'"; return 1; }

  local device_ok=0
  for a in $(seq 1 45); do
    if podman exec "$CLOUD" kubectl get device "$DEVICE" -n default >/dev/null 2>&1 \
       && podman exec "$CLOUD" kubectl get devicestatus "$DEVICE" -n default \
            -o jsonpath='{.status.twins[*].propertyName}' 2>/dev/null | grep -q coolantTemperature; then
      device_ok=1
      break
    fi
    sleep 2
  done
  [[ "$device_ok" == 1 ]] || {
    log "FAIL: device twin / DeviceStatus not ready"
    podman exec "$CLOUD" kubectl get devicemodel,device,devicestatus -n default || true
    podman exec "$EDGE" journalctl -u continuumx-virtual-ethernet-mapper -n 40 --no-pager || true
    return 1
  }

  # Coolant twin patch (index 14).
  podman exec "$CLOUD" kubectl patch device "$DEVICE" -n default --type=json \
    -p='[{"op":"test","path":"/spec/properties/14/name","value":"targetCoolantTemperature"},{"op":"replace","path":"/spec/properties/14/desired/value","value":"63.0"}]' \
    >/dev/null

  local twin_ok=0 observed reported
  for a in $(seq 1 45); do
    observed=$(podman exec "$CLOUD" kubectl get devicestatus "$DEVICE" -n default \
      -o jsonpath='{range .status.twins[?(@.propertyName=="targetCoolantTemperature")]}{.observedDesired.value}{end}' 2>/dev/null || true)
    reported=$(podman exec "$CLOUD" kubectl get devicestatus "$DEVICE" -n default \
      -o jsonpath='{range .status.twins[?(@.propertyName=="targetCoolantTemperature")]}{.reported.value}{end}' 2>/dev/null || true)
    log "coolant twin attempt$a observedDesired=$observed reported=$reported"
    if echo "$observed" | grep -Eq '^63(\.0)?$' && echo "$reported" | grep -Eq '^63(\.0)?$'; then
      twin_ok=1
      break
    fi
    sleep 3
  done
  [[ "$twin_ok" == 1 ]] || {
    log "FAIL: desired coolant twin 63.0 not observed/reported"
    podman exec "$CLOUD" kubectl get devicestatus "$DEVICE" -n default -o yaml | tail -80 || true
    return 1
  }

  # Firmware OTA: desired sim-1.1.0 -> ECU health + reported twin.
  log "patching firmwareVersion desired=sim-1.1.0"
  podman exec "$CLOUD" kubectl patch device "$DEVICE" -n default --type=json \
    -p='[{"op":"test","path":"/spec/properties/10/name","value":"firmwareVersion"},{"op":"replace","path":"/spec/properties/10/desired/value","value":"sim-1.1.0"}]' \
    >/dev/null

  local fw_ok=0 fw_reported ecu_ver
  for a in $(seq 1 60); do
    ecu_ver="$(ecu_health_version)"
    fw_reported=$(podman exec "$CLOUD" kubectl get devicestatus "$DEVICE" -n default \
      -o jsonpath='{range .status.twins[?(@.propertyName=="firmwareVersion")]}{.reported.value}{end}' 2>/dev/null || true)
    log "fw attempt$a ecu=${ecu_ver} reported=${fw_reported}"
    if [[ "$ecu_ver" == "sim-1.1.0" && "$fw_reported" == "sim-1.1.0" ]]; then
      fw_ok=1
      break
    fi
    sleep 2
  done
  [[ "$fw_ok" == 1 ]] || {
    log "FAIL: firmware OTA to sim-1.1.0 did not complete"
    podman exec "$EDGE" journalctl -u continuumx-virtual-ecu -n 40 --no-pager || true
    podman exec "$EDGE" journalctl -u continuumx-virtual-ethernet-mapper -n 50 --no-pager || true
    podman exec "$CLOUD" kubectl get device,devicestatus "$DEVICE" -n default -o yaml | tail -100 || true
    return 1
  }

  log "PASS: $label"
  return 0
}

cold_start() {
  local n="$1"
  log "######## COLD START #$n ########"
  bash ./host-prep.sh >/dev/null
  podman compose down -v --remove-orphans
  podman compose up -d
  wait_ready 360
  verify_e2e "cold-$n"
}

log "building images"
podman compose build cloud edge servicebus-demo firmware-catalog

E2E_RUNS="${E2E_RUNS:-1}"
for i in $(seq 1 "$E2E_RUNS"); do
  if cold_start "$i"; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    log "cold start #$i failed -- aborting further runs"
    break
  fi
done

log "######## SUMMARY: pass=$PASS fail=$FAIL ########"
[[ "$FAIL" -eq 0 && "$PASS" -ge 1 ]]
