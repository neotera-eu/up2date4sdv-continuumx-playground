# Multi-ECU device-twin and firmware-update troubleshooting

This guide accompanies the [ContinuumX Playground](../README.md) **VirtualBox/VM** exercises with one DMI mapper and two independently running simulated ECUs. The ECUs are local Linux executables, not physical controllers or production OTA targets. Run checks on the specified VM. **Never manually set a reported twin value** to conceal a failed operation.

## Runtime identities

| | Thermal ECU | Tire-pressure ECU |
|---|---|---|
| DeviceModel | `automotive-thermal-ecu-fw-demo` | `automotive-tire-pressure-ecu-fw-demo` |
| Device / DeviceStatus | `automotive-thermal-ecu-fw-001` | `automotive-tire-pressure-ecu-fw-001` |
| Service | `continuumx-virtual-thermal-ecu.service` | `continuumx-virtual-tire-ecu.service` |
| Local API socket | `/run/continuumx-virtual-thermal-ecu/ecu.sock` | `/run/continuumx-virtual-tire-ecu/ecu.sock` |
| Persistent state | `/var/lib/continuumx-virtual-thermal-ecu/state.json` | `/var/lib/continuumx-virtual-tire-ecu/state.json` |
| Activation helper | `/usr/local/libexec/continuumx/activate-virtual-thermal-ecu` | `/usr/local/libexec/continuumx/activate-virtual-tire-ecu` |

The shared mapper is `continuumx-virtual-ethernet-mapper.service` with DMI socket `/etc/kubeedge/virtual-ethernet-mapper.sock`. EdgeCore listens on `/etc/kubeedge/dmi.sock`. The mapper talks to each ECU over HTTP/JSON through that ECU's distinct socket.

## 1. Confirm the two Devices are registered (cloud VM)

On **`u2deb-cloud`**:

```bash
kubectl get nodes -o wide
kubectl get devicemodel automotive-thermal-ecu-fw-demo \
  automotive-tire-pressure-ecu-fw-demo -n default
kubectl get device automotive-thermal-ecu-fw-001 \
  automotive-tire-pressure-ecu-fw-001 -n default
```

Inspect each Device's routing attributes (including the socket and logical type):

```bash
for device in automotive-thermal-ecu-fw-001 automotive-tire-pressure-ecu-fw-001; do
  echo "=== $device ==="
  kubectl get device "$device" -n default -o json | jq '{
    name: .metadata.name,
    nodeName: .spec.nodeName,
    protocol: .spec.protocol.protocolName,
    deviceType: .spec.protocol.configData.deviceType,
    socketPath: .spec.protocol.configData.socketPath,
    model: .spec.deviceModelRef.name
  }'
done
```

Both Devices must use protocol `virtual-ethernet`, target the edge node `u2deb-edge` and select distinct ECU types (`thermal` and `tire-pressure`). A stale `deviceType` or socket path can prevent acquisition or route a command to the wrong client.

## 2. Verify services and local ECU health (edge VM)

On **`u2deb-edge`**:

```bash
systemctl is-active edgecore.service \
  continuumx-virtual-ethernet-mapper.service \
  continuumx-virtual-thermal-ecu.service \
  continuumx-virtual-tire-ecu.service
sudo curl -fsS --unix-socket /run/continuumx-virtual-thermal-ecu/ecu.sock \
  http://localhost/v1/health | jq .
sudo curl -fsS --unix-socket /run/continuumx-virtual-tire-ecu/ecu.sock \
  http://localhost/v1/health | jq .
```

If an ECU is unhealthy, inspect **its own service** before modifying DeviceModels or restarting EdgeCore:

```bash
sudo journalctl -u continuumx-virtual-thermal-ecu.service -n 60 --no-pager
sudo journalctl -u continuumx-virtual-tire-ecu.service -n 60 --no-pager
```

## 3. Mapper registers but DeviceStatus does not advance

The mapper can log `Mapper register finished` and `devInit finished` even if no matching Devices were available at initialization. A successful registration is not sufficient evidence of active per-device reporting loops.

On **`u2deb-edge`**:

```bash
sudo systemctl cat continuumx-virtual-ethernet-mapper.service
sudo journalctl -u continuumx-virtual-ethernet-mapper.service \
  -b -n 160 --no-pager -l
sudo ss -xlpn | grep -E 'dmi.sock|virtual-ethernet-mapper.sock'
```

The supplied mapper unit uses `--v=2`; `BATCH reported` messages are verbosity-2 logs. If the two Device resources were created **after** mapper registration and do not initialize, verify both models, Devices and ECU endpoints first, then restart **only the mapper**:

```bash
sudo systemctl restart continuumx-virtual-ethernet-mapper.service
sudo journalctl -u continuumx-virtual-ethernet-mapper.service \
  --since '2 minutes ago' --no-pager -l | \
  grep -E 'Registration returned|Starting batched|BATCH reported|[Ee]rror'
```

Expect startup and report entries for **both** `automotive-thermal-ecu-fw-001` and `automotive-tire-pressure-ecu-fw-001`. Do not restart EdgeCore or recreate Devices without diagnosing missing Kubernetes resources or DMI connectivity.

On **`u2deb-cloud`**, check actual cloud-side progress independently of log filtering:

```bash
for device in automotive-thermal-ecu-fw-001 automotive-tire-pressure-ecu-fw-001; do
  echo "=== $device ==="
  kubectl get devicestatus "$device" -n default -o json | jq -r '
    "resourceVersion=\(.metadata.resourceVersion)",
    (.status.twins[]? | select(.propertyName == "firmwareVersion") |
      "firmwareVersion=\(.reported.value // "-") timestamp=\(.reported.metadata.timestamp // "-")")'
done
```

Repeat after at least one collection interval. `DeviceStatus` is the **last synchronized snapshot** and `kubectl get` does not trigger a live ECU read.

## 4. Firmware-update failures and isolation

On **`u2deb-cloud`**, query the selected Device's desired and reported firmware versions:

```bash
DEVICE=automotive-thermal-ecu-fw-001  # or automotive-tire-pressure-ecu-fw-001
kubectl get device "$DEVICE" -n default -o json | jq -r '
  .spec.properties[] | select(.name == "firmwareVersion") |
  "desired=\(.desired.value)"'
kubectl get devicestatus "$DEVICE" -n default -o json | jq -r '
  .status.twins[]? | select(.propertyName == "firmwareVersion") |
  "observedDesired=\(.observedDesired.value) reported=\(.reported.value)"'
```

| Observation | Interpretation / next check |
|---|---|
| `desired` updated, `observedDesired` old | Desired state may not have reached the edge mapper; inspect device routing and cloud–edge synchronization |
| `observedDesired` updated, `reported` old | The request was observed but actual firmware activation is not proven; inspect updater and selected ECU logs |
| `/v1/health` new, cloud `reported` old | Verify mapper reporting timestamps and DeviceStatus synchronization |
| Both ECUs restart after updating one | Unexpected: check which service the updater invoked and whether systemd units were modified |
| Mapper restarts after updating an ECU | Unexpected: inspect mapper exit and service configuration; only the selected ECU should restart |

On **`u2deb-edge`**, inspect the updater and both services:

```bash
sudo journalctl -u continuumx-virtual-ethernet-mapper.service \
  --since '15 minutes ago' --no-pager | grep -Ei 'firmware|FW-UPDATE|error|activation'
sudo systemctl cat continuumx-virtual-thermal-ecu.service
sudo systemctl cat continuumx-virtual-tire-ecu.service
sudo ls -l /opt/continuumx/firmware-candidates/
sudo ls -l /usr/local/libexec/continuumx/activate-virtual-thermal-ecu \
  /usr/local/libexec/continuumx/activate-virtual-tire-ecu
```

Use `systemctl show -p MainPID --value SERVICE` before and after each update to prove that the **selected ECU PID changes and the other two processes remain stable**. The helper selects only locally staged versions `sim-1.0.0` or `sim-1.1.0` and attempts rollback on failure; this is **not a signed or safety-certified firmware-update procedure**.

## 5. First firmware update succeeds, but later update requests stop working

**Observed intermittent behavior (VM Playground):** A tire-pressure firmware update succeeded, but subsequent tire-pressure downgrades and thermal firmware upgrades did not take effect. Restarting **only the shared mapper** restored updates for both ECUs, and repeated upgrades/downgrades then worked. This may indicate a mapper device-twin reconciliation or device-worker lifecycle defect. **The root cause has not been established, and a restart is a recovery workaround, not a fix.** It is different from the initial-registration issue in Section 3, although both may recover after the same service restart.

Before restarting anything, ensure that no ECU activation is still running and collect diagnostics **while the failure is present**:

On **`u2deb-edge`**:

```bash
systemctl is-active continuumx-virtual-ethernet-mapper.service \
  continuumx-virtual-thermal-ecu.service continuumx-virtual-tire-ecu.service
sudo journalctl -u continuumx-virtual-ethernet-mapper.service \
  --since '20 minutes ago' --no-pager -l | \
  grep -Ei 'DMI twin|FW-UPDATE|applying desired|activation|Starting batched|BATCH reported|error|stopped' || true
sudo journalctl -u continuumx-virtual-thermal-ecu.service \
  -u continuumx-virtual-tire-ecu.service --since '20 minutes ago' --no-pager -l
pgrep -af 'activate-virtual-(thermal|tire)-ecu' || true
```

On **`u2deb-cloud`**, compare the requested and actual firmware for **both** Devices:

```bash
for dev in automotive-thermal-ecu-fw-001 automotive-tire-pressure-ecu-fw-001; do
  echo "=== $dev ==="
  kubectl get device "$dev" -n default -o json | jq -r '
    .spec.properties[] | select(.name == "firmwareVersion") |
    "desired=\(.desired.value)"'
  kubectl get devicestatus "$dev" -n default -o json | jq -r '
    .status.twins[]? | select(.propertyName == "firmwareVersion") |
    "observedDesired=\(.observedDesired.value // "-") reported=\(.reported.value // "-")"'
done
```

If both ECU health endpoints respond, no activation is still executing, but newly requested versions are not being processed, **restart the mapper alone** on `u2deb-edge`:

```bash
sudo systemctl restart continuumx-virtual-ethernet-mapper.service
sudo journalctl -u continuumx-virtual-ethernet-mapper.service \
  --since '2 minutes ago' --no-pager -l | \
  grep -E 'Registration returned|Starting batched|BATCH reported|FW-UPDATE|[Ee]rror' || true
```

Do **not** restart EdgeCore, either ECU service, or manually invoke an activation helper as the first response. Verify that **both** DeviceStatus resources resume reporting, then compare `/v1/health` and `reported` firmware with the requested values. A matching `observedDesired` value alone is insufficient. If the request remains unapplied, investigate the DMI event path; a mapper restart does not guarantee that the same desired-value event will be replayed. Re-establish a **new mapper PID baseline** before any further firmware process-isolation test.

Record the failed desired value, timestamps, relevant mapper/EdgeCore logs, and whether either ECU continued reporting. Reproducibility should be investigated and fixed in the private mapper development project; this Playground only documents the observed behavior and operational recovery.

## 6. Legacy installations

If present, retire `continuumx-virtual-ecu.service` and `continuumx-virtual-ethernet.service` before bringing up the new services. Back up existing settings and leave legacy state untouched unless migrating it deliberately. Do not run two mappers registering the same `virtual-ethernet` protocol or two reference Devices driving the same simulated ECU.

The Podman/Compose lab is separately maintained and outside the scope of these VM diagnostics.
