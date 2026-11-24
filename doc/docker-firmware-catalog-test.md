# Test: firmware is retrieved from the catalog

Use this after the Docker playground is up (`cd docker && make run`). Every command runs on the **host**. The edge image does not contain ECU binaries. Boot and each twin update download them from `http://firmware-catalog:3100`.

```bash
CLOUD=continuumx-playground_cloud_1
EDGE=continuumx-playground_edge_1
```

Pass means the SHA-256 published by the catalog equals the file the edge staged, and the fetch log names that catalog URL.

## 1. Catalog is the publisher

```bash
curl -fsS http://127.0.0.1:3100/api/health
curl -fsS http://127.0.0.1:3100/api/firmwares | jq -r \
  '.items[] | "\(.name)@\(.version) \(.sha256) \(.size)"'
```

Pass: four rows.

| Name | Versions |
|---|---|
| `virtual-thermal-ecu` | `sim-1.0.0`, `sim-1.1.0` |
| `virtual-tire-pressure-ecu` | `sim-1.0.0`, `sim-1.1.0` |

The UI is http://127.0.0.1:3100. A direct download is:

```bash
curl -fsS -o /tmp/thermal-sim-1.1.0.bin \
  'http://127.0.0.1:3100/api/download?name=virtual-thermal-ecu&version=sim-1.1.0'
sha256sum /tmp/thermal-sim-1.1.0.bin
```

That digest must equal the `virtual-thermal-ecu@sim-1.1.0` value from the list above.

## 2. Boot copies came from the catalog

On a fresh start the edge log records both baselines before either ECU is healthy:

```bash
podman exec "$EDGE" cat /var/log/continuumx-catalog-fetch.log
```

Pass: one line for each of these URLs (later updates append more lines):

```text
http://firmware-catalog:3100/api/download?name=virtual-thermal-ecu&version=sim-1.0.0
http://firmware-catalog:3100/api/download?name=virtual-tire-pressure-ecu&version=sim-1.0.0
```

Compare every staged file with the catalog record:

```bash
podman exec "$EDGE" bash -c 'sha256sum /opt/continuumx/firmware-candidates/*' \
  | while read -r sum path; do
      base=$(basename "$path")
      name=${base%-sim-*}
      ver=${base##*-ecu-}
      cat_sum=$(curl -fsS http://127.0.0.1:3100/api/firmwares | jq -r \
        --arg n "$name" --arg v "$ver" \
        '.items[] | select(.name==$n and .version==$v) | .sha256')
      if [[ "$sum" == "$cat_sum" ]]; then
        echo "MATCH $name@$ver"
      else
        echo "MISMATCH $name@$ver edge=$sum catalog=$cat_sum"
        exit 1
      fi
    done
```

Pass: four `MATCH` lines. The running thermal and tire binaries are those same downloads:

```bash
podman exec "$EDGE" sha256sum \
  /opt/continuumx/virtual-thermal-ecu/virtual-thermal-ecu \
  /opt/continuumx/virtual-tire-pressure-ecu/virtual-tire-pressure-ecu
```

Each digest equals the catalog entry for the version reported by health:

```bash
podman exec "$EDGE" curl -fsS --unix-socket /run/continuumx-virtual-thermal-ecu/ecu.sock \
  http://localhost/v1/health
podman exec "$EDGE" curl -fsS --unix-socket /run/continuumx-virtual-tire-ecu/ecu.sock \
  http://localhost/v1/health
```

## 3. A cloud patch downloads again

This forces a new catalog GET. Delete only the tire `sim-1.0.0` cache file, then ask CloudCore for that version. The edge cannot satisfy the request from a file it no longer has.

```bash
podman exec "$EDGE" rm -f \
  /opt/continuumx/firmware-candidates/virtual-tire-pressure-ecu-sim-1.0.0
BEFORE=$(podman exec "$EDGE" wc -l < /var/log/continuumx-catalog-fetch.log)

DEV=automotive-tire-pressure-ecu-fw-001
IDX=$(podman exec "$CLOUD" kubectl get device "$DEV" -n default -o json | jq -r \
  '.spec.properties | to_entries[] | select(.value.name=="firmwareVersion") | .key')
podman exec "$CLOUD" kubectl patch device "$DEV" -n default --type=json \
  -p="[{\"op\":\"test\",\"path\":\"/spec/properties/$IDX/name\",\"value\":\"firmwareVersion\"},{\"op\":\"replace\",\"path\":\"/spec/properties/$IDX/desired/value\",\"value\":\"sim-1.0.0\"}]"
```

Wait until the reported twin and the ECU health both show `sim-1.0.0` (usually under 20 seconds):

```bash
podman exec "$CLOUD" kubectl get devicestatus "$DEV" -n default -o json | jq -r \
  '.status.twins[] | select(.propertyName=="firmwareVersion") |
   "observedDesired=\(.observedDesired.value) reported=\(.reported.value)"'
podman exec "$EDGE" curl -fsS --unix-socket /run/continuumx-virtual-tire-ecu/ecu.sock \
  http://localhost/v1/health | jq -r .firmwareVersion
```

Then prove the new file was the catalog object:

```bash
podman exec "$EDGE" test -x \
  /opt/continuumx/firmware-candidates/virtual-tire-pressure-ecu-sim-1.0.0
AFTER=$(podman exec "$EDGE" wc -l < /var/log/continuumx-catalog-fetch.log)
test "$AFTER" -gt "$BEFORE"
podman exec "$EDGE" tail -n 1 /var/log/continuumx-catalog-fetch.log
EDGE_SHA=$(podman exec "$EDGE" sha256sum \
  /opt/continuumx/firmware-candidates/virtual-tire-pressure-ecu-sim-1.0.0 | awk '{print $1}')
CAT_SHA=$(curl -fsS http://127.0.0.1:3100/api/firmwares | jq -r \
  '.items[] | select(.name=="virtual-tire-pressure-ecu" and .version=="sim-1.0.0") | .sha256')
echo "edge=$EDGE_SHA"
echo "catalog=$CAT_SHA"
test "$EDGE_SHA" = "$CAT_SHA"
```

Pass when all of these are true:

- the candidate file exists again
- the fetch log grew by at least one line
- that line contains `fetched virtual-tire-pressure-ecu@sim-1.0.0 from http://firmware-catalog:3100/api/download?name=virtual-tire-pressure-ecu&version=sim-1.0.0`
- `edge` and `catalog` SHA-256 are identical
- tire health is `sim-1.0.0`

Thermal health must still be whatever it was before this patch. Only the tire service restarts.

## 4. Put the tire ECU back on sim-1.1.0

Repeat the patch with `"sim-1.1.0"`. Delete the cached `virtual-tire-pressure-ecu-sim-1.1.0` first if you want the same proof for the upgrade. The new log line must cite `version=sim-1.1.0`, and the staged SHA-256 must equal the catalog row for `virtual-tire-pressure-ecu@sim-1.1.0`.

The same two steps work for the thermal device `automotive-thermal-ecu-fw-001` and the name `virtual-thermal-ecu`. Its socket is `/run/continuumx-virtual-thermal-ecu/ecu.sock`.

## Other checks

Coolant, tire leak, NGINX, and ServiceBus are in [docker-playground-demo.md](docker-playground-demo.md). The script `docker/e2e-cold-test.sh` runs the full cold start, including these catalog downloads.
