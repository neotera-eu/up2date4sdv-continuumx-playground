# Kubernetes Control Plane v1.32 on Debian 13 (Trixie) guest VM
## Installation Guide - Baseline for ContinuumX v1.23 CloudCore

> **Target stack:** Debian 13 (Trixie) - Kubernetes v1.32 - containerd as CRI - Flannel CNI
>
> **Scope:** This guide covers only the Kubernetes control plane installation and all
> pre-conditions required to host ContinuumX v1.23 CloudCore. ContinuumX installation
> itself is out of scope and will be covered in a separate guide.

---

## Network Layout

This guide assumes a VirtualBox VM with three network adapters:

| Adapter | VirtualBox Type | Interface | IP | Purpose |
|---|---|---|---|---|
| 1 | NAT | `enp0s3` | 10.0.2.x (DHCP) | Outbound Internet access only |
| 2 | Host-Only | `enp0s8` | `192.168.56.x` (static) | Host-VM, VM-VM, Kubernetes cluster traffic, ContinuumX edge nodes |
| 3 | Bridged | `enp0s9` | DHCP from LAN router | LAN access from other PCs on the local network |

> **Interface names** (`enp0s3`, `enp0s8`, `enp0s9`) are the most common VirtualBox defaults
> on Debian 13 but may differ on your system. Verify with `ip addr show` and substitute
> accordingly throughout this guide.
>
> **The Host-Only IP is the Kubernetes IP.** The Bridged adapter carries a dynamic LAN IP
> and is exposed via mDNS (Avahi) so LAN PCs can reach the cluster using the stable name
> `u2deb-cloud.local` regardless of what IP the DHCP router assigns to the bridged
> interface. The NAT adapter plays no role in cluster networking.

---

## Table of Contents

1. [Prerequisites & VM Baseline](#1-prerequisites--vm-baseline)
2. [System Preparation](#2-system-preparation)
3. [Install containerd](#3-install-containerd)
4. [Install kubeadm, kubelet & kubectl](#4-install-kubeadm-kubelet--kubectl)
5. [Endpoint Strategy and Variables](#5-endpoint-strategy-and-variables)
6. [Initialize the Control Plane](#6-initialize-the-control-plane)
7. [Configure kubectl Access](#7-configure-kubectl-access)
8. [Install a CNI plugin](#8-install-a-cni-plugin)
9. [ContinuumX Pre-Conditions](#9-continuumx-pre-conditions)
10. [Final Cluster Verification](#10-final-cluster-verification)
11. [Troubleshooting](#11-troubleshooting)

---

## 1. Prerequisites & VM Baseline

This guide assumes that your host has **VirtualBox** virtualizer installed. The VirtualBox version used during this guide was *v7.2.6*. Also, that during the guest OS installation only Adapter 1 was enabled in NAT mode.

### Required VM Network Adapters
The following three network adapters has to be enabled.

| Adapter | Mode | Purpose |
|---|---|---|
| Adapter 1 | NAT | Internet access |
| Adapter 2 | Host-Only | Host-VM and VM-VM |
| Adapter 3 | Bridged | LAN access from other PCs |

### Minimum VM Specifications

| Resource | Minimum | Recommended |
|---|---|---|
| vCPU | 2 | 4 |
| RAM | 2 GB | 8 GB |
| Disk | 3 GB | 8 GB |
| OS | Debian 13 (Trixie) | Debian 13 (Trixie) |
| Kernel | 5.10+ (Trixie ships 6.x) | 6.x |
| Host-Only NIC | Static IP required | Static IP required |
| Bridged NIC | DHCP acceptable | DHCP acceptable |

Verify your kernel version:

```bash
uname -r
# Expected: 6.x.x or higher
```

### Required Open Ports

If `ufw` is active or your environment has an external firewall, open these ports before
starting. Ports 30000 and 30002 are the ContinuumX CloudCore NodePorts and are not used
until ContinuumX is installed, but should be opened now.

| Port | Protocol | Component | Notes |
|---|---|---|---|
| 6443 | TCP | kube-apiserver | Required by all clients and by ContinuumX CloudCore |
| 2379–2380 | TCP | etcd | Client and peer traffic (internal) |
| 10250 | TCP | kubelet API | Used by the control plane |
| 10257 | TCP | kube-controller-manager | Internal only |
| 10259 | TCP | kube-scheduler | Internal only |
| 10000 | TCP | ContinuumX CloudHub | WebSocket NodePort, edge nodes connect here |
| 10002 | TCP | ContinuumX CloudCore | Certificate service NodePort |

If `ufw` is active, apply all rules now:

```bash
sudo ufw allow 6443/tcp   comment 'Kubernetes API Server'
sudo ufw allow 10250/tcp  comment 'kubelet API'
sudo ufw allow 10000/tcp  comment 'ContinuumX CloudHub WebSocket NodePort'
sudo ufw allow 10002/tcp  comment 'ContinuumX CloudCore cert NodePort'
sudo ufw reload
```

---

## 2. System Preparation

All commands below must be run as **root** or via `sudo`.

### 2.1 Setup Networking

We assume that the NAT network adapter, enumerated as enp0s3, has been already configured during the OS installation, since only Adapter 1 in NAT mode was enabled.


## Configure Adapter 2 Network Inside the VM

#### IP Plan

| Machine   | Host-Only IP     |
|-----------|-----------------|
| Host OS   | `192.168.56.1`  |
| Server VM | `192.168.56.10` |
| Client VM | `192.168.56.11` |

### Create a Host-Only Network in VirtualBox

1. Open VirtualBox -> **File -> Tools -> Network Manager**
2. Click the **Host-only Networks** tab
3. Click **Create** to add a new host-only network (e.g., `vboxnet0`)
4. Configure the adapter:
   - **IP:** `192.168.56.1`
   - **Mask:** `255.255.255.0`
5. Go to the **DHCP Server** tab and **disable** it
6. Click **Apply**

With the VM off, go to VM **Settings -> Network**:

- **Adapter 2**: Attached to -> **Host-Only Adapter** -> select `vboxnet0`

### OS Nerwork configuration

Boot the VM and first confirm the interface name of the second adapter:

```bash
ip a
```

It is typically `enp0s8`. Then create a config file for it:

```bash
sudo nano /etc/network/interfaces.d/hostonly
```

and write the following content:
```bash
auto enp0s8
iface enp0s8 inet static
address 192.168.56.10
netmask 255.255.255.0
```

## Configure Adapter 3 Network Inside the VM

With the VM off, go to VM **Settings -> Network**:

- **Adapter 3**: Attached to -> **Bridged Adapter**

### OS Nerwork configuration

Boot the VM and first confirm the interface name of the second adapter:

```bash
ip a
```

It is typically `enp0s9`. Then create a config file for it:

```bash
sudo nano /etc/network/interfaces.d/bridged
```

and write the following content:
```bash
auto enp0s9
iface enp0s9 inet dhcp
```

--- 
Make sure `/etc/network/interfaces` includes the directory (it usually does by default):

```bash
cat /etc/network/interfaces
```

It should contain the line below. If missing, add it:

```bash
echo "source /etc/network/interfaces.d/*" | sudo tee -a /etc/network/interfaces
```

Restart Networking to apply the changes:
```bash
sudo systemctl restart networking
```

### 2.2 Update the System

```bash
sudo apt-get update && sudo apt-get upgrade -y
```

### 2.3 Set the Hostname

```bash
sudo hostnamectl set-hostname u2deb-cloud
```

Verify it was applied:

```bash
hostnamectl status | grep 'Static hostname'
# Expected: Static hostname: u2deb-cloud
```

Add the hostname to `/etc/hosts` pointing at the Host-Only (Kubernetes) IP. This ensures
internal cluster resolution works without depending on mDNS or external DNS:

```bash
echo "192.168.56.10  u2deb-cloud.local" | sudo tee -a /etc/hosts
```

### 2.4 Disable Swap

Kubernetes requires swap to be fully off. Disable it for the live session and remove it
permanently from `/etc/fstab`:

```bash
sudo swapoff -a
sudo sed -i '/\bswap\b/d' /etc/fstab
```

Mask the swap systemd unit to prevent it re-activating on reboot:

```bash
sudo systemctl mask swap.target 2>/dev/null || true
```

Verify swap is gone:

```bash
swapon --show
# Expected: no output

free -h | grep Swap
# Expected: Swap: 0B   0B   0B
```

### 2.5 Load Required Kernel Modules

containerd and kube-proxy require `overlay` and `br_netfilter`. Configure all modules to
load at boot and activate them immediately:

```bash
cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

sudo modprobe overlay
sudo modprobe br_netfilter
```

Verify both are loaded:

```bash
lsmod | grep -E '^overlay|^br_netfilter'
```

### 2.6 Set Required sysctl Parameters

```bash
cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

sudo sysctl --system
```

Verify the critical parameters applied:

```bash
sysctl net.ipv4.ip_forward net.bridge.bridge-nf-call-iptables
# Both should return = 1
```

### 2.7 Install Required System Dependencies

```bash
sudo apt-get install -y \
  apt-transport-https \
  ca-certificates \
  curl \
  gnupg \
  lsb-release \
  socat \
  conntrack \
  ipset \
  iptables
```

---

## 3. Install containerd

### 3.1 Add Docker's Official Repository

containerd is distributed via Docker's APT repository for Debian:

```bash
sudo install -m 0755 -d /etc/apt/keyrings

curl -fsSL https://download.docker.com/linux/debian/gpg | \
  sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg

sudo chmod a+r /etc/apt/keyrings/docker.gpg

echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/debian \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
```

### 3.2 Install containerd

```bash
sudo apt-get update
sudo apt-get install -y containerd.io
```

### 3.3 Configure containerd

Generate the default configuration and enable the `SystemdCgroup` driver. This is
mandatory, Kubernetes and containerd must use the same cgroup driver, and `systemd` is the
correct choice on Debian 13:

```bash
sudo mkdir -p /etc/containerd
containerd config default | sudo tee /etc/containerd/config.toml > /dev/null
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
```

Verify the change:

```bash
grep 'SystemdCgroup' /etc/containerd/config.toml
# Expected: SystemdCgroup = true
```

> **Critical:** `SystemdCgroup = true` must never be reverted after the cluster is running.
> Changing it will break the cluster and require a full reset.

### 3.4 Enable and Start containerd

```bash
sudo systemctl enable --now containerd
sudo systemctl restart containerd
sudo systemctl status containerd
```

Confirm the socket exists:

```bash
ls -la /run/containerd/containerd.sock
# Expected: srw-rw---- ... /run/containerd/containerd.sock
```

---

## 4. Install kubeadm, kubelet & kubectl

### 4.1 Add the Kubernetes v1.32 APT Repository

The legacy `apt.kubernetes.io` repository is deprecated. Use the official per-minor-version
repository:

```bash
sudo mkdir -p /etc/apt/keyrings

curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.32/deb/Release.key | \
  sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.32/deb/ /' | \
  sudo tee /etc/apt/sources.list.d/kubernetes.list
```

### 4.2 Install the Kubernetes Tooling

```bash
sudo apt-get update
sudo apt-get install -y kubelet=1.32.13-1.1 kubeadm=1.32.13-1.1 kubectl=1.32.13-1.1
```

### 4.3 Pin Package Versions

This prevents apt from upgrading Kubernetes components unexpectedly, which could break
ContinuumX compatibility:

```bash
sudo apt-mark hold kubelet kubeadm kubectl
```

Confirm they are held:

```bash
apt-mark showhold
# Expected: kubelet, kubeadm, kubectl
```

### 4.4 Enable kubelet

```bash
sudo systemctl enable --now kubelet
```

> **Note:** kubelet will enter a crash-loop at this point. This is expected, it requires a
> cluster configuration that `kubeadm init` provides in Section 6.

---

## 5. Endpoint Strategy and Variables

The `controlPlaneEndpoint` written into the kubeadm configuration is baked permanently into
the cluster's TLS certificates and all generated kubeconfigs. Getting this right before
`kubeadm init` avoids having to rotate certificates later.

### Design for this setup

The cluster uses **Strategy C: hostname as primary endpoint + all reachable addresses as
certificate SANs**. The result is:

- **Kubernetes cluster traffic and ContinuumX edge nodes** connect via the bare hostname
  `u2deb-cloud.local` (resolves via `/etc/hosts` on each node) or the static Host-Only IP `192.168.56.10`.
- **LAN PCs** connect via `u2deb-cloud.lan` (the user has to explicitly set or update the IP address, since the Bridged adapter uses DHCP-assigned IP).
- **Local tools on the VM itself** can use `localhost` or `127.0.0.1`.

All of the above are included as SANs in the API server certificate, so TLS validates
correctly through any of these addresses without requiring `--insecure-skip-tls-verify`.

### Set the variables

```bash
# Host-Only adapter IP, static, used for cluster traffic
NODE_IP="192.168.56.10"

# Bare hostname set in Section 2.2
CONTROL_PLANE_HOSTNAME="u2deb-cloud.local"

CONTROL_PLANE_HOSTNAME_LAN="u2deb-cloud.lan"

# Primary endpoint written into kubeconfigs and the cluster record
CONTROL_PLANE_ENDPOINT="${CONTROL_PLANE_HOSTNAME}:6443"
```

Verify the hostname resolves to the correct IP before continuing:

```bash
ping -c 2 "${CONTROL_PLANE_HOSTNAME}"
# Expected: replies from 192.168.56.10
```

---

## 6. Initialize the Control Plane

### 6.1 Pre-fetch Control Plane Images (Optional)

```bash
sudo kubeadm config images pull \
  --kubernetes-version v1.32.13 \
  --cri-socket unix:///run/containerd/containerd.sock
```

### 6.2 Create the kubeadm Configuration File

```bash
cat <<EOF | sudo tee /etc/kubernetes/kubeadm-config.yaml
apiVersion: kubeadm.k8s.io/v1beta4
kind: InitConfiguration
localAPIEndpoint:
  advertiseAddress: "${NODE_IP}"
  bindPort: 6443
nodeRegistration:
  criSocket: unix:///run/containerd/containerd.sock
  name: ${CONTROL_PLANE_HOSTNAME}
---
apiVersion: kubeadm.k8s.io/v1beta4
kind: ClusterConfiguration
kubernetesVersion: "v1.32.13"
controlPlaneEndpoint: "${CONTROL_PLANE_ENDPOINT}"
apiServer:
  certSANs:
    - "${CONTROL_PLANE_HOSTNAME}"          # bare hostname  -> Host-Only / cluster traffic
    - "${CONTROL_PLANE_HOSTNAME_LAN}"    # DNS name      -> Bridged / LAN PCs
    - "${NODE_IP}"                         # Host-Only IP   -> direct IP access
    - "127.0.0.1"                          # loopback
    - "localhost"
networking:
  #podSubnet: "10.0.0.0/8"                 # Cilium default IPAM range, do not use 10.244.0.0/16
  podSubnet: "10.244.0.0/16"
  serviceSubnet: "10.96.0.0/12"
---
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
cgroupDriver: systemd
EOF
```

### 6.3 Run kubeadm init

```bash
sudo kubeadm init --config /etc/kubernetes/kubeadm-config.yaml
```

This process takes 2–5 minutes. When it completes, save the printed `kubeadm join` command
— you will need the token and CA hash to join worker nodes later.

> **Node will show NotReady** after init completes. This is expected and correct, the node
> stays `NotReady` until some CNI is installed in Section 8. Do not attempt to install the CNI
> before completing kubectl access setup in Section 7.

---

## 7. Configure kubectl Access

### 7.1 Set Up kubeconfig for Your User

```bash
mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config
```

Test access:

```bash
kubectl cluster-info
kubectl get nodes
# Node will show: NotReady, this is expected until CNI is installed
```

### 7.2 Verify the Endpoint in Your kubeconfig

```bash
kubectl config view --minify | grep server
# Expected: server: https://u2deb-cloud:6443
```

### 7.3 Enable Shell Autocompletion (Recommended)

```bash
sudo apt-get install -y bash-completion
echo 'source <(kubectl completion bash)' >> ~/.bashrc
echo 'alias k=kubectl' >> ~/.bashrc
echo 'complete -o default -F __start_kubectl k' >> ~/.bashrc
source ~/.bashrc
```

### 7.4 Prepare a kubeconfig for LAN PCs

LAN PCs need a kubeconfig pointing to the DNS name so it keeps working across Bridged IP
changes:

```bash
sed "s|https://${CONTROL_PLANE_HOSTNAME}:6443|https://${CONTROL_PLANE_HOSTNAME_LAN}:6443|g" \
  $HOME/.kube/config > $HOME/.kube/config-lan

echo "LAN kubeconfig written to: $HOME/.kube/config-lan"
echo "Copy this file to LAN PCs and place it at ~/.kube/config"
```

---

## 8. Install a CNI Plugin

Without a CNI plugin, pods cannot communicate and the node stays `NotReady`. Flannel is used here because its default pod CIDR (`10.244.0.0/16`) matches the `podSubnet` set in Section 6, and it integrates cleanly with ContinuumX's edge networking model (CNI is only required on the cloud side, ContinuumX edge nodes do not use the cluster CNI).

> If you prefer Calico, change `podSubnet` to `192.168.0.0/16` in the kubeadm config and apply the Calico operator manifest instead. Either CNI works for the cloud-side control plane.

### 8.1 Deploy Flannel

```bash
kubectl apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml
```

### 8.2 Wait for Flannel to Become Ready

```bash
kubectl -n kube-flannel get pods -w
# Wait until all flannel pods show: Running
```

Press `Ctrl+C` once all pods are Running.

### 8.3 Confirm the Node is Ready

```bash
kubectl get nodes -o wide
# NAME          STATUS   ROLES           AGE   VERSION
# u2deb-cloud   Ready    control-plane   Xm    v1.32.x
```

### 8.4 Disable Flannel deployment on edge nodes
Flannel CNI is not supported by ContinuumX for the edge nodes
```bash
kubectl patch daemonset kube-flannel-ds -n kube-flannel -p '
{
  "spec": 
    {"template": 
      {"spec": 
        {"affinity": 
          {"nodeAffinity":
            {"requiredDuringSchedulingIgnoredDuringExecution": 
              {"nodeSelectorTerms": 
                [
                  {"matchExpressions": 
                    [
                      {
                        "key": "node-role.kubernetes.io/edge", 
                        "operator": "DoesNotExist"
                      }
                    ]
                  }
                ]
              }
            }
          }
        }
      }
    }
}'
```
---

## 9. ContinuumX Pre-Conditions

Every item in this section must be completed before ContinuumX CloudCore can be installed.

### 9.1 Remove the Control Plane Taint

By default, the control plane node has a `NoSchedule` taint that prevents pods from running
on it. ContinuumX CloudCore is deployed as a pod on this node, so the taint must be
removed:

```bash
kubectl taint nodes u2deb-cloud.local node-role.kubernetes.io/control-plane:NoSchedule-
```

Confirm the taint is cleared:

```bash
kubectl describe node u2deb-cloud.local | grep Taints
# Expected: no node-role.kubernetes.io/control-plane:NoSchedule taint
```

### 9.2 Prevent kube-proxy from Running on Edge Nodes

ContinuumX does not support `kube-proxy` on edge nodes. Patch the `kube-proxy` DaemonSet
to exclude any node carrying the `node-role.kubernetes.io/edge` label, which ContinuumX
automatically assigns to edge nodes on join:

```bash
kubectl patch daemonset kube-proxy -n kube-system --type='json' -p='[
  {
    "op": "add",
    "path": "/spec/template/spec/affinity",
    "value": {
      "nodeAffinity": {
        "requiredDuringSchedulingIgnoredDuringExecution": {
          "nodeSelectorTerms": [
            {
              "matchExpressions": [
                {
                  "key": "node-role.kubernetes.io/edge",
                  "operator": "DoesNotExist"
                }
              ]
            }
          ]
        }
      }
    }
  }
]'
```

Verify the patch was applied:

```bash
kubectl get daemonset kube-proxy -n kube-system \
  -o jsonpath='{.spec.template.spec.affinity}' | python3 -m json.tool
```

### 9.3 Confirm the Kubernetes CA Files Are Present

CloudCore requires direct read access to the cluster CA. Verify both files exist with
non-zero sizes:

```bash
sudo ls -la /etc/kubernetes/pki/ca.crt /etc/kubernetes/pki/ca.key
```

If either is missing, `kubeadm init` did not complete successfully, run `kubeadm reset` and restart from Section 6.

### 9.4 Make kubeconfig Available to Root

CloudCore defaults to reading kubeconfig from `/root/.kube/config`:

```bash
sudo mkdir -p /root/.kube
sudo cp $HOME/.kube/config /root/.kube/config
```

Test that root can reach the cluster:

```bash
sudo kubectl get nodes
# Expected: u2deb-cloud   Ready   control-plane   ...
```

### 9.5 Record Endpoint Information for Edge Nodes

When ContinuumX edge nodes are configured, they will need to reach this control plane.
Record the active SANs and endpoints now:

```bash
echo "=== Endpoint Information for Edge Node Configuration ==="
echo "Primary endpoint (cluster traffic) : u2deb-cloud:6443"
echo "LAN endpoint (mDNS)                : u2deb-cloud.local:6443"
echo "Direct IP endpoint (Host-Only)     : ${NODE_IP}:6443"
echo ""
echo "=== API Server Certificate SANs ==="
openssl x509 -in /etc/kubernetes/pki/apiserver.crt -noout -ext subjectAltName
```

Edge nodes on the Host-Only network (VM↔VM) use `u2deb-cloud:6443` and resolve it via
their own `/etc/hosts` entry (`192.168.56.10 u2deb-cloud`). Edge nodes on the LAN use
`u2deb-cloud.local:6443` and rely on mDNS, no configuration needed on the edge node side
as long as `avahi-daemon` or equivalent is installed there.

---

## 10. Final Cluster Verification

Run these checks to confirm the cluster is fully healthy and ready for ContinuumX CloudCore
installation.

### 10.1 Node and System Pod Status

```bash
kubectl get nodes -o wide
kubectl get pods -n kube-system
```

All pods in `kube-system` should be `Running` or `Completed`. None should be in `Pending`,
`CrashLoopBackOff`, or `Error`.

### 10.2 API Server Health

```bash
kubectl get --raw='/healthz?verbose'
# All checks should report: ok
```

### 10.3 Confirm containerd as the Active CRI

```bash
kubectl get node u2deb-cloud.local \
  -o jsonpath='{.status.nodeInfo.containerRuntimeVersion}'
# Expected: containerd://x.x.x
```

### 10.4 Verify Certificate SANs

Confirm all SANs are present in the API server certificate:

```bash
openssl x509 -in /etc/kubernetes/pki/apiserver.crt -noout -ext subjectAltName
# Expected to include:
#   DNS:u2deb-cloud.lan
#   DNS:u2deb-cloud.local
#   IP Address:192.168.56.10
#   IP Address:127.0.0.1
```

### 10.5 Test Reachability via All Endpoints

```bash
# Via bare hostname (Host-Only / cluster traffic)
curl -k https://u2deb-cloud.local:6443/healthz
# Expected: ok

# Via mDNS name (Bridged / LAN PCs)
# set at /etc/hosts: 
# u2deb-cloud.lan <Bridged interface IP>
curl -k https://u2deb-cloud.lan:6443/healthz
# Expected: ok

# Via static IP (Host-Only direct)
curl -k https://${NODE_IP}:6443/healthz
# Expected: ok
```

### 10.6 Test Pod Scheduling

```bash
kubectl run smoke-test --image=nginx:alpine --restart=Never
kubectl wait --for=condition=Ready pod/smoke-test --timeout=60s
kubectl delete pod smoke-test
```

### 10.7 Pre-Conditions Checklist

Before proceeding to ContinuumX CloudCore installation, confirm every item:

- [ ] Node shows `STATUS: Ready`
- [ ] All `kube-system` pods are `Running` or `Completed`
- [ ] containerd is the reported CRI (`containerd://x.x.x`)
- [ ] `SystemdCgroup = true` confirmed in `/etc/containerd/config.toml`
- [ ] Avahi daemon is active (`systemctl is-active avahi-daemon` → `active`)
- [ ] `u2deb-cloud.local` resolves and ping succeeds from the VM
- [ ] Control plane taint removed (`Taints: <none>`)
- [ ] kube-proxy DaemonSet has edge node affinity exclusion applied
- [ ] `/etc/kubernetes/pki/ca.crt` and `ca.key` both present
- [ ] `/root/.kube/config` present and `sudo kubectl get nodes` succeeds
- [ ] Certificate SANs include `u2deb-cloud`, `u2deb-cloud.local`, `192.168.56.10`, `127.0.0.1`
- [ ] All three `curl -k https://<endpoint>:6443/healthz` calls return `ok`
- [ ] Ports 6443, 4240, 8472, 30000, and 30002 open inbound

---

## 11. Troubleshooting

### kubelet Fails to Start After kubeadm init

```bash
sudo journalctl -u kubelet -n 100 --no-pager
```

Common causes: `SystemdCgroup = false` in containerd config, swap still active, or CRI
socket not found. Fix the root cause, restart containerd
(`sudo systemctl restart containerd`), and re-run `kubeadm init` after a reset.

### TLS Error When Connecting via a Hostname

This means the hostname was not included in `certSANs` at init time. Verify:

```bash
openssl x509 -in /etc/kubernetes/pki/apiserver.crt -noout -ext subjectAltName
```

If a name is missing, rotate the API server certificate without a full cluster reset:

```bash
sudo cp /etc/kubernetes/pki/apiserver.crt /etc/kubernetes/pki/apiserver.crt.bak
sudo cp /etc/kubernetes/pki/apiserver.key /etc/kubernetes/pki/apiserver.key.bak
sudo rm /etc/kubernetes/pki/apiserver.crt /etc/kubernetes/pki/apiserver.key
sudo kubeadm init phase certs apiserver --config /etc/kubernetes/kubeadm-config.yaml
sudo mv /etc/kubernetes/manifests/kube-apiserver.yaml /tmp/
sleep 5
sudo mv /tmp/kube-apiserver.yaml /etc/kubernetes/manifests/
openssl x509 -in /etc/kubernetes/pki/apiserver.crt -noout -ext subjectAltName
```

### Full Reset and Retry

If initialization failed and you need to start from scratch:

```bash
sudo kubeadm reset -f
sudo rm -rf /etc/cni/net.d /var/lib/etcd $HOME/.kube /root/.kube
sudo iptables -F && sudo iptables -t nat -F && sudo iptables -t mangle -F && sudo iptables -X
sudo systemctl restart containerd
```

Then return to [Section 7](#7-initialize-the-control-plane).

---

*Guide scope: Kubernetes v1.32 Control Plane · Debian 13 (Trixie) · containerd · VirtualBox (NAT + Host-Only + Bridged) · mDNS via Avahi ·
Pre-conditions for ContinuumX v1.23 CloudCore*

*ContinuumX v1.23.0 released 2026-03-11 · vendors Kubernetes v1.32.10
