# ContinuumX Playground

A hands-on testbed for [ContinuumX](https://github.com/neotera-eu/continuumx), the Neotera distribution of [KubeEdge](https://github.com/kubeedge/kubeedge).

This playground gets you to a running two-node cluster: a Kubernetes control plane running ContinuumX **CloudCore**, and an edge worker node running ContinuumX **EdgeCore**. Once it is up, you deploy a real workload (NGINX) to the edge node and verify end-to-end connectivity.

---

## What is ContinuumX?

**ContinuumX** extends Kubernetes with native edge computing capabilities, bringing containerised application orchestration and device management to edge nodes, based on the CNCF project KubeEdge. It consists of two main components:

- **CloudCore**, runs on the Kubernetes control plane. Manages edge nodes, synchronises metadata, and exposes the CloudHub WebSocket endpoint that edge nodes connect to.
- **EdgeCore**, runs as a `systemd` service on each edge node. Manages local containers, reports node status back to the cloud, and operates autonomously when the cloud connection is intermittent.

ContinuumX also supports **MQTT**, enabling edge devices to communicate through edge nodes via the EventBus component.

`cxadm` is the ContinuumX CLI, equivalent to upstream `keadm`, used to deploy CloudCore (via Helm) and to join edge nodes.

---

## Reference Topology

```
┌─────────────────────────────────────┐     Host-Only Network
│  VirtualBox Host                    │     192.168.56.0/24
│                                     │
│  ┌──────────────────────────────┐   │   ┌──────────────────────────────┐
│  │  u2deb-cloud  192.168.56.10  │◄──┼──►│  u2deb-edge  192.168.56.11   │
│  │  Debian 13 · K8s v1.32       │   │   │  Debian 13                   │
│  │  CloudCore v1.23             │   │   │  EdgeCore v1.23              │
│  │                              │   │   │                              │
│  │  NAT · Host-Only · Bridged   │   │   │  NAT · Host-Only             │
│  └──────────────────────────────┘   │   └──────────────────────────────┘
│                                     │
└─────────────────────────────────────┘
```

| VM | Hostname | Host-Only IP | Role |
|---|---|---|---|
| VM 0 | `u2deb-cloud` | `192.168.56.10` | K8s Control Plane + ContinuumX CloudCore |
| VM 1 | `u2deb-edge` | `192.168.56.11` | Edge Worker Node + ContinuumX EdgeCore |

---

## Getting Started

Choose the path that suits you:

- **[Option 1](#option-1-build-from-scratch)**, Follow the step-by-step guides to provision both VMs yourself. Recommended if you want to understand what every layer does.
- **[Option 2](#option-2-import-ready-made-vms)**, Download two pre-built VMs and import them into VirtualBox. Recommended if you want a working cluster in minutes.

Both options converge at [Verify the Testbed](#verify-the-testbed).

---

## Option 1, Build from Scratch

Three guides, to be followed in order.

### Step 1, Prepare the CloudCore VM

Follow **[`vm0-continuumx-cloudcore-v1_23.md`](./doc/vm0-continuumx-cloudcore-v1_23.md)** to provision a Debian 13 VM running Kubernetes v1.32 with containerd and Flannel CNI, configured and validated as a ready baseline for ContinuumX CloudCore.

At the end of this guide the VM (`u2deb-cloud`, `192.168.56.10`) will have:
- A fully operational single-node Kubernetes control plane
- All ContinuumX pre-conditions satisfied (taint removed, kube-proxy patched, CA files present, kubeconfig available to root)

### Step 2, Prepare the EdgeCore VM

Follow **[`vm1-continuumx-edgecore-v1_23.md`](./doc/vm1-continuumx-edgecore-v1_23.md)** to provision a second Debian 13 VM with containerd, configured as a minimal edge worker node baseline.

At the end of this guide the VM (`u2deb-edge`, `192.168.56.11`) will have:
- containerd installed and running with `SystemdCgroup = true`
- Static IP on the Host-Only interface, `/etc/hosts` entries for both nodes, swap disabled

### Step 3, Install CloudCore and EdgeCore

Follow **[`continuumx-v1_23-cloudcore-edgecore-install.md`](./doc/continuumx-v1_23-cloudcore-edgecore-install.md)** to deploy ContinuumX on both VMs using `cxadm`.

This guide covers:
- **Part I**, Install `cxadm` on the control plane, run `cxadm init` to deploy CloudCore as a Helm-managed pod in the `kubeedge` namespace, configure Cilium cloud-side, and retrieve the edge join token.
- **Part II**, Install `cxadm` on the edge node, run `cxadm join` to register `u2deb-edge` as a ContinuumX edge worker, and configure Cilium edge-side.

At the end of this guide you will have a live two-node cluster. Continue to [Verify the Testbed](#verify-the-testbed).

---

## Option 2, Import Ready-Made VMs

Download the two pre-built VirtualBox appliances and import them. The VMs ship with everything from Options 1 and 2 already applied, Kubernetes, CloudCore, EdgeCore, and all network configuration are pre-installed and ready to boot.

### 2.1 Download the Appliances

| Appliance | VM | Download |
|---|---|---|
| `u2deb-cloud.vdi` | CloudCore (control plane) | [u2deb-edge.vdi.tag.gz](https://drive.google.com/file/d/1RI-MqrhOZ4BdTkz_tthgPjHZImDyjZYr/view?usp=sharing) |
| `u2deb-edge.vdi` | EdgeCore (edge worker) | [u2deb-edge.vdi.tag.gz](https://drive.google.com/file/d/1RI-MqrhOZ4BdTkz_tthgPjHZImDyjZYr/view?usp=sharing) |

### 2.2 Create the Host-Only Network in VirtualBox

Both VMs communicate over a dedicated host-only network. This must be created before importing.

1. Open VirtualBox -> **File -> Tools -> Network Manager**
2. Click the **Host-only Networks** tab
3. Click **Create**, VirtualBox will add a new adapter (e.g. `vboxnet0`)
4. Set the adapter address:
   - **IPv4 Address:** `192.168.56.1`
   - **IPv4 Network Mask:** `255.255.255.0`
5. Switch to the **DHCP Server** tab and ensure DHCP is **disabled**
6. Click **Apply**

> If `vboxnet0` with `192.168.56.1/24` already exists from a previous setup, skip this step.

### 2.3 Import the CloudCore VM (`u2deb-cloud`)

1. In VirtualBox, go to **File -> Import Appliance**
2. Select `u2deb-cloud.vdi` and click **Next**
3. Review the settings and click **Finish**. Wait for the import to complete.
4. Once imported, open the VM **Settings -> Network** and verify the three adapters:

| Adapter | Attached to | Details |
|---|---|---|
| Adapter 1 | NAT | Internet / package access |
| Adapter 2 | Host-Only Adapter | Select `vboxnet0` |
| Adapter 3 | Bridged Adapter | Select your physical LAN interface |

> If Adapter 3 shows "not connected", select your active LAN interface (e.g. `eth0`, `en0`, or `Wi-Fi`) from the dropdown.

### 2.4 Import the EdgeCore VM (`u2deb-edge`)

1. In VirtualBox, go to **File -> Import Appliance**
2. Select `u2deb-edge.vdi` and click **Next**
3. Review the settings and click **Finish**. Wait for the import to complete.
4. Once imported, open the VM **Settings -> Network** and verify the two adapters:

| Adapter | Attached to | Details |
|---|---|---|
| Adapter 1 | NAT | Internet / package access |
| Adapter 2 | Host-Only Adapter | Select `vboxnet0` |

### 2.5 Start Both VMs

Start `u2deb-cloud` first and wait until it is fully booted (roughly 30–60 seconds), then start `u2deb-edge`.

The edge node's EdgeCore service will connect to CloudCore automatically on boot. No manual join is required, it was already registered in the pre-built image.

---

## Verify the Testbed

Once both VMs are running (regardless of which option you followed), perform the checks below from the **CloudCore VM** (`u2deb-cloud`).

### Check 1, Edge Node Has Joined and Is Ready

```bash
kubectl get nodes -o wide
```

Expected output:

```
NAME           STATUS   ROLES           AGE   VERSION    INTERNAL-IP     OS-IMAGE
u2deb-cloud    Ready    control-plane   ...   v1.32.x    192.168.56.10   Debian GNU/Linux 13
u2deb-edge     Ready    agent,edge      ...   v1.23.0    192.168.56.11   Debian GNU/Linux 13
```

Both nodes must show `Ready`. If `u2deb-edge` shows `NotReady`, wait 60 seconds and retry, EdgeCore may still be establishing its WebSocket connection to CloudCore.

If it remains `NotReady`, check EdgeCore logs on the edge VM:

```bash
# On u2deb-edge
journalctl -u edgecore -n 50 --no-pager
```

### Check 2, Deploy NGINX to the Edge Node

Deploy a demo NGINX pod targeted to the edge node, following the [KubeEdge upstream demo](https://kubeedge.io/docs/setup/install-with-binary#deploy-demo-on-edge-nodes).

**Apply deployment manifest:**

```bash
kubectl apply -f manifests/templates/nginx-edge.yaml
```

**Wait for the pod to reach Running state:**

```bash
kubectl wait --for=condition=Ready pod \
  -l app=nginx-edge \
  --timeout=120s
```

> The first run may take longer as `u2deb-edge` pulls the `nginx:alpine` image. Subsequent deploys are faster.

**Verify the pod is scheduled on the edge node:**

```bash
kubectl get pods -o wide
```

Expected output:

```
NAME                          READY   STATUS    NODE
nginx-edge-<hash>             1/1     Running   u2deb-edge
```


**Clean up:**

```bash
kubectl delete -f nginx-edge.yaml
```

---

## What's Next?

- Explore the [ContinuumX README](https://github.com/neotera-eu/continuumx) for the full feature set.
- Browse the [KubeEdge documentation](https://kubeedge.io/docs/) for device management, MQTT integration, and EdgeMesh.
- Try deploying your own workloads with `nodeName: u2deb-edge` or using node labels and `nodeSelector`.
- Review the troubleshooting appendices in the install guide for common edge-cloud connectivity issues.

## TODOS
- Verify pods networking
- Validate the digital twins infrastrure.
- Provide a digital twins example for the baseline version.