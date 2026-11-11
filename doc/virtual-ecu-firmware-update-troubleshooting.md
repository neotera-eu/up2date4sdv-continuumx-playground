# Virtual ECU firmware-update troubleshooting

This guide accompanies the [ContinuumX Playground](../README.md) firmware-update exercise and applies only to its local, simulated ECU executable replacement. Run checks on the host indicated below. **Do not manually set `reported` to the desired version** to conceal a failed update.

## Identify the failing stage

On **u2deb-cloud**:

```bash
kubectl get devicemodel automotive-thermal-ecu-fw-demo -n default -o json | \
  jq -r '.spec.properties[] | select(.name == "firmwareVersion") | "modelAccess=\(.accessMode)"'
kubectl get device automotive-thermal-ecu-fw-001 -n default -o json | \
  jq -r '.spec.properties[] | select(.name == "firmwareVersion") | "desired=\(.desired.value)"'
kubectl get devicestatus automotive-thermal-ecu-fw-001 -n default -o json | \
  jq -r '.status.twins[]? | select(.propertyName == "firmwareVersion") | "observedDesired=\(.observedDesired.value) reported=\(.reported.value)"'
```

On **u2deb-edge**:

```bash
systemctl is-active continuumx-virtual-ecu.service continuumx-virtual-ethernet-mapper.service
sudo curl -fsS --unix-socket /run/continuumx-virtual-ecu/ecu.sock \
  http://localhost/v1/health | jq .
sudo journalctl -u continuumx-virtual-ethernet-mapper.service \
  --since '15 minutes ago' --no-pager | grep -Ei 'FW-UPDATE|error|firmware|grpc'
sudo journalctl -u continuumx-virtual-ecu.service -n 35 --no-pager
```

## Interpretation

| Observation | Likely troubleshooting direction |
|---|---|
| `desired=sim-1.1.0`, `observedDesired=sim-1.0.0` | The desired-state update may not have reached or been acknowledged by the mapper yet. Inspect DMI and cloud–edge synchronization. |
| `observedDesired=sim-1.1.0`, `reported=sim-1.0.0` | The request was observed but the firmware is not yet active. Check mapper activation logs, model access permissions, and helper execution. |
| Model says `ReadWrite` in cloud but mapper receives `ReadOnly` | Stale model metadata. Confirm the *fresh* `automotive-thermal-ecu-fw-demo` model and `automotive-thermal-ecu-fw-001` Device are deployed together; avoid running the former experimental device against the same ECU. |
| ECU health returns `sim-1.1.0` but cloud status still says `sim-1.0.0` | Check the mapper's batched reporting cycle and status synchronization. Verify report timestamp; reading `DeviceStatus` does not initiate a live ECU read. |
| Both ECU and mapper processes restart on version request | The mapper should remain running; inspect its exit status, logs and systemd unit. The ECU restart alone is expected. |
| Version remains old and helper reports error | Check root ownership and permissions of `/opt/continuumx/firmware-candidates/`, the `/usr/local/libexec/continuumx/activate-virtual-ecu` helper, and ECU service logs. |

## Filesystem and service checks

On **u2deb-edge**:

```bash
sudo ls -l /opt/continuumx/firmware-candidates/
sudo ls -l /opt/continuumx/virtual-thermal-ecu/virtual-thermal-ecu
sudo ls -l /usr/local/libexec/continuumx/activate-virtual-ecu
sudo systemctl cat continuumx-virtual-ecu.service
sudo systemctl cat continuumx-virtual-ethernet-mapper.service
sudo test -S /etc/kubeedge/virtual-ethernet-mapper.sock && echo 'DMI mapper socket ready'
```

Only the allowlisted versions (`sim-1.0.0` and `sim-1.1.0`) are supported. Candidates must be trusted local executables owned by root and not writable by group/others. The helper tries to restore the previous executable after a failed activation, but this is **not** a safety-certified rollback guarantee.

## Avoid competing deployments

Only one mapper should register `virtual-ethernet` on this edge node. If migrating from the old name, disable `continuumx-virtual-ethernet.service` before enabling `continuumx-virtual-ethernet-mapper.service`. Never start both simultaneously. Similarly, only one reference Device should drive this single simulated ECU; preserve old Device YAML before retiring previous examples.

For a user exercising firmware updates, the sole command that requests a version change is a Kubernetes patch to `firmwareVersion.desired`. Do not invoke the privileged activation helper manually unless you are performing controlled maintainer-level diagnostics.
