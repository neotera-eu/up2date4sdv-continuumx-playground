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
THERMAL=automotive-thermal-ecu-fw-001
TIRE=automotive-tire-pressure-ecu-fw-001
PASS=0
FAIL=0

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }

ecu_health_version() {
  local sock="$1"
  podman exec "$EDGE" curl -sfS --max-time 2 \
    --unix-socket "$sock" \
    http://localhost/v1/health 2>/dev/null \
    | python3 -c 'import sys,json; print(json.load(sys.stdin).get("firmwareVersion",""))' 2>/dev/null || true
}

unit_pid() {
  podman exec "$EDGE" systemctl show -p MainPID --value "$1" 2>/dev/null || true
}

device_desired() {
  local dev="$1" prop="$2"
  podman exec "$CLOUD" kubectl get device "$dev" -n default -o json 2>/dev/null \
    | python3 -c '
import json,sys
prop=sys.argv[1]
d=json.load(sys.stdin)
for p in d.get("spec",{}).get("properties",[]):
  if p.get("name")==prop:
    print((p.get("desired") or {}).get("value",""))
    break
' "$prop" 2>/dev/null || true
}

twin_field() {
  local dev="$1" prop="$2" field="$3"
  podman exec "$CLOUD" kubectl get devicestatus "$dev" -n default -o json 2>/dev/null \
    | python3 -c '
import json,sys
prop,field=sys.argv[1:]
d=json.load(sys.stdin)
for t in d.get("status",{}).get("twins",[]) or []:
  if t.get("propertyName")==prop:
    print((t.get(field) or {}).get("value",""))
    break
' "$prop" "$field" 2>/dev/null || true
}

patch_desired() {
  local dev="$1" prop="$2" value="$3" idx
  idx="$(podman exec "$CLOUD" kubectl get device "$dev" -n default -o json \
    | python3 -c 'import json,sys; prop=sys.argv[1]; d=json.load(sys.stdin); print(next(i for i,p in enumerate(d["spec"]["properties"]) if p.get("name")==prop))' "$prop")"
  [[ -n "$idx" ]] || { echo "missing property ${prop} on ${dev}" >&2; return 1; }
  podman exec "$CLOUD" kubectl patch device "$dev" -n default --type=json \
    -p="[{\"op\":\"test\",\"path\":\"/spec/properties/${idx}/name\",\"value\":\"${prop}\"},{\"op\":\"replace\",\"path\":\"/spec/properties/${idx}/desired/value\",\"value\":\"${value}\"}]" \
    >/dev/null
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
    ecu=$(podman exec "$EDGE" systemctl is-active continuumx-virtual-thermal-ecu 2>/dev/null || true)
    tire=$(podman exec "$EDGE" systemctl is-active continuumx-virtual-tire-ecu 2>/dev/null || true)
    c_boot=${c_boot:-na}; e_boot=${e_boot:-na}; e_core=${e_core:-na}
    mapper=${mapper:-na}; ecu=${ecu:-na}
    podman exec "$CLOUD" bash -c 'ss -lnt 2>/dev/null | grep -q ":9443 "' 2>/dev/null && r9443=yes || true

    log "t+${elapsed}s cloud-boot=$c_boot ready=$c_ready :9443=$r9443 edge-boot=$e_boot edgecore=$e_core thermal=$ecu tire=${tire:-na} mapper=$mapper"

    if [[ "$c_boot" == failed || "$e_boot" == failed ]]; then
      log "bootstrap FAILED"
      podman exec "$CLOUD" journalctl -u cx-bootstrap -n 40 --no-pager 2>&1 | tail -50 || true
      podman exec "$EDGE" journalctl -u cx-bootstrap -n 40 --no-pager 2>&1 | tail -50 || true
      return 1
    fi

    if [[ "$c_ready" == yes && "$r9443" == yes && "$e_core" == active && \
          "$ecu" == active && "${tire:-}" == active && "$mapper" == active && \
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
       && echo "$catalog_json" | grep -q 'virtual-tire-pressure-ecu' \
       && echo "$catalog_json" | grep -q 'sim-1.0.0' \
       && echo "$catalog_json" | grep -q 'sim-1.1.0'; then
      catalog_ok=1
      break
    fi
    sleep 2
  done
  [[ "$catalog_ok" == 1 ]] || {
    log "FAIL: firmware-catalog missing thermal and tire sim-1.0.0 / sim-1.1.0"
    echo "$catalog_json" | head -c 800 || true
    return 1
  }
  podman exec "$EDGE" curl -fsS --max-time 5 \
    "http://firmware-catalog:3100/api/download?name=virtual-tire-pressure-ecu&version=sim-1.1.0" \
    -o /dev/null \
    || { log "FAIL: edge cannot download tire sim-1.1.0 from firmware-catalog"; return 1; }
  log "catalog seeded with both ECUs; edge can download"
}

# CloudCore patch → catalog download → one ECU only.
# $1 device  $2 catalog name  $3 health socket  $4 target version
cloud_initiated_firmware_ota() {
  local dev="$1" name="$2" sock="$3" target="$4"
  local desired observed reported ecu_ver ok stamp_before stamp_after

  stamp_before="$(podman exec "$EDGE" sh -c 'wc -l < /var/log/continuumx-catalog-fetch.log 2>/dev/null || echo 0')"
  stamp_before="${stamp_before//[^0-9]/}"
  stamp_before="${stamp_before:-0}"

  log "CloudCore patch: ${dev} firmwareVersion.desired → ${target}"
  patch_desired "$dev" firmwareVersion "$target"

  desired="$(device_desired "$dev" firmwareVersion)"
  [[ "$desired" == "$target" ]] || {
    log "FAIL: ${dev} desired is '${desired}', expected '${target}'"
    return 1
  }

  ok=0
  for a in $(seq 1 90); do
    desired="$(device_desired "$dev" firmwareVersion)"
    observed="$(twin_field "$dev" firmwareVersion observedDesired)"
    reported="$(twin_field "$dev" firmwareVersion reported)"
    ecu_ver="$(ecu_health_version "$sock")"
    log "fw[${dev} ${target}] attempt$a desired=${desired} observedDesired=${observed} reported=${reported} ecu=${ecu_ver}"
    if [[ "$desired" == "$target" && "$observed" == "$target" \
       && "$reported" == "$target" && "$ecu_ver" == "$target" ]]; then
      ok=1
      break
    fi
    sleep 2
  done
  [[ "$ok" == 1 ]] || {
    log "FAIL: CloudCore OTA ${dev} → ${target} did not converge"
    podman exec "$EDGE" journalctl -u continuumx-virtual-ethernet-mapper -n 80 --no-pager || true
    podman exec "$EDGE" cat /var/log/continuumx-catalog-fetch.log 2>/dev/null || true
    return 1
  }

  stamp_after="$(podman exec "$EDGE" sh -c 'wc -l < /var/log/continuumx-catalog-fetch.log 2>/dev/null || echo 0')"
  stamp_after="${stamp_after//[^0-9]/}"
  stamp_after="${stamp_after:-0}"
  if ! podman exec "$EDGE" grep -q "fetched ${name}@${target}" /var/log/continuumx-catalog-fetch.log; then
    log "FAIL: missing catalog fetch stamp for ${name}@${target}"
    return 1
  fi
  [[ "$stamp_after" -gt "$stamp_before" ]] || {
    log "FAIL: catalog fetch log did not grow for ${name}@${target}"
    return 1
  }
  podman exec "$EDGE" test -x "/opt/continuumx/firmware-candidates/${name}-${target}" \
    || { log "FAIL: candidate not staged for ${name}@${target}"; return 1; }
  log "PASS CloudCore OTA ${dev} → ${target}"
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

  podman exec "$EDGE" systemctl is-active --quiet continuumx-virtual-thermal-ecu \
    || { log "FAIL: thermal ECU inactive"; return 1; }
  podman exec "$EDGE" systemctl is-active --quiet continuumx-virtual-tire-ecu \
    || { log "FAIL: tire ECU inactive"; return 1; }
  podman exec "$EDGE" systemctl is-active --quiet continuumx-virtual-ethernet-mapper \
    || { log "FAIL: mapper inactive"; return 1; }
  podman exec "$EDGE" test -S /etc/kubeedge/dmi.sock \
    || { log "FAIL: missing dmi.sock"; return 1; }
  podman exec "$EDGE" test -S /run/continuumx-virtual-thermal-ecu/ecu.sock \
    || { log "FAIL: missing thermal socket"; return 1; }
  podman exec "$EDGE" test -S /run/continuumx-virtual-tire-ecu/ecu.sock \
    || { log "FAIL: missing tire socket"; return 1; }

  local thermal_ver tire_ver
  thermal_ver="$(ecu_health_version /run/continuumx-virtual-thermal-ecu/ecu.sock)"
  tire_ver="$(ecu_health_version /run/continuumx-virtual-tire-ecu/ecu.sock)"
  log "health thermal=${thermal_ver} tire=${tire_ver}"
  [[ "$thermal_ver" == "sim-1.0.0" && "$tire_ver" == "sim-1.0.0" ]] \
    || { log "FAIL: expected both ECUs at sim-1.0.0"; return 1; }
  podman exec "$EDGE" grep -q 'fetched virtual-thermal-ecu@sim-1.0.0' /var/log/continuumx-catalog-fetch.log \
    && podman exec "$EDGE" grep -q 'fetched virtual-tire-pressure-ecu@sim-1.0.0' /var/log/continuumx-catalog-fetch.log \
    || { log "FAIL: boot firmware was not fetched from the catalog"; return 1; }
  log "PASS boot: both ECUs sim-1.0.0 from catalog"

  local device_ok=0
  for a in $(seq 1 45); do
    if podman exec "$CLOUD" kubectl get devicestatus "$THERMAL" -n default \
         -o jsonpath='{.status.twins[*].propertyName}' 2>/dev/null | grep -q coolantTemperature \
       && podman exec "$CLOUD" kubectl get devicestatus "$TIRE" -n default \
         -o jsonpath='{.status.twins[*].propertyName}' 2>/dev/null | grep -q frontLeftPressure; then
      device_ok=1
      break
    fi
    sleep 2
  done
  [[ "$device_ok" == 1 ]] || {
    log "FAIL: both DeviceStatus resources not ready"
    podman exec "$CLOUD" kubectl get devicemodel,device,devicestatus -n default || true
    return 1
  }

  local init_ok=0
  for a in $(seq 1 45); do
    if [[ "$(twin_field "$THERMAL" firmwareVersion reported)" == "sim-1.0.0" \
       && "$(twin_field "$TIRE" firmwareVersion reported)" == "sim-1.0.0" ]]; then
      init_ok=1
      break
    fi
    sleep 2
  done
  [[ "$init_ok" == 1 ]] || { log "FAIL: cloud twins not reporting sim-1.0.0"; return 1; }
  log "PASS twins: both devices report sim-1.0.0"

  log "PART coolant setpoint"
  patch_desired "$THERMAL" targetCoolantTemperature 63.0
  local twin_ok=0 observed reported
  for a in $(seq 1 45); do
    observed="$(twin_field "$THERMAL" targetCoolantTemperature observedDesired)"
    reported="$(twin_field "$THERMAL" targetCoolantTemperature reported)"
    log "coolant attempt$a observedDesired=$observed reported=$reported"
    if echo "$observed" | grep -Eq '^63(\.0)?$' && echo "$reported" | grep -Eq '^63(\.0)?$'; then
      twin_ok=1
      break
    fi
    sleep 3
  done
  [[ "$twin_ok" == 1 ]] || { log "FAIL: coolant setpoint"; return 1; }
  log "PASS coolant setpoint 63.0"

  log "PART tire leak"
  local fl start_fl
  fl="$(twin_field "$TIRE" frontLeftPressure reported)"
  start_fl="$fl"
  [[ -n "$fl" ]] || { log "FAIL: no frontLeftPressure yet"; return 1; }
  patch_desired "$TIRE" leakWheel FL
  patch_desired "$TIRE" leakRate 10
  patch_desired "$TIRE" pressureThreshold "$fl"
  patch_desired "$TIRE" leakEnabled true
  local leak_ok=0 warn wheels
  for a in $(seq 1 40); do
    fl="$(twin_field "$TIRE" frontLeftPressure reported)"
    warn="$(twin_field "$TIRE" lowPressureWarning reported)"
    wheels="$(twin_field "$TIRE" lowPressureWheels reported)"
    log "leak attempt$a fl=${fl} warn=${warn} wheels=${wheels}"
    if [[ "$warn" == "true" || "$warn" == "True" ]] && echo "$wheels" | grep -q FL; then
      leak_ok=1
      break
    fi
    sleep 3
  done
  patch_desired "$TIRE" leakEnabled false || true
  [[ "$leak_ok" == 1 ]] || { log "FAIL: tire leak warning did not appear (start fl=${start_fl})"; return 1; }
  [[ "$(twin_field "$THERMAL" targetCoolantTemperature reported)" == "63" \
    || "$(twin_field "$THERMAL" targetCoolantTemperature reported)" == "63.0" ]] \
    || { log "FAIL: thermal twin changed during tire leak"; return 1; }
  log "PASS tire leak warning; thermal twin unchanged"

  assert_catalog_seeded || return 1

  log "PART independent firmware updates"
  local pid_mapper pid_thermal pid_tire
  pid_mapper="$(unit_pid continuumx-virtual-ethernet-mapper.service)"
  pid_thermal="$(unit_pid continuumx-virtual-thermal-ecu.service)"
  pid_tire="$(unit_pid continuumx-virtual-tire-ecu.service)"
  log "pids before mapper=${pid_mapper} thermal=${pid_thermal} tire=${pid_tire}"

  cloud_initiated_firmware_ota "$TIRE" virtual-tire-pressure-ecu \
    /run/continuumx-virtual-tire-ecu/ecu.sock sim-1.1.0 || return 1
  [[ "$(unit_pid continuumx-virtual-ethernet-mapper.service)" == "$pid_mapper" ]] \
    || { log "FAIL: mapper restarted during tire OTA"; return 1; }
  [[ "$(unit_pid continuumx-virtual-thermal-ecu.service)" == "$pid_thermal" ]] \
    || { log "FAIL: thermal ECU restarted during tire OTA"; return 1; }
  [[ "$(unit_pid continuumx-virtual-tire-ecu.service)" != "$pid_tire" ]] \
    || { log "FAIL: tire ECU pid did not change"; return 1; }
  [[ "$(ecu_health_version /run/continuumx-virtual-thermal-ecu/ecu.sock)" == "sim-1.0.0" ]] \
    || { log "FAIL: thermal firmware changed during tire OTA"; return 1; }
  log "PASS tire OTA isolated"

  pid_tire="$(unit_pid continuumx-virtual-tire-ecu.service)"
  cloud_initiated_firmware_ota "$THERMAL" virtual-thermal-ecu \
    /run/continuumx-virtual-thermal-ecu/ecu.sock sim-1.1.0 || return 1
  [[ "$(unit_pid continuumx-virtual-ethernet-mapper.service)" == "$pid_mapper" ]] \
    || { log "FAIL: mapper restarted during thermal OTA"; return 1; }
  [[ "$(unit_pid continuumx-virtual-tire-ecu.service)" == "$pid_tire" ]] \
    || { log "FAIL: tire ECU restarted during thermal OTA"; return 1; }
  [[ "$(unit_pid continuumx-virtual-thermal-ecu.service)" != "$pid_thermal" ]] \
    || { log "FAIL: thermal ECU pid did not change"; return 1; }
  log "PASS thermal OTA isolated"

  log "PART nginx edge workload"
  local nginx_ok=0
  for a in $(seq 1 30); do
    if curl -fsS --max-time 3 http://127.0.0.1:8080/ 2>/dev/null | grep -qi nginx; then
      nginx_ok=1
      break
    fi
    sleep 2
  done
  [[ "$nginx_ok" == 1 ]] || {
    log "FAIL: nginx on :8080 did not respond"
    podman exec "$CLOUD" kubectl get pods -o wide || true
    podman exec "$CLOUD" kubectl describe pod -l app=nginx-edge || true
    return 1
  }
  log "PASS nginx edge workload"

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
