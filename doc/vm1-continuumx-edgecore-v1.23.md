# ContinuumX v1.23 EdgeCore Node on Debian 13 (Trixie) guest VM
## Installation Guide: VM Baseline, containerd & MQTT Broker

> **Target stack:** Debian 13 (Trixie) · containerd as CRI · Mosquitto MQTT broker
>
> **Scope:** This guide covers the full preparation of a VM to serve as a ContinuumX
> EdgeCore node: VM configuration, networking, containerd, and the Mosquitto MQTT broker.
> ContinuumX EdgeCore installation itself is out of scope and will be covered in a
> separate guide.
>
> **Network design:** Unlike the CloudCore VM (which carries three adapters), this edge
> node is intentionally minimal: only the Host-Only adapter is enabled in its final
> configuration. The edge node communicates with the CloudCore control plane exclusively
> over the `192.168.56.0/24` host-only network.
>
> **Internet access during setup:** Package installation requires outbound internet access.
> The NAT adapter (Adapter 1) is kept enabled throughout this guide for that purpose.
> Section 1.2 describes how to disable it in VirtualBox once provisioning is complete,
> leaving only the Host-Only adapter active for runtime operation.
>
> **Naming note:** This guide uses **ContinuumX** throughout as the name of the SDV-targeted
> edge framework. References to upstream tooling (EdgeCore, CloudCore, etc.) remain as-is
> since those are binary and component names in the codebase.

---

## Network Layout

This guide configures the edge VM with a single active adapter for runtime:

| Adapter | VirtualBox Type | Interface | IP | Purpose |
|---|---|---|---|---|
| 1 | NAT | `enp0s3` | 10.0.2.x (DHCP) | Internet access, **setup only, disabled after provisioning** |
| 2 | Host-Only | `enp0s8` | `192.168.56.11` (static) | Cluster traffic, EdgeCore ↔ CloudCore, MQTT |

> **Interface names** (`enp0s3`, `enp0s8`) are the most common VirtualBox defaults on
> Debian 13 but may differ on your system. Verify with `ip addr show` and substitute
> accordingly throughout this guide.
>
> **IP Plan reminder:**
>
> | Machine       | Host-Only IP      |
> |---------------|-------------------|
> | Host OS       | `192.168.56.1`    |
> | CloudCore VM  | `192.168.56.10`   |
> | EdgeCore VM   | `192.168.56.11`   |

---

## Table of Contents

1. [Prerequisites & VM Baseline](#1-prerequisites--vm-baseline)
2. [System Preparation](#2-system-preparation)
3. [Install containerd](#3-install-containerd)
4. [Final Node Verification](#5-final-node-verification)
5. [Troubleshooting](#6-troubleshooting)
<!-- 4. [Install and Configure Mosquitto MQTT Broker](#4-install-and-configure-mosquitto-mqtt-broker) -->
---

## 1. Prerequisites & VM Baseline

This guide assumes that your host has **VirtualBox** installed (v7.2.6 was used during
authoring) and that during the Debian 13 guest OS installation only Adapter 1 was enabled
in NAT mode, the same starting assumption as the CloudCore guide.

### 1.1 Required VM Network Adapters

Two adapters are needed during provisioning; only one survives to runtime.

| Adapter | Mode | Active During | Purpose |
|---|---|---|---|
| Adapter 1 | NAT | Setup only | Outbound internet for `apt` |
| Adapter 2 | Host-Only | Setup + Runtime | Cluster and MQTT traffic |

### 1.2 Minimum VM Specifications

The EdgeCore node has a lighter footprint than the CloudCore VM, no etcd, no kube-apiserver,
no CNI operator. The requirements below reflect a node running EdgeCore and Mosquitto
alongside a modest edge workload.

| Resource | Minimum | Recommended |
|---|---|---|
| vCPU | 1 | 2 |
| RAM | 512 MB | 2 GB |
| Disk | 2 GB | 8 GB |
| OS | Debian 13 (Trixie) | Debian 13 (Trixie) |
| Kernel | 4.15+ (containerd) | 6.x (Trixie default) |
| Host-Only NIC | Static IP required | Static IP required |

### 1.3 Configure VM Network Adapters in VirtualBox

With the VM powered off, open VM **Settings -> Network**.

#### Create the Host-Only Network (if not already present from the CloudCore setup)

1. Open VirtualBox -> **File -> Tools -> Network Manager**
2. Click the **Host-only Networks** tab
3. If `vboxnet0` (`192.168.56.1 / 255.255.255.0`) is already present from the CloudCore
   guide, skip to the next step. Otherwise click **Create** and configure:
   - **IP:** `192.168.56.1`
   - **Mask:** `255.255.255.0`
4. Go to the **DHCP Server** tab and ensure it is **disabled**
5. Click **Apply**

#### Adapter Settings

- **Adapter 1**: Attached to -> **NAT** *(leave as-is from OS installation)*
- **Adapter 2**: Attached to -> **Host-Only Adapter** -> select `vboxnet0`

### 1.4 Required Open Ports

If `ufw` is active or your environment has an external firewall, ensure the following
ports are accessible on the edge node. These are the ports EdgeCore and Mosquitto need.

| Port | Protocol | Component | Notes |
|---|---|---|---|
| 10350 | TCP | EdgeCore MetaServer | In-cluster API access from edge pods |
| 10255 | TCP | EdgeCore read-only kubelet | Metrics and pod status queries |
| 1883 | TCP | Mosquitto MQTT broker | EdgeCore internal event bus |

If `ufw` is active, apply the rules now:

```bash
sudo ufw allow 10350/tcp  --comment 'EdgeCore MetaServer'
sudo ufw allow 10255/tcp  --comment 'EdgeCore read-only kubelet'
sudo ufw allow 1883/tcp   --comment 'Mosquitto MQTT broker'
sudo ufw reload
```

---

## 2. System Preparation

All commands below must be run as **root** or via `sudo`.

### 2.1 Configure Adapter 2 (Host-Only) Inside the VM

Boot the VM and identify the interface name of the second adapter:

```bash
ip a
```

It is typically `enp0s8`. Create a static configuration file for it:

```bash
sudo nano /etc/network/interfaces.d/hostonly
```

Write the following content:

```
auto enp0s8
iface enp0s8 inet static
address 192.168.56.11
netmask 255.255.255.0
```

Ensure `/etc/network/interfaces` sources the directory (it usually does by default):

```bash
cat /etc/network/interfaces
```

The file must contain the line below. If it is missing, add it:

```bash
echo "source /etc/network/interfaces.d/*" | sudo tee -a /etc/network/interfaces
```

Restart networking to apply the change:

```bash
sudo systemctl restart networking
```

Verify the static IP is assigned:

```bash
ip addr show enp0s8
# Expected: inet 192.168.56.11/24
```

Confirm reachability of the CloudCore node across the host-only network:

```bash
ping -c 3 192.168.56.10
# Expected: replies from 192.168.56.10
```

### 2.2 Update the System

```bash
sudo apt-get update && sudo apt-get upgrade -y
```

### 2.3 Set the Hostname

```bash
sudo hostnamectl set-hostname u2deb-edge
```

Verify it was applied:

```bash
hostnamectl status | grep 'Static hostname'
# Expected: Static hostname: u2deb-edge
```

Add the edge node's own hostname to `/etc/hosts` pointing at its Host-Only IP. This
ensures local name resolution works without depending on external DNS:

```bash
echo "192.168.56.11  u2deb-edge.local" | sudo tee -a /etc/hosts
```

Also add an entry for the CloudCore node so EdgeCore can reach it by name:

```bash
echo "192.168.56.10  u2deb-cloud.local" | sudo tee -a /etc/hosts
```

Verify both resolve:

```bash
ping -c 2 u2deb-edge.local
ping -c 2 u2deb-cloud.local
```

### 2.4 Disable Swap

EdgeCore, like kubelet on the control plane, does not support running with swap enabled.
Disable it for the live session and remove it permanently from `/etc/fstab`:

```bash
sudo swapoff -a
sudo sed -i '/\bswap\b/d' /etc/fstab
```

Mask the swap systemd unit to prevent re-activation on reboot:

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

containerd requires `overlay` and `br_netfilter`. Configure them to load at boot and
activate them immediately:

```bash
cat <<EOF | sudo tee /etc/modules-load.d/containerd.conf
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
cat <<EOF | sudo tee /etc/sysctl.d/99-containerd.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

sudo sysctl --system
```

Verify the critical parameters applied:

```bash
sudo sysctl net.ipv4.ip_forward net.bridge.bridge-nf-call-iptables
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

EdgeCore uses containerd as its Container Runtime Interface (CRI). The installation and
configuration steps here are identical to those on the CloudCore node to ensure runtime
compatibility.

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

Generate the default configuration and enable the `SystemdCgroup` driver. This must match
the cgroup driver used on the CloudCore node:

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

> **Critical:** `SystemdCgroup = true` must never be reverted after EdgeCore joins the
> cluster. Changing it will break the runtime and require a full node re-join.

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

### 3.5 Install the latest CNI plugins.

Install CNI plugins:
```bash
VER=$(curl -s https://api.github.com/repos/containernetworking/plugins/releases | grep tag_name | cut -d '"' -f 4 | sed 1q | sed 's/v//g')
wget https://github.com/containernetworking/plugins/releases/download/v$VER/cni-plugins-linux-amd64-v$VER.tgz
mkdir -p /opt/cni/bin
sudo tar Cxzvf /opt/cni/bin cni-plugins-linux-amd64-v$VER.tgz
rm cni-plugins-linux-amd64-v$VER.tgz
```

Setup CNI bridge:
```bash
mkdir -p /etc/cni/net.d/
cat << EOF | sudo tee /etc/cni/net.d/10-containerd-net.conflist
{
  "cniVersion": "1.0.0",
  "name": "containerd-net",
  "plugins": 
  [
    {
      "type": "bridge",
      "bridge": "cni0",
      "isGateway": true,
      "ipMasq": true,
      "promiscMode": true,
      "ipam": {
        "type": "host-local",
        "ranges": [
          [{
            "subnet": "10.88.0.0/16"
          }],
          [{
            "subnet": "2001:4860:4860::/64"
          }]
        ],
        "routes": [
          { "dst": "0.0.0.0/0" },
          { "dst": "::/0" }
        ]
      }
    },
    {
      "type": "portmap",
      "capabilities": {"portMappings": true}
    }
  ]
}
EOF
```

---

<!-- ## 4. Install and Configure Mosquitto MQTT Broker

ContinuumX EdgeCore uses an MQTT broker as its internal event bus for device twins,
telemetry, and edge-cloud message routing. Mosquitto is the recommended broker for edge
nodes due to its minimal resource footprint.

### 4.1 Install Mosquitto

Mosquitto is available in the standard Debian repositories:

```bash
sudo apt-get update
sudo apt-get install -y mosquitto mosquitto-clients
```

`mosquitto-clients` installs the `mosquitto_pub` and `mosquitto_sub` command-line tools,
which are useful for verifying broker operation.

### 4.2 Configure Mosquitto

The default Debian Mosquitto package ships a minimal `/etc/mosquitto/mosquitto.conf` that
sources everything under `/etc/mosquitto/conf.d/`. Drop the EdgeCore configuration there
to keep it separate from any future package-managed defaults:

```bash
sudo nano /etc/mosquitto/conf.d/edgecore.conf
```

Write the following content:

```
# EdgeCore MQTT broker configuration
# Listener on all interfaces, port 1883 (unencrypted)
# EdgeCore connects on localhost; adjust bind_address if external access is needed.

listener 1883
allow_anonymous true
```

> **Security note:** `allow_anonymous true` is intentional for EdgeCore's local IPC.
> EdgeCore connects to the broker on `localhost:1883` and does not expose the broker to the
> host-only network. If your deployment requires external MQTT clients on the host-only
> network, consider adding password authentication or TLS. See the Mosquitto documentation
> for `password_file` and `cafile` directives. -->

<!-- Verify the configuration file has no syntax errors: -->

<!-- ```bash
sudo mosquitto -c /etc/mosquitto/conf.d/edgecore.conf --test-config
# Expected: Config loaded from /etc/mosquitto/conf.d/edgecore.conf.
``` -->

<!-- ### 4.3 Enable and Start Mosquitto

```bash
sudo systemctl enable --now mosquitto
sudo systemctl status mosquitto
```

### 4.4 Verify the Broker is Listening on Port 1883

```bash
ss -tlnp | grep 1883
# Expected: LISTEN  0  ... 0.0.0.0:1883  ...  users:(("mosquitto",...))
```

### 4.5 Smoke-Test the Broker

Open two terminals (or use `&` backgrounding) and verify publish/subscribe round-trips:

```bash
# Terminal 1, subscribe and wait
mosquitto_sub -h localhost -p 1883 -t test/edgecore

# Terminal 2, publish a test message
mosquitto_pub -h localhost -p 1883 -t test/edgecore -m "hello from edge"
```

Terminal 1 should print `hello from edge`. Press `Ctrl+C` to exit the subscriber. -->

---

## 4. Final Node Verification

Run these checks to confirm the node is fully ready for EdgeCore installation.

### 4.1 Network and Hostname

```bash
hostname
# Expected: u2deb-edge

ip addr show enp0s8 | grep 'inet '
# Expected: inet 192.168.56.11/24

ping -c 2 u2deb-cloud.local
# Expected: replies from 192.168.56.10
```

### 4.2 Swap Disabled

```bash
swapon --show
# Expected: no output

free -h | grep Swap
# Expected: Swap: 0B   0B   0B
```

### 4.3 Kernel Modules Loaded

```bash
lsmod | grep -E '^overlay|^br_netfilter'
# Expected: both lines present
```

### 4.4 containerd Running and Configured

```bash
sudo systemctl is-active containerd
# Expected: active

grep 'SystemdCgroup' /etc/containerd/config.toml
# Expected: SystemdCgroup = true

ls -la /run/containerd/containerd.sock
# Expected: socket file present
```

<!-- ### 4.5 Mosquitto Running on Port 1883

```bash
sudo systemctl is-active mosquitto
# Expected: active

ss -tlnp | grep 1883
# Expected: LISTEN ... mosquitto ...
``` -->

<!-- ### 5.6 Disable the NAT Adapter (Final Step)

Once all packages are installed and the node is verified, power off the VM and remove
internet access by disabling Adapter 1:

1. Power off the VM: `sudo poweroff`
2. In VirtualBox, open VM **Settings -> Network -> Adapter 1**
3. Uncheck **Enable Network Adapter**
4. Click **OK**
5. Boot the VM

After reboot, confirm only the host-only interface is active:

```bash
ip addr show
# Expected: only lo and enp0s8 (192.168.56.11) are present, enp0s3 is gone
```

Verify the CloudCore node is still reachable:

```bash
ping -c 2 192.168.56.10
# Expected: replies from 192.168.56.10
``` -->

### 4.5 Pre-Conditions Checklist

Before proceeding to ContinuumX EdgeCore installation, confirm every item:

- [ ] Hostname is `u2deb-edge` (`hostnamectl status` -> `Static hostname: u2deb-edge`)
- [ ] `enp0s8` has static IP `192.168.56.11/24`
- [ ] NAT adapter (Adapter 1 / `enp0s3`) is disabled in VirtualBox
- [ ] `ping 192.168.56.10` succeeds (CloudCore reachable)
- [ ] Swap is fully off (`swapon --show` returns no output)
- [ ] `overlay` and `br_netfilter` modules are loaded (`lsmod` confirms both)
- [ ] `net.ipv4.ip_forward = 1` and `net.bridge.bridge-nf-call-iptables = 1`
- [ ] containerd is `active` and `SystemdCgroup = true` in its config
- [ ] `/run/containerd/containerd.sock` exists
<!-- - [ ] Mosquitto is `active` and listening on `0.0.0.0:1883`
- [ ] `mosquitto_pub` / `mosquitto_sub` round-trip test passes -->

---

## 5. Troubleshooting

### enp0s8 Does Not Come Up After Reboot

```bash
sudo systemctl status networking
sudo journalctl -u networking --no-pager -n 50
```

Common cause: the `source /etc/network/interfaces.d/*` line is missing from
`/etc/network/interfaces`. Add it and restart networking:

```bash
echo "source /etc/network/interfaces.d/*" | sudo tee -a /etc/network/interfaces
sudo systemctl restart networking
```

### Cannot Ping CloudCore (192.168.56.10)

Verify the host-only interface is up and has the correct IP:

```bash
ip addr show enp0s8
```

If the IP is missing, bring the interface up manually and check for errors:

```bash
sudo ifup enp0s8
```

Confirm the VirtualBox host-only network (`vboxnet0`) has **DHCP disabled** and is
configured as `192.168.56.1/24`. A running DHCP server on `vboxnet0` can override the
static configuration.

### containerd Fails to Start

```bash
sudo journalctl -u containerd -n 100 --no-pager
```

Common causes: `overlay` kernel module not loaded, or a stale socket from a previous
failed start. Resolve with:

```bash
sudo modprobe overlay
sudo rm -f /run/containerd/containerd.sock
sudo systemctl restart containerd
```

<!-- ### Mosquitto Fails to Start or Exits Immediately

```bash
sudo journalctl -u mosquitto -n 50 --no-pager
```

Most startup failures are caused by a configuration syntax error. Test the config directly:

```bash
sudo mosquitto -c /etc/mosquitto/mosquitto.conf --test-config
```

If port 1883 is already bound by another process:

```bash
ss -tlnp | grep 1883
```

Identify and stop the conflicting process before restarting Mosquitto:

```bash
sudo systemctl restart mosquitto
```

### Mosquitto_sub Receives No Messages

Verify the broker is listening and the topic filter matches:

```bash
# Check broker is running
sudo systemctl is-active mosquitto

# Confirm port is open
ss -tlnp | grep 1883

# Try with wildcard topic
mosquitto_sub -h localhost -p 1883 -t '#' -v
```

If `mosquitto_sub` connects but hangs with no output, the broker is healthy, the
publisher may be using a different topic or host. Add `-d` to both commands for verbose
debug output.
 -->
### swap Returns After Reboot

The swap unit was not masked. Apply the mask and re-verify:

```bash
sudo systemctl mask swap.target
sudo swapoff -a
sudo grep -v swap /etc/fstab | sudo tee /etc/fstab
reboot
```

---

*Guide scope: ContinuumX v1.23 EdgeCore baseline · Debian 13 (Trixie) · containerd ·
Mosquitto MQTT (port 1883) · VirtualBox (Host-Only only at runtime) · Static IP
192.168.56.11*

*ContinuumX v1.23.0 released 2026-04-24 · EdgeCore requires containerd with
SystemdCgroup enabled*
