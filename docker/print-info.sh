#!/usr/bin/env bash
# Print SSH, URLs and MQTT info for the running playground.
#
# You may set PLAYGROUND_HOST if you connect from another machine
# (default 127.0.0.1).

set -euo pipefail

HOST="${PLAYGROUND_HOST:-127.0.0.1}"

svc_status() {
  # Print running / exited / missing for a compose container name.
  local name="$1" state
  state=$(podman inspect -f '{{.State.Status}}' "$name" 2>/dev/null || echo missing)
  printf '%s' "$state"
}

mqtt_ctr=$(svc_status continuumx-playground_mqtt-broker_1)
cloud_ctr=$(svc_status continuumx-playground_cloud_1)
edge_ctr=$(svc_status continuumx-playground_edge_1)
demo_ctr=$(svc_status continuumx-playground_servicebus-demo_1)
fw_ctr=$(svc_status continuumx-playground_firmware-catalog_1)

# Ready = service is usable (not only that the container process is up).
mqtt_ready=no
cloud_ready=no
edge_ready=no
demo_ready=no
fw_ready=no
mapper_ready=no
ecu_ready=no
device_ready=no
# Prefer compose health when present, else treat running as ready.
mqtt_health=$(podman inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{end}}' \
  continuumx-playground_mqtt-broker_1 2>/dev/null || true)
if [[ "$mqtt_health" == healthy ]]; then
  mqtt_ready=yes
elif [[ "$mqtt_ctr" == running && -z "$mqtt_health" ]]; then
  mqtt_ready=yes
fi
podman exec continuumx-playground_cloud_1 test -f /var/cx-join/cloud-ready 2>/dev/null \
  && podman exec continuumx-playground_cloud_1 bash -c 'ss -lnt 2>/dev/null | grep -q ":9443 "' 2>/dev/null \
  && cloud_ready=yes || true
podman exec continuumx-playground_edge_1 systemctl is-active --quiet edgecore 2>/dev/null \
  && edge_ready=yes || true
curl -sfS --max-time 2 "http://${HOST}:3000/api/health" >/dev/null 2>&1 \
  && demo_ready=yes || true
curl -sfS --max-time 2 "http://${HOST}:3100/api/health" >/dev/null 2>&1 \
  && fw_ready=yes || true
podman exec continuumx-playground_edge_1 \
  systemctl is-active --quiet continuumx-virtual-ethernet-mapper 2>/dev/null \
  && mapper_ready=yes || true
podman exec continuumx-playground_edge_1 \
  systemctl is-active --quiet continuumx-virtual-ecu 2>/dev/null \
  && ecu_ready=yes || true
podman exec continuumx-playground_cloud_1 \
  kubectl get device automotive-thermal-ecu-fw-001 -n default >/dev/null 2>&1 \
  && device_ready=yes || true

cat <<EOF

============================================================
 ContinuumX Playground - quick start
============================================================

  Status
    mqtt-broker      : container=${mqtt_ctr}  ready=${mqtt_ready}
    cloud            : container=${cloud_ctr}  ready=${cloud_ready}
    edge             : container=${edge_ctr}  ready=${edge_ready}
    servicebus-demo  : container=${demo_ctr}  ready=${demo_ready}
    firmware-catalog : container=${fw_ctr}  ready=${fw_ready}
    virtual-ecu      : continuumx-virtual-ecu  ready=${ecu_ready}
    mapper           : continuumx-virtual-ethernet-mapper  ready=${mapper_ready}
    device-twin      : automotive-thermal-ecu-fw-001  ready=${device_ready}
    (first cold start usually finishes in about 1-2 minutes)

------------------------------------------------------------
  SSH  (user / password)
------------------------------------------------------------
  Cloud   ssh -p 2222 user@${HOST}     password: user123
  Edge    ssh -p 2223 user@${HOST}     password: user123

  On cloud, kubectl as root:
    ssh -p 2222 user@${HOST}
    sudo -i
    kubectl get nodes
    kubectl get pods -A

------------------------------------------------------------
  Firmware catalog (OTA store)
------------------------------------------------------------
  UI           http://${HOST}:3100
  Health       http://${HOST}:3100/api/health
  List         http://${HOST}:3100/api/firmwares
  Download     http://${HOST}:3100/api/download?name=<name>&version=<ver>

------------------------------------------------------------
  Device twin + Virtual ECU firmware update
------------------------------------------------------------
  Edge services:
    continuumx-virtual-ecu.service
    continuumx-virtual-ethernet-mapper.service

  ECU health (inside edge):
    curl --unix-socket /run/continuumx-virtual-ecu/ecu.sock http://localhost/v1/health

  On cloud:
    kubectl get devicemodel,device,devicestatus -n default
    kubectl get device automotive-thermal-ecu-fw-001 -n default -o json \\
      | jq -r '.spec.properties[] | select(.name=="firmwareVersion") | .desired.value'
    kubectl get devicestatus automotive-thermal-ecu-fw-001 -n default -o json \\
      | jq -r '.status.twins[]? | select(.propertyName=="firmwareVersion") |
          "observedDesired=\\(.observedDesired.value) reported=\\(.reported.value)"'

  Firmware source: catalog only (bin/ecu published at :3100).
  Boot downloads sim-1.0.0; twin OTA downloads sim-1.1.0. No baked edge candidates.
  Patch desired firmware to sim-1.1.0 (index 10 = firmwareVersion):
    kubectl patch device automotive-thermal-ecu-fw-001 -n default --type=json \\
      -p='[{"op":"test","path":"/spec/properties/10/name","value":"firmwareVersion"},
           {"op":"replace","path":"/spec/properties/10/desired/value","value":"sim-1.1.0"}]'
  Catalog packages:
    http://${HOST}:3100/api/download?name=virtual-thermal-ecu&version=sim-1.0.0
    http://${HOST}:3100/api/download?name=virtual-thermal-ecu&version=sim-1.1.0

  Patch desired coolant target to 63.0 (index 14):
    kubectl patch device automotive-thermal-ecu-fw-001 -n default --type=json \\
      -p='[{"op":"test","path":"/spec/properties/14/name","value":"targetCoolantTemperature"},
           {"op":"replace","path":"/spec/properties/14/desired/value","value":"63.0"}]'

------------------------------------------------------------
  ServiceBus demo (Next.js)
------------------------------------------------------------
  UI           http://${HOST}:3000
  Health       http://${HOST}:3000/api/health
  Request log  http://${HOST}:3000/api/requests
  Trigger      curl -sS -X POST http://${HOST}:3000/api/trigger \\
                 -H 'content-type: application/json' \\
                 -d '{"msg":"hello via ServiceBus"}'

  CloudCore Router (host -> edge ServiceBus -> demo :3000):
    POST http://${HOST}:9443/u2deb-edge/default/demo

------------------------------------------------------------
  MQTT broker
------------------------------------------------------------
  Host         ${HOST}
  Port         1883
  Auth         anonymous (allow_anonymous true)

  Clients are inside the mqtt-broker container (no need to install
  mosquitto_sub / mosquitto_pub on the host):

  Subscribe (all topics):
    podman exec -it continuumx-playground_mqtt-broker_1 \\
      mosquitto_sub -h 127.0.0.1 -p 1883 -t '#' -v

  Publish:
    podman exec continuumx-playground_mqtt-broker_1 \\
      mosquitto_pub -h 127.0.0.1 -p 1883 -t 'demo/hello' -m 'hi'

  EdgeCore EventBus (mqttMode 2 -> this broker). Common topics:
    \$hw/events/device/+/state/update
    \$hw/events/device/+/twin/+
    \$hw/events/node/+/membership/get
    \$kubeedge/edge/membership/get
    SYS/dis/upload_records

------------------------------------------------------------
  Other ports
------------------------------------------------------------
  Kubernetes API      https://${HOST}:6443
  CloudHub (WS)       ${HOST}:10000
  CloudHub (cert)     ${HOST}:10002
  CloudCore Router    ${HOST}:9443
  NodePort demo       ${HOST}:30080

------------------------------------------------------------
  Make helpers
------------------------------------------------------------
  make info              show this info again
  make down              stop containers
  make delete            remove containers (keep volumes/images)
  make prune             remove containers + volumes + project images

EOF
