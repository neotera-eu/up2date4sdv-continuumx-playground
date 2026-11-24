# Docker playground — demonstration steps

Run these after `cd docker && make run` and `make info` shows cloud and edge ready. Commands that say **cloud** run inside the cloud container. Commands that say **edge** run inside the edge container. Commands that say **host** run on the machine that started Compose.

```bash
CLOUD=continuumx-playground_cloud_1
EDGE=continuumx-playground_edge_1
```

Each part is independent of the later parts, except firmware updates, which expect both ECUs to be running.

## 1. Cloud and edge nodes

**cloud**

```bash
kubectl get nodes -o wide
kubectl -n kubeedge get deploy,pods
```

Pass: `u2deb-cloud` and `u2deb-edge` are `Ready`. A CloudCore deployment exists.

Catalog download proof (SHA-256 of the catalog object equals the file staged on the edge) is in [docker-firmware-catalog-test.md](docker-firmware-catalog-test.md).

## 2. Firmware catalog

**host**

```bash
curl -fsS http://127.0.0.1:3100/api/health
curl -fsS http://127.0.0.1:3100/api/firmwares
```

Open http://127.0.0.1:3100.

Pass: the list contains `virtual-thermal-ecu` and `virtual-tire-pressure-ecu`, each at `sim-1.0.0` and `sim-1.1.0`.

## 3. Both ECU processes (catalog boot)

**edge**

```bash
systemctl is-active \
  continuumx-virtual-thermal-ecu \
  continuumx-virtual-tire-ecu \
  continuumx-virtual-ethernet-mapper

curl -fsS --unix-socket /run/continuumx-virtual-thermal-ecu/ecu.sock \
  http://localhost/v1/health
curl -fsS --unix-socket /run/continuumx-virtual-tire-ecu/ecu.sock \
  http://localhost/v1/health

grep fetched /var/log/continuumx-catalog-fetch.log
```

Pass: three units are `active`. Both health documents show `"firmwareVersion":"sim-1.0.0"`. The log contains a fetch line for each ECU at `sim-1.0.0`.

## 4. Both device twins

**cloud**

```bash
kubectl get devicemodel,device,devicestatus -n default

kubectl get devicestatus automotive-thermal-ecu-fw-001 -n default -o json \
  | jq -r '.status.twins[] | select(.propertyName=="firmwareVersion") | .reported.value'

kubectl get devicestatus automotive-tire-pressure-ecu-fw-001 -n default -o json \
  | jq -r '.status.twins[] | select(.propertyName=="firmwareVersion") | .reported.value'
```

Pass: both models and both devices exist. Both reported firmware values are `sim-1.0.0`. Thermal status includes `coolantTemperature`. Tire status includes `frontLeftPressure`.

## 5. Thermal coolant setpoint

**cloud** — find the property index, then patch only that field:

```bash
DEV=automotive-thermal-ecu-fw-001
IDX=$(kubectl get device "$DEV" -n default -o json | jq -r \
  '.spec.properties | to_entries[] | select(.value.name=="targetCoolantTemperature") | .key')

kubectl patch device "$DEV" -n default --type=json \
  -p="[{\"op\":\"test\",\"path\":\"/spec/properties/$IDX/name\",\"value\":\"targetCoolantTemperature\"},{\"op\":\"replace\",\"path\":\"/spec/properties/$IDX/desired/value\",\"value\":\"63.0\"}]"

kubectl get devicestatus "$DEV" -n default -o json | jq -r \
  '.status.twins[] | select(.propertyName=="targetCoolantTemperature") |
   "observedDesired=\(.observedDesired.value) reported=\(.reported.value)"'
```

Repeat the status command until both values are `63` or `63.0`. That can take one report cycle (about 10 seconds).

## 6. Tire leak, thermal unchanged

**cloud**

```bash
DEV=automotive-tire-pressure-ecu-fw-001
FL=$(kubectl get devicestatus "$DEV" -n default -o json | jq -r \
  '.status.twins[] | select(.propertyName=="frontLeftPressure") | .reported.value')
echo "frontLeftPressure=$FL"

patch_prop() {
  local name="$1" value="$2"
  local idx
  idx=$(kubectl get device "$DEV" -n default -o json | jq -r \
    --arg n "$name" '.spec.properties | to_entries[] | select(.value.name==$n) | .key')
  kubectl patch device "$DEV" -n default --type=json \
    -p="[{\"op\":\"test\",\"path\":\"/spec/properties/$idx/name\",\"value\":\"$name\"},{\"op\":\"replace\",\"path\":\"/spec/properties/$idx/desired/value\",\"value\":\"$value\"}]"
}

patch_prop leakWheel FL
patch_prop leakRate 10
patch_prop pressureThreshold "$FL"
patch_prop leakEnabled true
```

Watch until the warning appears:

```bash
kubectl get devicestatus "$DEV" -n default -o json | jq -r \
  '.status.twins[] | select(.propertyName=="frontLeftPressure" or .propertyName=="lowPressureWarning" or .propertyName=="lowPressureWheels") |
   "\(.propertyName)=\(.reported.value)"'
```

Pass: `lowPressureWarning` is `true` and `lowPressureWheels` contains `FL`. Then turn the leak off:

```bash
patch_prop leakEnabled false
```

Confirm the thermal setpoint is still 63:

```bash
kubectl get devicestatus automotive-thermal-ecu-fw-001 -n default -o json | jq -r \
  '.status.twins[] | select(.propertyName=="targetCoolantTemperature") | .reported.value'
```

## 7. Independent firmware updates

Record PIDs on the **edge** before any patch:

```bash
systemctl show -p MainPID --value continuumx-virtual-ethernet-mapper
systemctl show -p MainPID --value continuumx-virtual-thermal-ecu
systemctl show -p MainPID --value continuumx-virtual-tire-ecu
```

**cloud**, tire ECU first:

```bash
DEV=automotive-tire-pressure-ecu-fw-001
IDX=$(kubectl get device "$DEV" -n default -o json | jq -r \
  '.spec.properties | to_entries[] | select(.value.name=="firmwareVersion") | .key')
kubectl patch device "$DEV" -n default --type=json \
  -p="[{\"op\":\"test\",\"path\":\"/spec/properties/$IDX/name\",\"value\":\"firmwareVersion\"},{\"op\":\"replace\",\"path\":\"/spec/properties/$IDX/desired/value\",\"value\":\"sim-1.1.0\"}]"
```

Wait until tire `DeviceStatus` reported firmware and the tire health socket both show `sim-1.1.0`. On the **edge**, the tire PID must change. The mapper PID and the thermal PID must stay the same. Thermal health must still be `sim-1.0.0`.

```bash
curl -fsS --unix-socket /run/continuumx-virtual-tire-ecu/ecu.sock http://localhost/v1/health
curl -fsS --unix-socket /run/continuumx-virtual-thermal-ecu/ecu.sock http://localhost/v1/health
grep 'virtual-tire-pressure-ecu@sim-1.1.0' /var/log/continuumx-catalog-fetch.log
```

Then the thermal ECU, same patch with `DEV=automotive-thermal-ecu-fw-001`. After it converges, only the thermal PID has changed. Tire health stays `sim-1.1.0`. The fetch log contains `virtual-thermal-ecu@sim-1.1.0`.

## 8. NGINX on the edge

**host**

```bash
curl -fsS http://127.0.0.1:8080/ | head
```

**cloud**

```bash
kubectl get pods -o wide -l app=nginx-edge
```

Pass: the curl output is the NGINX welcome page, and the pod is `Running` on `u2deb-edge`.

## 9. ServiceBus

**host**

```bash
curl -fsS http://127.0.0.1:3000/api/health
curl -fsS -X POST http://127.0.0.1:3000/api/trigger \
  -H 'content-type: application/json' \
  -d '{"msg":"hello via ServiceBus"}'
```

Pass: the trigger response contains `"ok":true`.

## Automated check

From `docker/`:

```bash
./e2e-cold-test.sh
```

This cold-starts the stack and runs parts 1–9, including the PID isolation checks.
