#!/bin/bash
# Apply automotive DeviceModel + Device once the edge node is Ready.
#
# Manifests live at /opt/cx/devices/ (copied from manifests/samples/devices).

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

echo "applying device model + instance"
kubectl apply -f /opt/cx/devices/device-model.yaml
kubectl apply -f /opt/cx/devices/device-instance.yaml

# Wait until DeviceStatus appears (mapper reports via DMI).
echo "waiting for DeviceStatus twins"
ok=0
for _ in $(seq 1 60); do
  twins=$(kubectl get devicestatus automotive-thermal-ecu-001 -n default \
    -o jsonpath='{.status.twins[*].propertyName}' 2>/dev/null || true)
  if echo "$twins" | grep -q 'coolantTemperature' \
     && echo "$twins" | grep -q 'targetCoolantTemperature'; then
    ok=1
    break
  fi
  sleep 2
done

kubectl get devicemodel,device,devicestatus -n default || true

if [[ "$ok" != 1 ]]; then
  echo "warning: DeviceStatus twins not ready yet (mapper may still be starting)"
  echo "  check: kubectl get devicestatus automotive-thermal-ecu-001 -o yaml"
  # Do not fail cloud bootstrap hard - edge mapper starts after join.
  exit 0
fi

echo "device twin resources ready"
