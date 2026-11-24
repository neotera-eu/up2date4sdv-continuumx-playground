# ContinuumX Docker / Podman Playground — How To

Run the ContinuumX cloud–edge playground as containers on a Linux host (Podman Compose or Docker Compose). No VirtualBox VMs required.

For the VirtualBox appliance path, see the main [README](../README.md).

---

## What it does

The stack starts four services:

| Service | Role |
|---|---|
| **mqtt-broker** | External MQTT broker for EdgeCore EventBus (`mqttMode: 2`) |
| **cloud** | Kubernetes control plane + ContinuumX CloudCore + Router |
| **edge** | EdgeCore, one mapper, thermal ECU, tire-pressure ECU, NGINX |
| **servicebus-demo** | Next.js demo app on the edge (HTTP via ServiceBus) |
| **firmware-catalog** | Sole firmware source. Seeds both ECU binaries from `bin/ecu` |

On first boot the containers bootstrap themselves:

1. Cloud initializes kubeadm, installs CloudCore, enables the Router (`:9443`), publishes the edge join token.
2. Edge joins CloudCore, downloads both ECU baselines from the catalog, then starts the mapper.
3. Cloud applies the thermal and tire-pressure DeviceModels and Devices, plus NGINX on the edge.
4. Hands-on checks for each function are in [docker-playground-demo.md](docker-playground-demo.md).

Cold start is usually about **1–2 minutes** after images are built.

---

## Prerequisites

- Linux host (Fedora, Debian, Ubuntu, …)
- **Podman** + `podman compose` (or Docker Compose)
- `make`
- Ability to elevate once with **sudo** or **run0** (host prep only)

Do **not** run the whole stack as `sudo make run`. Use your normal user (rootless Podman). Host prep may ask for a password once.

---

## Quick start

```bash
cd docker
make build
make run
```

`make run` will:

1. Run `host-prep.sh` (kernel modules + sysctls; may check `/etc/hosts`)
2. Start the compose stack
3. Print connection info (`make info`)

Wait until status shows cloud / edge / mapper ready, then try the examples below.

---

## Make targets

| Target | Meaning |
|---|---|
| `make build` | Build all images |
| `make build cloud` | Build one service (`mqtt-broker`, `cloud`, `edge`, `servicebus-demo`) |
| `make run` | Host prep + start all + print info |
| `make down` | Stop containers |
| `make delete` | Remove containers (keep volumes and images) |
| `make prune` | Remove containers, **volumes**, and project images (full reset) |
| `make info` | Print SSH / URLs / MQTT / twin helpers again |
| `make revert` | Restore `/etc/hosts` from `/etc/hosts.backup` |

Volumes keep cluster and edge state across `down` / `delete`. Use `make prune` only when you want a clean cold start.

---

## Host prep (why sudo is asked)

Containers share the **host kernel**. Under rootless Podman they cannot `modprobe`, so `make run` loads on the host:

- `overlay`
- `br_netfilter`

and sets inotify / bridge / `ip_forward` sysctls.

If `/etc/hosts` has stale names that conflict with this stack (`cloud`, `mqtt-broker`, `u2deb-cloud`, `u2deb-edge`, …), host prep warns you and can backup the file to `/etc/hosts.backup` and write a clean one. Undo with:

```bash
make revert
```

---

## Access

Default host is `127.0.0.1`. Password for SSH user `user` is `user123`.

| What | How |
|---|---|
| Cloud SSH | `ssh -p 2222 user@127.0.0.1` |
| Edge SSH | `ssh -p 2223 user@127.0.0.1` |
| kubectl | On cloud: `sudo -i` then `kubectl get nodes` |
| ServiceBus UI | http://127.0.0.1:3000 |
| Firmware catalog (OTA) | http://127.0.0.1:3100 |
| CloudCore Router | http://127.0.0.1:9443 |
| MQTT | port `1883` (clients via `podman exec` into the broker) |
| Kubernetes API | https://127.0.0.1:6443 |

Re-print everything with:

```bash
make info
```

---

## Demonstrate each function

Step-by-step checks (catalog, both ECU health endpoints, coolant setpoint, tire leak, independent firmware updates, NGINX, ServiceBus) are in [docker-playground-demo.md](docker-playground-demo.md).

To prove each ECU binary was downloaded from the firmware catalog, including a SHA-256 match, follow [docker-firmware-catalog-test.md](docker-firmware-catalog-test.md).

---

## Try ServiceBus

```bash
curl -sS -X POST http://127.0.0.1:3000/api/trigger \
  -H 'content-type: application/json' \
  -d '{"msg":"hello via ServiceBus"}'
```

Expect `"ok":true`. Path: host → CloudCore Router → edge ServiceBus → demo app on `:3000`.

---

## MQTT (optional)

Use the broker container (no need to install `mosquitto_sub` / `mosquitto_pub` on the host):

```bash
podman exec -it continuumx-playground_mqtt-broker_1 \
  mosquitto_sub -h 127.0.0.1 -p 1883 -t '#' -v

podman exec continuumx-playground_mqtt-broker_1 \
  mosquitto_pub -h 127.0.0.1 -p 1883 -t 'demo/hello' -m 'hi'
```

---

## End-to-end smoke test

From `docker/`:

```bash
./e2e-cold-test.sh
```

Builds images, does a cold start (`down -v` + `up`), and checks nodes, ServiceBus, mapper, and a twin patch.

---

## Troubleshooting

### `br_netfilter: Operation not permitted` / `systemd-modules-load` failed

Expected inside the containers under rootless Podman. Modules must be loaded on the **host** by `make run` / `host-prep.sh`.

```bash
cd docker
bash ./host-prep.sh
ls /sys/module/overlay /sys/module/br_netfilter
```

### Cloud / edge never become ready

```bash
podman ps -a
podman exec continuumx-playground_cloud_1 journalctl -u cx-bootstrap -n 80 --no-pager
podman exec continuumx-playground_edge_1 journalctl -u cx-bootstrap -n 80 --no-pager
make info
```

First boot needs CloudCore Router on `:9443` and the join token volume. Wait 1–2 minutes before assuming failure.

### Mapper inactive / no DeviceStatus

```bash
podman exec continuumx-playground_edge_1 systemctl status continuumx-virtual-ethernet --no-pager
podman exec continuumx-playground_edge_1 ls -l /etc/kubeedge/dmi.sock /etc/kubeedge/virtual-ethernet.sock
podman exec continuumx-playground_cloud_1 kubectl get nodes
podman exec continuumx-playground_cloud_1 kubectl get device,devicestatus -n default
```

The mapper starts only after EdgeCore creates `dmi.sock`. Device manifests are applied after `u2deb-edge` is Ready.

### Conflicting `/etc/hosts` names

Stale VirtualBox entries (`192.168.56.x u2deb-cloud`, a bare `cloud` hostname, …) can break resolution. Prefer the prompt from `make run`, or clean manually, then:

```bash
make revert   # only if host-prep created /etc/hosts.backup
```

### Ran everything with `sudo`

Rootful and rootless Podman use different storage. Prefer a normal user. If you mixed modes, remove the rootful containers/volumes and start again as your user with `make prune` / `make run`.

### Need a full reset

```bash
cd docker
make prune
make build
make run
```

### ServiceBus trigger returns not ok

Confirm the demo is up and the router is listening:

```bash
curl -sfS http://127.0.0.1:3000/api/health
podman exec continuumx-playground_cloud_1 ss -lnt | grep 9443
curl -sS -X POST http://127.0.0.1:3000/api/trigger \
  -H 'content-type: application/json' -d '{"msg":"retry"}'
```

---

## Layout (for orientation)

```
docker/
  compose.yaml          # stack definition
  Makefile              # build / run / info / revert
  host-prep.sh          # host modules + sysctls + hosts check
  host-revert.sh        # restore /etc/hosts.backup
  print-info.sh         # connection cheat sheet
  e2e-cold-test.sh      # automated smoke test
  cloud/                # cloud image + bootstrap steps
  edge/                 # edge image + mapper bootstrap
  mosquitto/            # broker config
  servicebus-demo/      # Next.js demo
```

Mapper binary and device manifests come from the repo root (`bin/mapper/…`, `manifests/samples/devices/`) and are baked into the images at build time.
