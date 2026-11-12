#!/usr/bin/env bash
# Full cold-start e2e:
#   nodes + ServiceBus + Virtual ECU + mapper + CloudCore-initiated firmware OTA
#   (catalog download: sim-1.0.0 boot → sim-1.1.0 update → optional rollback).
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

device_desired_fw() {
  podman exec "$CLOUD" kubectl get device "$DEVICE" -n default -o json 2>/dev/null \
    | python3 -c '
import json,sys
d=json.load(sys.stdin)
for p in d.get("spec",{}).get("properties",[]):
  if p.get("name")=="firmwareVersion":
    print((p.get("desired") or {}).get("value",""))
    break
' 2>/dev/null || true
}

twin_fw_field() {
  # $1 = observedDesired | reported
  local field="$1"
  podman exec "$CLOUD" kubectl get devicestatus "$DEVICE" -n default -o json 2>/dev/null \
    | python3 -c '
import json,sys
field=sys.argv[1]
d=json.load(sys.stdin)
for t in d.get("status",{}).get("twins",[]) or []:
  if t.get("propertyName")=="firmwareVersion":
    print((t.get(field) or {}).get("value",""))
    break
' "$field" 2>/dev/null || true
}

fw_property_index() {
  podman exec "$CLOUD" kubectl get device "$DEVICE" -n default -o json 2>/dev/null \
    | python3 -c '
import json,sys
d=json.load(sys.stdin)
for i,p in enumerate(d.get("spec",{}).get("properties",[])):
  if p.get("name")=="firmwareVersion":
    print(i); break
' 2>/dev/null || true
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

assert_catalog_seeded() {
  local catalog_ok=0 catalog_json
  for a in $(seq 1 30); do
    catalog_json="$(curl -fsS --max-time 5 http://127.0.0.1:3100/api/firmwares 2>/dev/null || true)"
    if echo "$catalog_json" | grep -q 'virtual-thermal-ecu' \
       && echo "$catalog_json" | grep -q 'sim-1.0.0' \
       && echo "$catalog_json" | grep -q 'sim-1.1.0'; then
      catalog_ok=1
      break
    fi
    sleep 2
  done
  [[ "$catalog_ok" == 1 ]] || {
    log "FAIL: firmware-catalog missing virtual-thermal-ecu sim-1.0.0 and sim-1.1.0"
    echo "$catalog_json" | head -c 800 || true
    return 1
  }
  # Edge must reach the catalog on the compose network (CloudCore OTA download path).
  podman exec "$EDGE" curl -fsS --max-time 5 \
    "http://firmware-catalog:3100/api/download?name=virtual-thermal-ecu&version=sim-1.1.0" \
    -o /dev/null \
    || { log "FAIL: edge cannot download sim-1.1.0 from firmware-catalog"; return 1; }
  log "catalog seeded + edge can download via http://firmware-catalog:3100"
}

# Full CloudCore → Device twin → mapper → catalog → ECU → DeviceStatus path.
cloud_initiated_firmware_ota() {
  local target="$1"
  local fw_idx desired observed reported ecu_ver ok stamp_before stamp_after

  fw_idx="$(fw_property_index)"
  [[ -n "$fw_idx" ]] || { log "FAIL: cannot resolve firmwareVersion property index"; return 1; }

  desired="$(device_desired_fw)"
  observed="$(twin_fw_field observedDesired)"
  reported="$(twin_fw_field reported)"
  ecu_ver="$(ecu_health_version)"
  log "pre-OTA state desired=${desired} observedDesired=${observed} reported=${reported} ecu=${ecu_ver}"

  stamp_before="$(podman exec "$EDGE" sh -c 'wc -l < /var/log/continuumx-catalog-fetch.log 2>/dev/null || echo 0')"
  stamp_before="${stamp_before//[^0-9]/}"
  stamp_before="${stamp_before:-0}"

  log "CloudCore patch: Device/${DEVICE} firmwareVersion.desired → ${target} (index ${fw_idx})"
  podman exec "$CLOUD" kubectl patch device "$DEVICE" -n default --type=json \
    -p="[{\"op\":\"test\",\"path\":\"/spec/properties/${fw_idx}/name\",\"value\":\"firmwareVersion\"},{\"op\":\"replace\",\"path\":\"/spec/properties/${fw_idx}/desired/value\",\"value\":\"${target}\"}]" \
    >/dev/null

  # Spec must reflect the cloud write immediately.
  desired="$(device_desired_fw)"
  [[ "$desired" == "$target" ]] || {
    log "FAIL: Device.spec desired is '${desired}', expected '${target}' after cloud patch"
    return 1
  }
  log "Device.spec.desired=${desired} (cloud write accepted)"

  ok=0
  for a in $(seq 1 90); do
    desired="$(device_desired_fw)"
    observed="$(twin_fw_field observedDesired)"
    reported="$(twin_fw_field reported)"
    ecu_ver="$(ecu_health_version)"
    log "fw[${target}] attempt$a desired=${desired} observedDesired=${observed} reported=${reported} ecu=${ecu_ver}"
    if [[ "$desired" == "$target" \
       && "$observed" == "$target" \
       && "$reported" == "$target" \
       && "$ecu_ver" == "$target" ]]; then
      ok=1
      break
    fi
    sleep 2
  done

  [[ "$ok" == 1 ]] || {
    log "FAIL: CloudCore-initiated OTA to ${target} did not converge"
    podman exec "$CLOUD" kubectl get device "$DEVICE" -n default -o yaml | tail -80 || true
    podman exec "$CLOUD" kubectl get devicestatus "$DEVICE" -n default -o yaml | tail -100 || true
    podman exec "$EDGE" journalctl -u continuumx-virtual-ecu -n 50 --no-pager || true
    podman exec "$EDGE" journalctl -u continuumx-virtual-ethernet-mapper -n 80 --no-pager || true
    podman exec "$EDGE" cat /var/log/continuumx-catalog-fetch.log 2>/dev/null || true
    return 1
  }

  # Catalog fetch must have recorded this version after the cloud patch.
  stamp_after="$(podman exec "$EDGE" sh -c 'wc -l < /var/log/continuumx-catalog-fetch.log 2>/dev/null || echo 0')"
  stamp_after="${stamp_after//[^0-9]/}"
  stamp_after="${stamp_after:-0}"
  if ! podman exec "$EDGE" grep -q "fetched virtual-thermal-ecu@${target}" \
      /var/log/continuumx-catalog-fetch.log; then
    log "FAIL: missing catalog fetch stamp for ${target}"
    podman exec "$EDGE" cat /var/log/continuumx-catalog-fetch.log 2>/dev/null || true
    return 1
  fi
  if [[ "$stamp_after" -le "$stamp_before" ]]; then
    log "FAIL: catalog fetch log did not grow after cloud patch to ${target} (before=${stamp_before} after=${stamp_after})"
    return 1
  fi
  if ! podman exec "$EDGE" test -x \
      "/opt/continuumx/firmware-candidates/virtual-thermal-ecu-${target}"; then
    log "FAIL: catalog download did not stage candidate for ${target}"
    return 1
  fi

  log "PASS CloudCore OTA → ${target} (desired=observedDesired=reported=ecu, catalog fetch ok)"
}

verify_e2e() {
  local label="$1"
  log "=== verify: $label ==="

  podman exec "$CLOUD" kubectl get nodes -o wide
  local nodes
  nodes=$(podman exec "$CLOUD" kubectl get nodes --no-headers 2>/dev/null | wc -l)
  [[ "$nodes" -ge 2 ]] || { log "FAIL: expected 2 nodes, got $nodes"; return 1; }

  # CloudCore must be up (Router :9443 already gated; also check deployment/pod).
  podman exec "$CLOUD" kubectl -n kubeedge get deploy cloudcore >/dev/null 2>&1 \
    || podman exec "$CLOUD" kubectl get pods -A 2>/dev/null | grep -qi cloudcore \
    || { log "FAIL: cloudcore not found in cluster"; podman exec "$CLOUD" kubectl get pods -A || true; return 1; }
  log "CloudCore present in cluster"

  podman exec "$EDGE" getent hosts cloud u2deb-cloud mqtt-broker firmware-catalog >/dev/null
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
  [[ "$ver" == "sim-1.0.0" ]] \
    || { log "FAIL: expected boot baseline sim-1.0.0, got '${ver}'"; return 1; }
  if ! podman exec "$EDGE" grep -q 'fetched virtual-thermal-ecu@sim-1.0.0' \
      /var/log/continuumx-catalog-fetch.log; then
    log "FAIL: missing catalog fetch stamp for boot baseline sim-1.0.0"
    podman exec "$EDGE" cat /var/log/continuumx-catalog-fetch.log 2>/dev/null || true
    return 1
  fi
  log "boot sim-1.0.0 confirmed via catalog download"

  local device_ok=0
  for a in $(seq 1 45); do
    if podman exec "$CLOUD" kubectl get device "$DEVICE" -n default >/dev/null 2>&1 \
       && podman exec "$CLOUD" kubectl get devicestatus "$DEVICE" -n default \
            -o jsonpath='{.status.twins[*].propertyName}' 2>/dev/null | grep -q firmwareVersion; then
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

  # Initial firmware twin must already show sim-1.0.0 from the cloud side.
  local init_ok=0 desired observed reported
  for a in $(seq 1 45); do
    desired="$(device_desired_fw)"
    observed="$(twin_fw_field observedDesired)"
    reported="$(twin_fw_field reported)"
    log "fw baseline attempt$a desired=${desired} observedDesired=${observed} reported=${reported}"
    if [[ "$desired" == "sim-1.0.0" && "$reported" == "sim-1.0.0" ]]; then
      init_ok=1
      break
    fi
    sleep 2
  done
  [[ "$init_ok" == 1 ]] || {
    log "FAIL: cloud twin not reporting boot firmware sim-1.0.0"
    podman exec "$CLOUD" kubectl get device,devicestatus "$DEVICE" -n default -o yaml | tail -120 || true
    return 1
  }
  log "cloud twin baseline: desired/reported=sim-1.0.0"

  # Coolant twin patch (index 14) — proves DeviceTwin path before firmware OTA.
  podman exec "$CLOUD" kubectl patch device "$DEVICE" -n default --type=json \
    -p='[{"op":"test","path":"/spec/properties/14/name","value":"targetCoolantTemperature"},{"op":"replace","path":"/spec/properties/14/desired/value","value":"63.0"}]' \
    >/dev/null

  local twin_ok=0
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

  assert_catalog_seeded || return 1

  # --- Full firmware update cycle initiated from the cloud ---
  cloud_initiated_firmware_ota sim-1.1.0 || return 1
  cloud_initiated_firmware_ota sim-1.0.0 || return 1
  cloud_initiated_firmware_ota sim-1.1.0 || return 1

  log "PASS: $label (CloudCore firmware OTA cycle complete)"
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
