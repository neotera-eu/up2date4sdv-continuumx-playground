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
┌──────────────────────────────────────┐     Host-Only Network
│  VirtualBox Host                     │     192.168.56.0/24
│                                      │
│  ┌───────────────────────────────┐   │   ┌───────────────────────────────┐
│  │  u2d4sdv_cloud  192.168.56.10 │◄──┼──►│  u2d4sdv_edge  192.168.56.11  │
│  │  Debian 13 · K8s v1.32        │   │   │  Debian 13                    │
│  │  CloudCore cx-v1.23           │   │   │  EdgeCore cx-v1.23            │
│  │                               │   │   │                               │
│  │  NAT · Host-Only · Bridged    │   │   │  NAT · Host-Only              │
│  └───────────────────────────────┘   │   └───────────────────────────────┘
│                                      │
└──────────────────────────────────────┘
```

| VM | Hostname | Host-Only IP | Role |
|---|---|---|---|
| VM 0 | `u2deb-cloud` | `192.168.56.10` | K8s Control Plane + ContinuumX CloudCore |
| VM 1 | `u2ded-edge` | `192.168.56.11` | Edge Worker Node + ContinuumX EdgeCore |

---

## Getting Started

Choose the path that suits you:

- **[Option 1](#option-1-build-from-scratch)**, Follow the step-by-step guides to provision both VMs yourself. Recommended if you want to understand what every layer does.
- **[Option 2](#option-2-create-vms-from-pre-built-vdi-disks)**, Download two pre-built VDI disks and create VirtualBox VMs using those existing disks. Recommended if you want a working cluster in minutes.

Both options converge at [Verify the Testbed](#verify-the-testbed).

---

## Option 1, Build from Scratch

Three guides, to be followed in order.

### Step 1, Prepare the CloudCore VM

Follow **[`vm0-continuumx-cloudcore-v1.23.md`](./doc/vm0-continuumx-cloudcore-v1.23.md)** to provision a Debian 13 VM running Kubernetes v1.32 with containerd and Flannel CNI, configured and validated as a ready baseline for ContinuumX CloudCore.

At the end of this guide the VM (`u2d4sdv_cloud`, `192.168.56.10`) will have:
- A fully operational single-node Kubernetes control plane
- All ContinuumX pre-conditions satisfied (taint removed, kube-proxy patched, CA files present, kubeconfig available to root)

### Step 2, Prepare the EdgeCore VM

Follow **[`vm1-continuumx-edgecore-v1.23.md`](./doc/vm1-continuumx-edgecore-v1.23.md)** to provision a second Debian 13 VM with containerd, configured as a minimal edge worker node baseline.

At the end of this guide the VM (`u2d4sdv_edge`, `192.168.56.11`) will have:
- containerd installed and running with `SystemdCgroup = true`
- Static IP on the Host-Only interface, `/etc/hosts` entries for both nodes, swap disabled

### Step 3, Install CloudCore and EdgeCore

Follow **[`continuumx-v1_23-cloudcore-edgecore-install.md`](./doc/continuumx-v1_23-cloudcore-edgecore-install.md)** to deploy ContinuumX on both VMs using `cxadm`.

This guide covers:
- **Part I**, Install `cxadm` on the control plane, run `cxadm init` to deploy CloudCore as a Helm-managed pod in the `kubeedge` namespace, configure Cilium cloud-side, and retrieve the edge join token.
- **Part II**, Install `cxadm` on the edge node, run `cxadm join` to register `u2d4sdv_edge` as a ContinuumX edge worker, and configure Cilium edge-side.

At the end of this guide you will have a live two-node cluster. Continue to [Verify the Testbed](#verify-the-testbed).

---

## Option 2, Create VMs from Pre-Built VDI Disks

Download the two pre-built **Virtual Disk Image (`.vdi`)** files and create a new VirtualBox VM for each one. These files are **virtual hard disks, not VirtualBox appliances** (`.ova`/`.ovf`): do **not** use **File → Import Appliance**. Instead, create each VM with **New** and select **Use an Existing Virtual Hard Disk File**.

The disks already contain Debian 13, Kubernetes and the relevant ContinuumX components (CloudCore/EdgeCore), together with the guest-side configuration. **Do not select a Debian installation ISO or run an unattended OS installation.** Both VMs must be configured to boot in **UEFI/EFI mode**.

### 2.1 Download and Extract the VDI Disks

| VDI disk | VM | Download |
|---|---|---|
| `u2d4sdv_cloud.vdi` | CloudCore (control plane) | [u2d4sdv_cloud.vdi.tar.gz](https://drive.google.com/file/d/1owE9avnQFH84rgoHqRonNX7xVDDgO8ip/view?usp=drive_link) |
| `u2d4sdv_edge.vdi` | EdgeCore (edge worker) | [u2d4sdv_edge.vdi.tar.gz](https://drive.google.com/file/d/1RI-MqrhOZ4BdTkz_tthgPjHZImDyjZYr/view?usp=drive_link) |

1. Download both `.tar.gz` archives.
2. Extract each archive to obtain its `.vdi` disk file. On a Linux host, for example:

   ```bash
   tar -xzf u2d4sdv_cloud.vdi.tar.gz
   tar -xzf u2d4sdv_edge.vdi.tar.gz
   ```

3. Move the extracted VDI files to their **permanent locations** on the host before creating the VMs. VirtualBox will use the existing files directly; avoid moving or renaming them after they have been attached.
4. Confirm that the extracted filenames match those in the table above (or use the actual extracted filenames when selecting the disks).

### 2.2 Create the Host-Only Network in VirtualBox

Both VMs communicate over a dedicated host-only network. Create this network **before** creating the VMs.

1. Open VirtualBox → **File → Tools → Network Manager** (the menu location may vary by VirtualBox version).
2. Select **Host-only Networks**.
3. Click **Create** to add a host-only adapter (for example, `vboxnet0`).
4. Configure:
   - **IPv4 Address:** `192.168.56.1`
   - **IPv4 Network Mask:** `255.255.255.0`
5. Disable the **DHCP Server** for this host-only network; the prepared guest systems use static IP addresses.
6. Click **Apply** if your VirtualBox version requires it.

> **2.3**: Host-only Network Manager showing 192.168.56.1/24 and DHCP disabled.
!["Host-onlyNetworkManager"](./doc/images/Host-onlyNetworkManager.png 'Host-only Network Manager showing 192.168.56.1/24 and DHCP disabled.')

### 2.3 Create the Hoard Disks in VirtualBox

Create the Hard Disks for both VMs **before** creating the VMs.

1. Open VirtualBox → **File → Tools → Menu** (the menu location may vary by VirtualBox version).
2. Select **Hard disks**
3. Click **Add** and select the control plane VM (u2d4sdv_cloud.vdi)
4. Click **Add** and select the edge worker node VM (u2d4sdv_edge.vdi)

> **2.3**: Virtual Box media showing both VMs Hard disks.
!["HardDisks"](./doc/images/vmHd.png 'Virtual Box media showing both VMs Hard disks.')

### 2.4 Create the CloudCore VM (`u2d4sdv_cloud`) from Its VDI

1. In VirtualBox Manager, click **New** to open the **Create Virtual Machine** wizard.
2. Set the VM name to **`u2d4sdv_cloud`** and select a suitable VM folder.
3. Leave the **ISO Image** field empty; the existing VDI already contains the operating system. If the wizard offers unattended installation, leave it disabled / select **Skip Unattended Installation**.
4. Select the guest operating system:
   - **Type:** `Linux`
   - **Distribution:** `Debian` (if this field is shown)
   - **Version:** `Debian (64-bit)` / `Debian 13 (64-bit)` if available. The OS **inside the disk** is Debian 13, regardless of the exact VirtualBox menu label.
5. Allocate CPU and RAM according to the available host resources and the intended Kubernetes workload. These hardware values are not encoded in the VDI file.
6. **Enable EFI/UEFI boot** by selecting **Use EFI** in the wizard's hardware settings, if available. Otherwise enable it after creating the VM under **Settings → System → Motherboard → Enable EFI (special OSes only)** (wording varies by version).
7. In the **Virtual Hard Disk** step choose **Use an Existing Virtual Hard Disk File** (not **Create a Virtual Hard Disk Now**).
8. Open the disk selector (folder icon), click **Add** if necessary, browse to `u2d4sdv_cloud.vdi`, select it, and confirm.
9. Review the summary and click **Finish** to create the VM.
10. **Before first boot**, open **Settings → System** and confirm that EFI is enabled and the VDI is attached as the boot hard disk under **Settings → Storage**.

> **2.4a:** New VM wizard: name `u2d4sdv_cloud`, Linux/Debian 13 (64-bit), no ISO.
!["New VM wizardr"](./doc/images/vmWiz1-cloud.png 'New VM wizard: name `u2d4sdv_cloud`, Linux/Debian 13 (64-bit), no ISO.')

> **2.4b:** Hardware settings with **Use EFI** enabled.
!["SystemUEFI"](./doc/images/vmSystemEFI.png 'Hardware settings with **Use EFI** enabled.')

> **2.4c:** Virtual Hard Disk screen **Use an Existing Virtual Hard Disk File** and `u2d4sdv_cloud.vdi` selected.
!["Virtual Hard Disk"](./doc/images/vmWiz2-cloud.png 'Virtual Hard Disk screen **Use an Existing Virtual Hard Disk File** and `u2d4sdv_cloud.vdi` selected.')

With the VM powered off, open **Settings → Network** and configure the adapters in the same order as the prepared guest network interfaces:

| Adapter | Attached to | Details |
|---|---|---|
| Adapter 1 | NAT | Internet / package access |
| Adapter 2 | Host-Only Adapter | Select `vboxnet0` (or the host-only network created above) |
| Adapter 3 | Bridged Adapter | Select your active physical LAN interface |

Enable each adapter and ensure **Virtual Cable Connected** is checked. For the bridged adapter, select the actual host interface (for example, an Ethernet or Wi-Fi interface) rather than leaving it unassigned.

### 2.5 Create the EdgeCore VM (`u2d4sdv_edge`) from Its VDI

1. Click **New** in VirtualBox Manager to create a **separate** VM.
2. Set the VM name to **`u2d4sdv_edge`** and choose its VM folder.
3. Leave **ISO Image** empty and disable/skip unattended installation; Debian 13 is already installed on the VDI.
4. Select **Linux → Debian → Debian (64-bit)** (or **Debian 13 (64-bit)** if offered).
5. Allocate CPU and RAM appropriate for the edge workloads.
6. Enable **Use EFI** in the wizard, or confirm **Settings → System → Motherboard → Enable EFI** before booting.
7. In the **Virtual Hard Disk** step select **Use an Existing Virtual Hard Disk File**; browse to and attach **`u2d4sdv_edge.vdi`** using the disk selector and **Add** where required.
8. Click **Finish**. Verify the existing VDI under **Settings → Storage** and EFI under **Settings → System** before booting.


> **2.5a:** New VM wizard: name `u2d4sdv_edge`, Linux/Debian 13 (64-bit), no ISO.
!["New VM wizardr"](./doc/images/vmWiz1-edge.png 'New VM wizard: name `u2d4sdv_edge`, Linux/Debian 13 (64-bit), no ISO.')

> **2.5b:** Hardware settings with **Use EFI** enabled.
!["SystemUEFI"](./doc/images/vmSystemEFI.png 'Hardware settings with **Use EFI** enabled.')

> **2.5c:** Virtual Hard Disk screen **Use an Existing Virtual Hard Disk File** and `u2d4sdv_edgevdi` selected.
!["Virtual Hard Disk"](./doc/images/vmWiz2-edge.png 'Virtual Hard Disk screen **Use an Existing Virtual Hard Disk File** and `u2d4sdv_edge.vdi` selected.')


With the VM powered off, open **Settings → Network** and configure:

| Adapter | Attached to | Details |
|---|---|---|
| Adapter 1 | NAT | Internet / package access |
| Adapter 2 | Host-Only Adapter | Select the **same** host-only network used by CloudCore (`vboxnet0` in this example) |

Enable both adapters and check **Cable Connected**.

### 2.6 VMs user

Both VMs have a super user; use the following credentials for logging in:

- Username: **user**
- Password: **user123**

For better user experience, e.g., copy-paste functionality, you may use **ssh** for connecting to the VMs using the NAT adapter IP assigned to each VM.

### 2.7 Start Both VMs

1. Start **`u2d4sdv_cloud`** first and wait until Debian has finished booting and its services have started.
2. Start **`u2d4sdv_edge`**.
3. Confirm that the prepared host-only addresses are present:
   - CloudCore VM: `192.168.56.10`
   - EdgeCore VM: `192.168.56.11`

The EdgeCore service should connect to CloudCore automatically after boot. No manual `cxadm join` is required, because the edge node was already registered in the pre-built image. Proceed to [Verify the Testbed](#verify-the-testbed).


> **Troubleshooting:** If a VM cannot find a bootable disk, check **Settings → Storage** for the correct VDI and **Settings → System** for EFI/UEFI. If the VMs boot but cannot communicate, verify that both use the same host-only network, that DHCP is disabled, and that the adapters are in the order shown above.

---

## Verify the Testbed

Once both VMs are running (regardless of which option you followed), perform the checks below from the **CloudCore VM** (`u2d4sdv_cloud`).

### Check 1, Edge Node Has Joined and Is Ready

```bash
kubectl get nodes -o wide
```

Expected output:

```
NAME           STATUS   ROLES           AGE   VERSION    INTERNAL-IP     OS-IMAGE
u2deb-cloud    Ready    control-plane   ...   v1.32.x    192.168.56.10   Debian GNU/Linux 13
u2deb-edge     Ready    agent,edge      ...   v1.32.x    192.168.56.11   Debian GNU/Linux 13
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
# On u2deb-cloud
kubectl apply -f nginx-edge.yaml
```
> The yaml fle is available at [manifests/templates/nginx-edge.yaml](manifests/templates/nginx-edge.yaml). It is also available at the u2deb-cloud root folder.
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