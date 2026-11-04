#!/bin/bash
# Patch edgecore.yaml for this playground.
#
# You may change:
# - mqttServerExternal (MQTT broker address)
# - mqttMode (2 = external broker only)
# - serviceBus server/port (HTTP target on the edge, default 127.0.0.1:3000 via rules)

cfg=/etc/kubeedge/config/edgecore.yaml
[[ -f "$cfg" ]] || return 0 2>/dev/null || exit 0

if ! grep -q 'KubeletInUserNamespace:' "$cfg"; then
  sed -i '/tailoredKubeletConfig:/a\      featureGates:\n        KubeletInUserNamespace: true' "$cfg"
fi
sed -i 's/oomScoreAdj: -999/oomScoreAdj: 0/' "$cfg" || true
sed -i 's/^      - pods$/      # - pods/' "$cfg" || true

sed -i 's|^    mqttMode: .*|    mqttMode: 2|' "$cfg"
sed -i 's|^    mqttServerExternal: .*|    mqttServerExternal: tcp://mqtt-broker:1883|' "$cfg"

sed -i '/^  serviceBus:/,/^  [a-zA-Z]/{
  s|^    enable: .*|    enable: true|
  s|^    port: .*|    port: 9060|
  s|^    server: .*|    server: 127.0.0.1|
  s|^    timeout: .*|    timeout: 60|
}' "$cfg"
