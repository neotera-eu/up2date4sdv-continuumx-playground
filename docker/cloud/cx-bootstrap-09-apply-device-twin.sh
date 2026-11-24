#!/bin/bash
# Apply automotive DeviceModel + Device once the edge node is Ready.
#
# Manifests live at /opt/cx/devices/ (copied from manifests/samples/devices).

THERMAL=automotive-thermal-ecu-fw-001
TIRE=automotive-tire-pressure-ecu-fw-001

echo "waiting for edge node u2deb-edge"
for _ in $(seq 1 120); do
  if kubectl get node u2deb-edge >/dev/null 2>&1; then
    ready=$(kubectl get node u2deb-edge \
      -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
    [[ "$ready" == True ]] && break
  fi
  sleep 2
done

ready=$(kubectl get node u2deb-edge \
  -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
if [[ "$ready" != True ]]; then
  echo "error: edge node u2deb-edge not Ready"
  kubectl get nodes -o wide || true
  exit 1
fi

echo "applying thermal + tire-pressure device models and devices"
kubectl apply -f /opt/cx/devices/thermal-device-model.yaml
kubectl apply -f /opt/cx/devices/tire-pressure-device-model.yaml
kubectl apply -f /opt/cx/devices/thermal-device-instance.yaml
kubectl apply -f /opt/cx/devices/tire-pressure-device-instance.yaml

echo "waiting for DeviceStatus twins on ${THERMAL} and ${TIRE}"
ok=0
for _ in $(seq 1 90); do
  thermal=$(kubectl get devicestatus "$THERMAL" -n default \
    -o jsonpath='{.status.twins[*].propertyName}' 2>/dev/null || true)
  tire=$(kubectl get devicestatus "$TIRE" -n default \
    -o jsonpath='{.status.twins[*].propertyName}' 2>/dev/null || true)
  if echo "$thermal" | grep -q 'coolantTemperature' \
     && echo "$thermal" | grep -q 'firmwareVersion' \
     && echo "$tire" | grep -q 'frontLeftPressure' \
     && echo "$tire" | grep -q 'firmwareVersion'; then
    ok=1
    break
  fi
  sleep 2
done

kubectl get devicemodel,device,devicestatus -n default || true

if [[ -f /opt/cx/nginx-edge.yaml ]]; then
  echo "applying nginx edge workload"
  kubectl apply -f /opt/cx/nginx-edge.yaml || echo "warning: nginx apply failed"
fi

if [[ "$ok" != 1 ]]; then
  echo "warning: DeviceStatus twins not ready yet (mapper/ECU may still be starting)"
  exit 0
fi

echo "device twin resources ready"
