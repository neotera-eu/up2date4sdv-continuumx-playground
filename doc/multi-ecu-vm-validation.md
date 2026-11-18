# VirtualBox Multi-ECU deployment and end-to-end validation

**Scope:** Validate the public ContinuumX Playground VM distribution imported in Steps 1–3. This is an end-user/maintainer validation checklist, not a build or source-code guide. No access to the private mapper source repository is required. Do not change the separately maintained `docker/` directory or `doc/docker-playground-howto.md`.

**Reference environment:** Fedora host; `u2deb-cloud` (`192.168.56.10`, Kubernetes API/CloudCore); `u2deb-edge` (`192.168.56.11`, EdgeCore). Run commands in the stated environment. All Kubernetes sample resources use namespace `default` and target edge node `u2deb-edge`.

| Component | Identity | Runtime |
|---|---|---|
| Shared DMI mapper | `continuumx-virtual-ethernet-mapper.service` | `/etc/kubeedge/virtual-ethernet-mapper.sock` |
| Thermal ECU | `continuumx-virtual-thermal-ecu.service` | `/run/continuumx-virtual-thermal-ecu/ecu.sock` |
| Tire-pressure ECU | `continuumx-virtual-tire-ecu.service` | `/run/continuumx-virtual-tire-ecu/ecu.sock` |
| Thermal Device | `automotive-thermal-ecu-fw-001` | DeviceModel `automotive-thermal-ecu-fw-demo` |
| Tire-pressure Device | `automotive-tire-pressure-ecu-fw-001` | DeviceModel `automotive-tire-pressure-ecu-fw-demo` |

**Safety/preservation:** The exercises change live Kubernetes desired values and simulated ECU state. Back up or note existing desired values before editing. Do not reapply a sample Device manifest over a previously configured Device. Do not overwrite an active ECU binary or restart EdgeCore as part of these tests. A leak reduces *persisted* simulated pressure; turning the leak off does not restore the lost pressure. The firmware exercise uses local demo executables and is **not** a secure automotive OTA procedure.

## A. Release and installation readiness

**A1. Linux (teste on Fedora) host, from the public Playground checkout**

```bash
cd /path/to/continuumx-playground
./scripts/prepare-playground-release.sh --verify
git status --short
```

**Pass:** the read-only verifier accepts the imported release, including all five Linux/AMD64 executables, four firmware identities, 16 artifact checksums, and metadata. If it fails, restore the corresponding artifact from the approved distribution; do not regenerate `SHA256SUMS` to hide an unexpected change.

**A2. VMs:** On `u2deb-cloud`, run:

```bash
kubectl get nodes -o wide
```

**Pass:** both `u2deb-cloud` and `u2deb-edge` show `Ready`.

**A3. Install if this is a fresh VM:** Follow the existing [Deploy both automotive ECUs](../README.md#deploy-both-automotive-ecus) section **in order**. It gives public-repository-only commands to transfer `bin/`, `config/`, and `deploy/`, install the separate ECU services and the shared mapper, copy the four Device manifests, and apply models before Devices. If a Device or service already exists, back it up and inspect it rather than reapplying the default desired values. Retire any *old* mapper service before starting the shared mapper; never run two mappers registering `virtual-ethernet` simultaneously.

**A4. Edge VM:**

```bash
systemctl is-active \
  edgecore.service \
  continuumx-virtual-ethernet-mapper.service \
  continuumx-virtual-thermal-ecu.service \
  continuumx-virtual-tire-ecu.service

test -S /etc/kubeedge/dmi.sock
test -S /etc/kubeedge/virtual-ethernet-mapper.sock

sudo curl -fsS --unix-socket /run/continuumx-virtual-thermal-ecu/ecu.sock \
  http://localhost/v1/health | jq .
sudo curl -fsS --unix-socket /run/continuumx-virtual-tire-ecu/ecu.sock \
  http://localhost/v1/health | jq .
```

**Pass:** four active services, both local DMI sockets present, and both HTTP/JSON ECU health endpoints respond with `status: ok` and the expected identities. On a fresh installation, both ECUs begin with `firmwareVersion: sim-1.0.0`; on an existing installation, inspect the actual value rather than assuming it was reset.

## B. Device registration and concurrent DMI reporting

**B1. Cloud VM:**

```bash
kubectl get devicemodel,device,devicestatus -n default

for dev in automotive-thermal-ecu-fw-001 automotive-tire-pressure-ecu-fw-001; do
  echo "=== $dev ==="
  kubectl get device "$dev" -n default -o json | jq '{
    node: .spec.nodeName,
    model: .spec.deviceModelRef.name,
    protocol: .spec.protocol.protocolName,
    deviceType: .spec.protocol.configData.deviceType,
    socket: .spec.protocol.configData.socketPath,
    updater: .spec.protocol.configData.firmwareUpdaterPath
  }'
done
```

**Pass:** the two DeviceModels and Devices exist; both Devices point to `u2deb-edge`, use protocol `virtual-ethernet`, and have different `deviceType`, socket, and activation helper values. Both models declare `firmwareVersion` as `ReadWrite`.

**B2. DMI startup-order checkpoint:** If the mapper was started **before** both Devices were registered and no reporting loops exist, restart **only the mapper** on `u2deb-edge`:

```bash
sudo systemctl restart continuumx-virtual-ethernet-mapper.service
sudo journalctl -u continuumx-virtual-ethernet-mapper.service \
  --since '3 minutes ago' --no-pager -l | \
  grep -E 'Registration returned|Starting batched|BATCH reported|[Ee]rror' || true
```

Do this once **before** capturing the mapper PID baseline below, never during either firmware isolation test. A healthy startup shows reporters and recurring successful batches for **both** Device names. `Mapper register finished` alone is not sufficient evidence that either device was initialized.

**B3. Cloud VM, sample twice:**

```bash
for dev in automotive-thermal-ecu-fw-001 automotive-tire-pressure-ecu-fw-001; do
  echo "=== $dev ==="
  kubectl get devicestatus "$dev" -n default -o json | jq -r '
    "resourceVersion=\(.metadata.resourceVersion)",
    (.status.twins[]? |
      select(.propertyName == "firmwareVersion" or
             .propertyName == "coolantTemperature" or
             .propertyName == "frontLeftPressure") |
      "\(.propertyName)=\(.reported.value // "-") timestamp=\(.reported.metadata.timestamp // "-")")'
done
```

Repeat after **30 seconds**. **Pass:** both DeviceStatus resources exist, each contains its own firmware identity and live measurement, and reporting timestamps/resource versions advance as the reporter runs. A `kubectl get` query reads the latest stored snapshot; it does not request a fresh sample. If data appear static, compare the batch logs and the configured `collectCycle` before concluding that reporting has stopped.

## C. Control isolation

**C1. Thermal setpoint (cloud VM):** Record the present desired value before the change. Use a test value different from the current value (the example uses `63.0`).

```bash
DEV=automotive-thermal-ecu-fw-001
kubectl get device "$DEV" -n default -o json | jq -r \
  '.spec.properties[] | select(.name == "targetCoolantTemperature") | .desired.value'

IDX=$(kubectl get device "$DEV" -n default -o json | jq -r \
  '.spec.properties | to_entries[] | select(.value.name == "targetCoolantTemperature") | .key')
test -n "$IDX"

kubectl patch device "$DEV" -n default --type=json \
  -p="[{\"op\":\"test\",\"path\":\"/spec/properties/$IDX/name\",\"value\":\"targetCoolantTemperature\"},{\"op\":\"replace\",\"path\":\"/spec/properties/$IDX/desired/value\",\"value\":\"63.0\"}]"

kubectl get devicestatus "$DEV" -n default -o json | jq -r \
  '.status.twins[]? | select(.propertyName == "targetCoolantTemperature" or .propertyName == "coolantTemperature") | "\(.propertyName): reported=\(.reported.value // "-")"'
```

**Pass:** the thermal desired setpoint reaches its reported target after reconciliation and the measured coolant temperature evolves gradually. The tire-pressure Device continues reporting independently. Restore the previous setpoint afterward if this is not a disposable test VM.

**C2. Tire leak (cloud VM):** This is most deterministic on a freshly initialized tire ECU (front-left pressure begins around 235 kPa). The simulator persists tire-pressure state, so check its *current* pressure first. Do not assume the example threshold will cause a new transition if pressure is already below it.

Use the helper and leak exercise already provided in [Tire-pressure controls](../README.md#tire-pressure-controls-simulate-a-low-pressure-warning): set `leakWheel=FL`, `leakRate=10`, a valid `pressureThreshold` just below the observed front-left pressure (the fresh-state example uses `234` kPa), then `leakEnabled=true` last. Verify falling `frontLeftPressure` and, once threshold is crossed, `lowPressureWarning=true` and `FL` in `lowPressureWheels`. Simultaneously verify thermal reporting continues.

**Immediately after observing the warning**, set `leakEnabled=false` and restore the prior threshold. **Pass:** only the tire-pressure ECU's measurements and alarms respond to the leak; the thermal ECU remains available.

## D. Independent firmware updates and process isolation

**D1. Edge VM, capture a clean PID baseline after any one-time mapper restart:**

```bash
snapshot_ecu_pids() {
  for unit in \
    continuumx-virtual-ethernet-mapper \
    continuumx-virtual-thermal-ecu \
    continuumx-virtual-tire-ecu; do
    printf '%s=%s\n' "$unit" \
      "$(systemctl show -p MainPID --value "$unit.service")"
  done
}
snapshot_ecu_pids | tee /tmp/cx-pids-before.txt
```

Keep this shell open on `u2deb-edge` so the function remains available. Confirm the two actual versions before patching:

```bash
sudo curl -fsS --unix-socket /run/continuumx-virtual-thermal-ecu/ecu.sock \
  http://localhost/v1/health | jq -r '.firmwareVersion'
sudo curl -fsS --unix-socket /run/continuumx-virtual-tire-ecu/ecu.sock \
  http://localhost/v1/health | jq -r '.firmwareVersion'
```

**D2. Cloud VM, test tire firmware first:** On a fresh installation request `sim-1.1.0`. If it is already running, request `sim-1.0.0` instead. Select the firmware property by *name*, not a hardcoded array offset:

```bash
DEV=automotive-tire-pressure-ecu-fw-001
IDX=$(kubectl get device "$DEV" -n default -o json | jq -r \
  '.spec.properties | to_entries[] | select(.value.name == "firmwareVersion") | .key')
test -n "$IDX"
kubectl patch device "$DEV" -n default --type=json \
  -p="[{\"op\":\"test\",\"path\":\"/spec/properties/$IDX/name\",\"value\":\"firmwareVersion\"},{\"op\":\"replace\",\"path\":\"/spec/properties/$IDX/desired/value\",\"value\":\"sim-1.1.0\"}]"

kubectl get devicestatus "$DEV" -n default -o json | jq -r \
  '.status.twins[]? | select(.propertyName == "firmwareVersion") | "observedDesired=\(.observedDesired.value // "-") reported=\(.reported.value // "-")"'
```

The command above uses `sim-1.1.0`. Substitute `sim-1.0.0` if it is the version **not currently running**. Allow time for reconciliation; `observedDesired` alone does not prove success.

**D3. Edge VM, verify tire activation and unchanged other PIDs:**

```bash
sudo curl -fsS --unix-socket /run/continuumx-virtual-tire-ecu/ecu.sock \
  http://localhost/v1/health | jq .
snapshot_ecu_pids | tee /tmp/cx-pids-after-tire.txt
diff -u /tmp/cx-pids-before.txt /tmp/cx-pids-after-tire.txt || true
```

**Pass:** the tire ECU PID is different; thermal ECU and shared mapper PIDs are the same as before. The tire ECU's health endpoint and the tire DeviceStatus **reported** firmware match the requested version. Thermal DeviceStatus still advances. The `diff` should show a change only for `continuumx-virtual-tire-ecu`.

**D4. Cloud VM, independently update thermal firmware:** As above, choose the firmware version that is *not currently running*:

```bash
DEV=automotive-thermal-ecu-fw-001
IDX=$(kubectl get device "$DEV" -n default -o json | jq -r \
  '.spec.properties | to_entries[] | select(.value.name == "firmwareVersion") | .key')
test -n "$IDX"
kubectl patch device "$DEV" -n default --type=json \
  -p="[{\"op\":\"test\",\"path\":\"/spec/properties/$IDX/name\",\"value\":\"firmwareVersion\"},{\"op\":\"replace\",\"path\":\"/spec/properties/$IDX/desired/value\",\"value\":\"sim-1.1.0\"}]"
```

**D5. Edge VM, check thermal activation and isolation:**

```bash
sudo curl -fsS --unix-socket /run/continuumx-virtual-thermal-ecu/ecu.sock \
  http://localhost/v1/health | jq .
snapshot_ecu_pids | tee /tmp/cx-pids-after-thermal.txt
diff -u /tmp/cx-pids-after-tire.txt /tmp/cx-pids-after-thermal.txt || true
```

**Pass:** the thermal ECU PID changes and its running version / thermal DeviceStatus `reported` match the requested version; the mapper and tire ECU PIDs remain unchanged, and tire DeviceStatus continues reporting. If the thermal firmware was already `sim-1.1.0`, change only the command's requested value to `sim-1.0.0`.

**D6. If the firmware upgrade/downgrade stalls:** This intermittent behavior has been observed. Do not mark the stalled operation successful even if the `observedDesired` advanced. Capture mapper/ECU logs and both Devices' desired, observed-desired, and reported firmware **before** recovery. When no activation helper is running and both ECU health endpoints are available, restart **only** `continuumx-virtual-ethernet-mapper.service` and recheck both DeviceStatus resources. The exact diagnostic and restart commands are in [Firmware-update troubleshooting](virtual-ecu-firmware-update-troubleshooting.md#5-first-firmware-update-succeeds-but-later-update-requests-stop-working). A restart is a documented workaround, **not** evidence that uninterrupted consecutive updates work; flag the limitation in the test report and reset the mapper PID baseline for subsequent isolation checks.

## E. Optional failure isolation (edge VM)

Only run this test on an isolated Playground VM after the other tests pass. Record the current PIDs and DeviceStatus first. Temporarily stop the tire ECU:

```bash
sudo systemctl stop continuumx-virtual-tire-ecu.service
systemctl is-active continuumx-virtual-ethernet-mapper.service \
  continuumx-virtual-thermal-ecu.service
```

**Pass:** the mapper and thermal ECU remain active; thermal reporting still advances while tire reads may produce errors. Recover the tire ECU:

```bash
sudo systemctl start continuumx-virtual-tire-ecu.service
sudo curl -fsS --unix-socket /run/continuumx-virtual-tire-ecu/ecu.sock \
  http://localhost/v1/health | jq .
```

Verify tire DeviceStatus resumes updating **without restarting the mapper**. A stopped ECU should never prevent the other ECU from continuing to report. Stop/start can also change the tire PID and must not be confused with the earlier firmware-isolation comparison.

## F. Acceptance and Git checkpoint

Record the following evidence for this release version:

| Check | Required observation | Result |
|---|---|---|
| A - Integrity | Public release verifier passes; no artifacts changed | ☐ |
| B - Services | EdgeCore, mapper, thermal ECU, tire ECU active; both ECU health APIs work | ☐ |
| C - DMI | Both Devices initialized and generate independent successful batches | ☐ |
| D - Twins | Both cloud DeviceStatus snapshots contain the expected repo-ted firmware/telemetry and advance | ☐ |
| E - Controls | Thermal setpoint works; tire leak/warning works independently | ☐ |
| F - Tire update | Tire firmware changes; only tire service PID changes | ☐ |
| G - Thermal update | Thermal firmware changes; only thermal service PID changes | ☐ |
| H - Optional failure isolation | Stopping tire ECU leaves thermal reporter operational; restarting tire recovers | ☐ optional |
| I - Repeated updates | Consecutive updates/downgrades work without mapper restart, or a workaround is explicitly documented | ☐ |

Useful evidence commands (do not publish credentials or confidential logs):

```bash
# Edge VM
sudo journalctl -u continuumx-virtual-ethernet-mapper.service \
  --since '10 minutes ago' --no-pager -l

# Cloud VM
kubectl get devicestatus automotive-thermal-ecu-fw-001 -n default -o yaml
kubectl get devicestatus automotive-tire-pressure-ecu-fw-001 -n default -o yaml
```

**Keep `docker/` and `doc/docker-playground-howto.md` untouched.** This step does not edit any of the 16 checksummed runtime artifacts, binaries, services, helpers, or manifests. After the live VM tests pass, the validation document itself can be committed:

```bash
git add doc/multi-ecu-vm-validation.md
git diff --cached --check
git commit -m "docs(playground): add validated multi-ECU VM acceptance procedure"
```

**Separate known issue:** The original `manifests/templates/nginx-edge.yaml` in the last supplied Playground snapshot contains unresolved Git conflict markers. This is outside the Multi-ECU acceptance test above. Do not claim the full Playground NGINX example is validated until that file has been reviewed, fixed in its own change, and applied successfully. Do not alter it incidentally during this step.
