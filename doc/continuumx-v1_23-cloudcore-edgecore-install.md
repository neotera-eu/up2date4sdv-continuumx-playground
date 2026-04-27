# ContinuumX v1.23, CloudCore & EdgeCore Installation Guide

> **Scope:** This guide covers the complete installation of ContinuumX CloudCore on the
> Kubernetes control plane and EdgeCore on edge worker nodes, including Cilium CNI
> integration on both sides. Although the reference setup uses VirtualBox VMs, all
> instructions apply equally to physical host PCs. Wherever the guide refers to the
> "CloudCore host" or "K8S control plane", substitute your actual control plane machine
>, whether it is a VM or a physical PC. The same applies to "EdgeCore host" or
> "edge worker node".
>
> **Assumed starting point:**
> - Kubernetes v1.32 is fully operational on the control plane host.
>
> **Tooling:** `cxadm` is the ContinuumX equivalent of upstream `keadm`. On the
> control plane it deploys CloudCore as a Helm-managed pod in the `kubeedge` namespace.
> On edge worker nodes it installs EdgeCore as a systemd service.
>
> **Images:** `neotera/cloudcore:v1.23.0` · `neotera/edgecore:v1.23.0`

---

## Reference Setup

The reference environment used to produce and verify this guide:

| Role | Host | OS | Network |
|---|---|---|---|
| K8S Control Plane / CloudCore | `u2deb-cloud` | Debian 13 (Trixie) | Host-Only `enp0s8 / 192.168.56.10` · Bridged LAN `enp0s9 / 192.168.1.x` (DHCP) |
| Edge Worker Node | Any LAN host | Debian 12/13 | Bridged LAN, same subnet as control plane |

CloudCore is reachable from edge worker nodes on three hostnames:

| Hostname | Network | CloudHub Port | Notes |
|---|---|---|---|
| `u2deb-cloud` | Host-Only | 10000 | Static IP SAN in cert |
| `u2deb-cloud.local` | LAN | 10000 | DNS SAN in cert |
| `u2deb-cloud.lan` | LAN | 10000 | DNS SAN in cert |

> **LAN hostname resolution:** Edge worker nodes resolve `u2deb-cloud.local` and
> `u2deb-cloud.lan` via `/etc/hosts`, mDNS is not used. See Part II, Section 4.

> **How external access works:** `cxadm init` deploys CloudCore with `hostNetwork: true`
> and a `ClusterIP` service. The pod binds directly to all control plane host interfaces,
> making ports 10000–10004 reachable on all physical IPs without NodePort or a load
> balancer.

> **The Bridged adapter's DHCP IP (`192.168.1.x`) is intentionally omitted from the
> certificate IP SANs.** LAN access is covered by the `DNS:u2deb-cloud.local` and
> `DNS:u2deb-cloud.lan` SANs, TLS validates against the hostname, not the IP.

---

## Table of Contents

**Part I, CloudCore (K8S Control Plane)**

1. [Control Plane Prerequisites](#i1-control-plane-prerequisites)
2. [Install cxadm](#i2-install-cxadm)
3. [Understanding the Flags and Chart Values](#i3-understanding-the-flags-and-chart-values)
4. [Initialize CloudCore](#i4-initialize-cloudcore)
5. [Verify CloudCore Deployment](#i5-verify-cloudcore-deployment)
6. [Retrieve the Edge Join Token](#i6-retrieve-the-edge-join-token)
7. [Verify CloudCore Certificate SANs](#i7-verify-cloudcore-certificate-sans)
8. [Extract the CloudCore CA Certificate](#i8-extract-the-cloudcore-ca-certificate)
9. [CloudCore Readiness Checklist](#i9-cloudcore-readiness-checklist)

**Part II, EdgeCore (Edge Worker Nodes)**

1. [Edge Worker Node Prerequisites](#ii1-edge-worker-node-prerequisites)
2. [Configure /etc/hosts on the Edge Worker Node](#ii2-configure-etchosts-on-the-edge-worker-node)
3. [Install cxadm on the Edge Worker Node](#ii3-install-cxadm-on-the-edge-worker-node)
4. [Deploy EdgeCore (cxadm join)](#ii4-deploy-edgecore-cxadm-join)
5. [Verify Edge Node Registration](#ii5-verify-edge-node-registration)
6. [EdgeCore Readiness Checklist](#ii6-edgecore-readiness-checklist)

**Appendices**

- [Appendix A, Troubleshooting](#appendix-a--troubleshooting)
- [Appendix B, Uninstalling](#appendix-b--uninstalling)

---

---

# Part I, CloudCore (K8S Control Plane)

> All commands in Part I are run on the **K8S control plane host** (`u2deb-cloud`)
> unless explicitly stated otherwise.

---

## I.1 Control Plane Prerequisites

Confirm every item before proceeding.

- [ ] `kubectl get nodes` -> `u2deb-cloud   Ready   control-plane`
- [ ] All `kube-system` pods are `Running` or `Completed`
- [ ] Control plane taint removed:
  ```bash
  kubectl describe node u2deb-cloud | grep Taints
  # Expected: Taints: <none>
  ```
- [ ] kube-proxy DaemonSet has the edge node affinity exclusion applied
- [ ] `/etc/kubernetes/pki/ca.crt` and `ca.key` both present
- [ ] `/root/.kube/config` exists and `sudo kubectl get nodes` succeeds
- [ ] Cilium is installed and `cilium status` reports all components OK
- [ ] No firewall (`ufw` is not installed on this host). If a firewall is present,
  allow TCP 10000 and 10002 inbound.

> **Cilium prerequisite, KubeEdge v1.16+:** Cilium integration with KubeEdge requires
> KubeEdge v1.16 or later (ContinuumX v1.23.0 satisfies this). The `cilium-agent` on
> edge nodes issues `InClusterConfig` API calls that are routed through the KubeEdge
> MetaManager, this capability was introduced in v1.16.

---

## I.2 Install cxadm

### I.2.1 Download the cxadm Binary

```bash
wget https://github.com/neotera-eu/continuumx/releases/download/v1.23.0-cx/cxadm-v1.23.0-linux-amd64.tar.gz \
  -O /tmp/cxadm-v1.23.0-linux-amd64.tar.gz
```

> **Note:** ContinuumX `cxadm` is the rebranded upstream `keadm` binary. The archive
> contains the binary which is installed as `cxadm`.
### I.2.2 Extract and Install

```bash
tar -xzvf /tmp/cxadm-v1.23.0-linux-amd64.tar.gz -C /tmp/

sudo mv /tmp/cxadm /usr/local/bin/cxadm
sudo chmod +x /usr/local/bin/cxadm
```

### I.2.3 Verify

```bash
cxadm version
# Expected: version.Info{...Version:"v1.23.0"...}
```

---

## I.3 Understanding the Flags and Chart Values

`cxadm init` is a thin wrapper around a Helm chart installation of CloudCore.
Understanding how CLI flags map to chart values prevents misconfiguration.

### CLI Flags

| Flag | Effect |
|---|---|
| `--advertise-address` | **IP addresses only.** Added as IP SANs to the CloudCore TLS certificate and set as `cloudHub.advertiseAddress`. This is the primary address edge nodes use to reach CloudCore. |
| `--kubeedge-version` | Pins the image tag globally across all chart components. |
| `--image-repository` | Overrides the image repository. Combined with `--kubeedge-version`, CloudCore pulls `<repo>/cloudcore:<version>`. |
| `--set` | Raw Helm `--set` overrides for anything not covered by a dedicated flag, including DNS SANs. |
| `--force` | **Required with ContinuumX images.** Bypasses the post-install readiness wait. Without it, `cxadm init` times out waiting for a readiness probe the custom image may not satisfy. |
| `--kube-config` | Path to the kubeconfig used to authenticate against the API server. |

### Key Chart Values

```yaml
cloudCore:
  image:
    repository: "kubeedge/cloudcore"    # overridden by --image-repository
    tag: "v1.23.0"                      # overridden by --kubeedge-version / --set
  hostNetWork: true                      # binds CloudCore to all host interfaces
                                         # makes ports 10000-10004 directly reachable
  modules:
    cloudHub:
      advertiseAddress: []               # set by --advertise-address (IP SANs)
      dnsNames: []                       # set by --set (DNS SANs)
      websocket:
        port: 10000                      # CloudHub WebSocket (direct, no NodePort)
      https:
        port: 10002                      # Certificate bootstrap (direct, no NodePort)
    dynamicController:
      enable: false                      # enabled by configure_cilium.sh (Cilium step)
service:
  type: "ClusterIP"                      # v1.23.0 actual deployed type
                                         # external access via hostNetwork, not NodePort
```

> **Service type:** Despite upstream documentation suggesting `NodePort`, `cxadm init
> v1.23.0` deploys a `ClusterIP` service. External reachability is provided entirely by
> `hostNetwork: true`. Do not patch the service to `NodePort`, it will conflict with
> the `cloud-iptables-manager` DNAT rules.

### How `--advertise-address` and `dnsNames` Work Together

- `--advertise-address` -> **IP SANs** + `advertiseAddress` in CloudCore config.
  Use for the static Host-Only IP (`192.168.56.10`).
- `dnsNames` (via `--set`) -> **DNS SANs** in the CloudCore certificate.
  Use for all hostnames. The Bridged adapter's DHCP IP is omitted, DNS SANs cover LAN
  access regardless of what DHCP assigns.

---

## I.4 Initialize CloudCore

### I.4.1 The cxadm init Command

```bash
sudo cxadm init \
  --advertise-address="192.168.56.10" \
  --kubeedge-version=v1.23.0 \
  --image-repository=neotera \
  --kube-config=/root/.kube/config \
  --set cloudCore.image.tag=v1.23.0 \
  --set cloudCore.modules.cloudHub.dnsNames[0]="u2deb-cloud" \
  --set cloudCore.modules.cloudHub.dnsNames[1]="u2deb-cloud.local" \
  --set cloudCore.modules.cloudHub.dnsNames[2]="u2deb-cloud.lan" \
  --force
```

**Flag-by-flag explanation:**

| Flag / `--set` key | Value | Reason |
|---|---|---|
| `--advertise-address` | `192.168.56.10` | Static Host-Only IP. Added as IP SAN and used as the primary CloudHub address. |
| `--kubeedge-version` | `v1.23.0` | Pins the image tag globally. |
| `--image-repository` | `neotera` | ContinuumX registry. Pulls `neotera/cloudcore:v1.23.0`. |
| `--set cloudCore.image.tag` | `v1.23.0` | Explicit tag override, ensures the correct image tag is applied. |
| `dnsNames[0]` | `u2deb-cloud` | Bare hostname DNS SAN. |
| `dnsNames[1]` | `u2deb-cloud.local` | `.local` hostname DNS SAN for LAN access. |
| `dnsNames[2]` | `u2deb-cloud.lan` | `.lan` hostname DNS SAN for LAN access. |
| `--force` | - | **Required.** Skips post-install readiness wait. |

### I.4.2 Expected Output

```
Kubernetes version verification passed, ContinuumX installation will start...
CLOUDCORE started
=========CHART DETAILS=======
Name: cloudcore
LAST DEPLOYED: ...
NAMESPACE: kubeedge
STATUS: deployed
REVISION: 1
```

---

## I.5 Verify CloudCore Deployment

### I.5.1 Check All CloudCore Resources

```bash
kubectl get all -n continuumx
```

Expected:

```
NAME                                   READY   STATUS    RESTARTS   AGE
pod/cloud-iptables-manager-<hash>      1/1     Running   0          Xm
pod/cloudcore-<hash>                   1/1     Running   0          Xm

NAME                TYPE        CLUSTER-IP   EXTERNAL-IP   PORT(S)                                             AGE
service/cloudcore   ClusterIP   10.x.x.x     <none>        10000/TCP,10001/UDP,10002/TCP,10003/TCP,10004/TCP   Xm

NAME                                    DESIRED   CURRENT   READY   AGE
daemonset.apps/cloud-iptables-manager   1         1         1       Xm

NAME                        READY   UP-TO-DATE   AVAILABLE   AGE
deployment.apps/cloudcore   1/1     1            1           Xm
```

All pods must be `1/1 Running` before proceeding.

### I.5.2 Confirm Image, hostNetwork, and Labels

```bash
# Confirm ContinuumX image
kubectl get pod -n continuumx -l kubeedge=cloudcore \
  -o jsonpath='{.items[0].spec.containers[0].image}'
# Expected: neotera/cloudcore:v1.23.0

# Confirm hostNetwork is true
kubectl get pod -n continuumx -l kubeedge=cloudcore \
  -o jsonpath='{.items[0].spec.hostNetwork}'
# Expected: true
```

> **Pod label:** The CloudCore pod label is `kubeedge=cloudcore`, not `app=cloudcore`.
> Using the wrong label returns no results.

### I.5.3 Check CloudCore Logs

```bash
kubectl logs -n continuumx -l kubeedge=cloudcore --tail=50
```

Expected startup lines:

```
I... starting module cloudhub
I... Succeed in loading TunnelCA from CloudHub
I... Succeed in loading TunnelCert and Key from CloudHub
I... Prepare to start tunnel server ...
I... start unix domain socket server
I... Starting cloudhub websocket server
```

No `ERROR` or `FATAL` lines should appear at startup.

### I.5.4 Confirm Ports Are Listening on All Interfaces

```bash
ss -tlnp | grep -E '10000|10001|10002|10003|10004'
```

Expected, all ports show `*` (all interfaces):

```
LISTEN  0   4096   *:10004   *:*
LISTEN  0   4096   *:10000   *:*
LISTEN  0   4096   *:10003   *:*
LISTEN  0   4096   *:10002   *:*
```

---

## I.6 Retrieve the Edge Join Token

The token is required by every edge worker node that joins the cluster.

```bash
sudo cxadm gettoken --kube-config=/root/.kube/config
```

The output is a string of the form `<hex-ca-fingerprint>.<base64-jwt>`. Record it, it
will be passed to `cxadm join` on each edge worker node.

> **Token expiry:** Tokens expire after 24 hours by default. Always retrieve a fresh
> token immediately before running `cxadm join`. The CA fingerprint (the hex prefix)
> does not change between refreshes.

---

## I.7 Verify CloudCore Certificate SANs

The CloudCore TLS certificate is stored in the `cloudcoresecret` Kubernetes Secret
under the key `cloudcoredata`.

```bash
kubectl get secret cloudcoresecret -n continuumx \
  -o jsonpath='{.data.cloudcoredata}' | base64 -d | \
  openssl x509 -noout -ext subjectAltName -subject
```

Expected output:

```
X509v3 Subject Alternative Name:
    DNS:u2deb-cloud, DNS:u2deb-cloud.local, DNS:u2deb-cloud.lan, IP Address:192.168.56.10
subject=O=ContinuumX,, CN=ContinuumX,
```

> **ContinuumX secret naming:** The certificate is in `cloudcoresecret / cloudcoredata`,
> not `cloudcore / tls.crt` as in some upstream KubeEdge guides. If the command returns
> empty output:
> ```bash
> kubectl get secrets -n continuumx
> kubectl get secret cloudcoresecret -n continuumx \
>   -o jsonpath='{.data}' | python3 -m json.tool | grep -o '"[^"]*":'
> ```

> **The LAN DHCP IP is absent from IP SANs by design.** Edge worker nodes must connect
> using a hostname (`u2deb-cloud`, `u2deb-cloud.local`, or `u2deb-cloud.lan`), not the
> raw LAN IP. Connecting by raw IP will produce a TLS certificate error.

If any expected SAN is missing, reinstall CloudCore, SANs cannot be added in-place.
See Appendix A (Troubleshooting) for the clean reinstall procedure.

---

## I.8 Extract the CloudCore CA Certificate

Edge worker nodes need the CloudCore CA certificate to validate TLS during `cxadm join`
and subsequent connections. In ContinuumX v1.23.0 the CA cert is in `casecret` under
the key `cadata`, stored in **DER (binary) format**, it must be converted to PEM.

### I.8.1 Extract and Convert to PEM

```bash
# Extract DER cert and convert to PEM in one pipeline
kubectl get secret casecret -n kubeedge \
  -o jsonpath='{.data.cadata}' | base64 -d | \
  openssl x509 -inform DER -out /tmp/cloudcore-ca.crt

# Verify it is valid PEM
head -1 /tmp/cloudcore-ca.crt
# Expected: -----BEGIN CERTIFICATE-----

# Verify cert details
openssl x509 -noout -subject -issuer -dates -in /tmp/cloudcore-ca.crt
```

Expected cert details:

```
subject=CN=KubeEdge
issuer=CN=KubeEdge
notBefore=...
notAfter=...   (99-year validity)
```

> **ContinuumX secret naming:** `casecret` stores the CA cert as `cadata` and the CA
> key as `cakeydata`. The upstream KubeEdge names (`rootCA.crt`, `rootCA.key`) are not
> used. Do not attempt `base64 -d > file` directly, the DER output is unusable by
> `curl`, `openssl -CAfile`, or `cxadm join`. Always convert with `-inform DER`.

### I.8.2 Distribute to Edge Worker Nodes

```bash
# Repeat for each edge worker node
scp /tmp/cloudcore-ca.crt user@<edge-node-ip>:/tmp/cloudcore-ca.crt
```

Verify on the edge worker node:

```bash
# On the edge worker node
head -1 /tmp/cloudcore-ca.crt
# Expected: -----BEGIN CERTIFICATE-----
```

---

## I.9 CloudCore Readiness Checklist

Before configuring any edge worker nodes:

- [ ] `kubectl get all -n kubeedge`, CloudCore pod `1/1 Running`
- [ ] Service type is `ClusterIP` (correct for v1.23.0)
- [ ] Image confirmed as `neotera/cloudcore:v1.23.0`
- [ ] `hostNetwork: true` confirmed on the CloudCore pod
- [ ] CloudCore logs show no startup errors; CloudHub websocket server started
- [ ] Ports 10000–10004 listening on `*`: `ss -tlnp | grep 1000`
- [ ] Certificate SANs: `DNS:u2deb-cloud`, `DNS:u2deb-cloud.local`, `DNS:u2deb-cloud.lan`, `IP:192.168.56.10`
- [ ] CloudCore restarted after Cilium configuration
- [ ] CA cert extracted as PEM: `head -1 /tmp/cloudcore-ca.crt` -> `-----BEGIN CERTIFICATE-----`
- [ ] CA cert distributed to all edge worker nodes
- [ ] Join token retrieved and recorded

**Information to record for edge worker node configuration:**

```bash
echo "CloudHub WebSocket  : u2deb-cloud:10000 / u2deb-cloud.local:10000 / u2deb-cloud.lan:10000"
echo "Cert bootstrap port : u2deb-cloud:10002 / u2deb-cloud.local:10002 / u2deb-cloud.lan:10002"
echo "CloudCore CA cert   : /tmp/cloudcore-ca.crt (copy to each edge worker node)"
echo "Join token          : $(sudo cxadm gettoken --kube-config=/root/.kube/config)"
```

---

---

# Part II, EdgeCore (Edge Worker Nodes)

> All commands in Part II are run on the **edge worker node** unless explicitly stated
> otherwise. Repeat every section for each edge worker node that joins the cluster.

---

## II.1 Edge Worker Node Prerequisites

### II.1.1 Operating System

Debian 12 or 13 (amd64) is recommended. Other systemd-based Linux distributions are
supported by upstream KubeEdge v1.23.


### II.1.2 Prerequisites Checklist, Edge Worker Node

- [ ] Debian 12/13 amd64, systemd init
- [ ] `systemctl is-active containerd` -> `active`
- [ ] `grep SystemdCgroup /etc/containerd/config.toml` -> `SystemdCgroup = true`
- [ ] `sysctl net.ipv4.ip_forward` -> `1`
- [ ] `free -h | grep Swap` -> all zeros
- [ ] CA cert present at `/tmp/cloudcore-ca.crt` (copied from control plane)

---

## II.2 Configure /etc/hosts on the Edge Worker Node

Edge worker nodes resolve `u2deb-cloud.local` and `u2deb-cloud.lan` via a static
`/etc/hosts` entry. This is required when the VirtualBox host bridges over WiFi (WiFi
APs filter multicast frames from the VM's virtual MAC, preventing mDNS propagation).
On wired Ethernet hosts this step is optional but recommended for consistency.

### II.2.1 Find the Control Plane's Current LAN IP

Run on the **K8S control plane host**:

```bash
# get the host-only adapter static IP; should be 192.168.56.10
ip addr show enp0s8 | grep 'inet ' | awk '{print $2}' | cut -d/ -f1
# get the dridged adapter dynamic IP
ip addr show enp0s9 | grep 'inet ' | awk '{print $2}' | cut -d/ -f1
```

### II.2.2 Add the /etc/hosts Entry

Run on the **edge worker node**:

```bash
# replace `192.168.1.27` with the actual IP from II.2.1
echo "192.168.1.27  u2deb-cloud.lan" | sudo tee -a /etc/hosts
# replace `192.168.56.10` with the actual IP from II.2.1
echo "192.168.56.10  u2deb-cloud.local" | sudo tee -a /etc/hosts
# Verify
grep u2deb-cloud /etc/hosts
```

Expected:

```
192.168.1.27  u2deb-cloud.lan
192.168.56.10  u2deb-cloud.local
```

### II.2.3 Verify Resolution and Connectivity

```bash
getent hosts u2deb-cloud.local   # Expected: 192.168.56.10
getent hosts u2deb-cloud.lan     # Expected: 192.168.1.27

# Port reachability
nc -zv u2deb-cloud.local 10000
nc -zv u2deb-cloud.local 10002
```

### II.2.4 Full TLS Validation

Confirm TLS validates against the CloudCore CA before joining:

```bash
# Requires CA cert at /tmp/cloudcore-ca.crt (Section I.9)

openssl s_client -connect u2deb-cloud:10002 \
  -CAfile /tmp/cloudcore-ca.crt \
  -verify_hostname u2deb-cloud -brief 2>&1 | grep -E 'Verification|error'

openssl s_client -connect u2deb-cloud.local:10002 \
  -CAfile /tmp/cloudcore-ca.crt \
  -verify_hostname u2deb-cloud.local -brief 2>&1 | grep -E 'Verification|error'

openssl s_client -connect u2deb-cloud.lan:10002 \
  -CAfile /tmp/cloudcore-ca.crt \
  -verify_hostname u2deb-cloud.lan -brief 2>&1 | grep -E 'Verification|error'
```

All three must return `Verification: OK` before proceeding.

> **IP changes:** The Bridged adapter IP is DHCP-assigned and may change between
> reboots. If `u2deb-cloud.local` stops resolving, re-run Section II.2.1 on the
> control plane host and update `/etc/hosts` on each edge worker node accordingly.

---

## II.3 Install cxadm on the Edge Worker Node

```bash
wget https://github.com/neotera-eu/continuumx/releases/download/v1.23.0-cx/cxadm-v1.23.0-linux-amd64.tar.gz \
  -O /tmp/cxadm-v1.23.0-linux-amd64.tar.gz

tar -xzvf /tmp/cxadm-v1.23.0-linux-amd64.tar.gz -C /tmp/

sudo mv /tmp/cxadm /usr/local/bin/cxadm
sudo chmod +x /usr/local/bin/cxadm

# Verify
cxadm version
# Expected: version.Info{...Version:"v1.23.0"...}
```

---

## II.4 Deploy EdgeCore (cxadm join)

`cxadm join` pulls the EdgeCore image, installs EdgeCore as a systemd service, and
registers the edge worker node with CloudCore.

### II.4.1 Retrieve a Fresh Token

Tokens expire after 24 hours. Always get a fresh token immediately before joining:

```bash
# On the K8S control plane host
sudo cxadm gettoken --kube-config=/root/.kube/config
```

### II.4.2 The cxadm join Command

```bash
# On the edge worker node
sudo cxadm join \
  --cloudcore-ipport=u2deb-cloud.local:10000 \
  --token=<paste-token-here> \
  --kubeedge-version=v1.23.0 \
  --image-repository=neotera \
  --cgroupdriver=systemd \
  --remote-runtime-endpoint=unix:///run/containerd/containerd.sock
```

**Flag-by-flag explanation:**

| Flag / `--set` key | Value | Reason |
|---|---|---|
| `--cloudcore-ipport` | `u2deb-cloud.local:10000` | CloudHub WebSocket address. Must be one of the DNS or IP SANs in the CloudCore certificate. Use `u2deb-cloud.local` or `u2deb-cloud.lan` for LAN edge nodes; use `192.168.56.10:10000` for nodes on the Host-Only network. **Do not use the raw DHCP IP.** |
| `--token` | `<token>` | Join token from `cxadm gettoken`. Contains the CA fingerprint for bootstrapping mutual TLS. |
| `--kubeedge-version` | `v1.23.0` | Pins the EdgeCore image version. Must match CloudCore. |
| `--image-repository` | `neotera` | ContinuumX registry. Pulls `neotera/edgecore:v1.23.0`. |
| `--cgroupdriver` | `systemd` | Must match the containerd cgroup driver set in Section II.1.2. |

### II.4.3 What cxadm join Does

1. Pulls `neotera/edgecore:v1.23.0` via containerd
2. Connects to CloudCore on port 10000 (WebSocket/TLS), authenticating with the token
3. CloudCore signs an edge certificate using the CloudCore CA
4. EdgeCore stores the signed cert in `/etc/kubeedge/certs/`
5. Installs and starts `edgecore.service` (systemd)
6. Registers the edge node in the Kubernetes API

### II.4.4 Expected Output

```
I... ContinuumX edgecore is running, For logs visit: journalctl -u edgecore.service -xe
I... Install Complete!
```

---

## II.5 Verify Edge Node Registration

### II.5.1 EdgeCore Service Status

```bash
# On the edge worker node
systemctl is-active edgecore
# Expected: active

journalctl -u edgecore -n 30 --no-pager | grep -E 'established|registered|Error|error'
```

Expected:

```
... connection established between edge and cloud
... Successful registration of edge node
```

### II.5.2 Node Appears on the Control Plane

```bash
# On the K8S control plane host
kubectl get nodes -o wide
```

Expected:

```
NAME              STATUS   ROLES                  AGE   VERSION
u2deb-cloud       Ready    control-plane,master   Xd    v1.32.x
<edge-node-name>  Ready    agent,edge             Xm    v1.23.0-kubeedge-...
```

> **Edge node name:** The node registers using the edge worker node's hostname.
> Confirm with `hostname` on the edge worker node before joining.

> **`NotReady` immediately after joining** is normal, allow 30–60 seconds for EdgeCore
> to establish the CloudHub tunnel and sync node status.

### II.5.3 Verify EdgeCore Certificate

```bash
# On the edge worker node
ls -lh /etc/kubeedge/certs/
# Expected: edge.crt, edge.key, server.crt, server.key

openssl x509 -noout -subject -issuer -dates \
  -in /etc/kubeedge/certs/edge.crt
# Expected: issuer=CN=KubeEdge (signed by CloudCore CA)
```

---

## II.6 EdgeCore Readiness Checklist

- [ ] `systemctl is-active edgecore` -> `active`
- [ ] EdgeCore logs show `connection established between edge and cloud`
- [ ] Edge node appears in `kubectl get nodes` with status `Ready`
- [ ] Node role shows `agent,edge`
- [ ] `edgecore.crt` present in `/etc/kubeedge/certs/`, signed by CloudCore CA

---

---

# Appendix A, Troubleshooting

---

## A.1 CloudCore Issues

### cxadm init Fails Immediately

Use `--dry-run` to inspect generated manifests without touching the cluster:

```bash
sudo cxadm init \
  --advertise-address="192.168.56.10" \
  --kubeedge-version=v1.23.0 \
  --image-repository=neotera \
  --kube-config=/root/.kube/config \
  --set cloudCore.image.tag=v1.23.0 \
  --set cloudCore.modules.cloudHub.dnsNames[0]="u2deb-cloud" \
  --set cloudCore.modules.cloudHub.dnsNames[1]="u2deb-cloud.local" \
  --set cloudCore.modules.cloudHub.dnsNames[2]="u2deb-cloud.lan" \
  --dry-run
```

### cxadm init Times Out

Ensure `--force` is present. Inspect the pod state independently:

```bash
kubectl get pod -n kubeedge
kubectl describe pod -n kubeedge -l kubeedge=cloudcore
kubectl logs -n kubeedge -l kubeedge=cloudcore
```

### CloudCore Pod in ImagePullBackOff

```bash
kubectl describe pod -n kubeedge -l kubeedge=cloudcore | grep -A 10 Events
sudo crictl pull neotera/cloudcore:v1.23.0
```

If registry authentication is required:

```bash
kubectl create secret docker-registry neotera-pull-secret \
  --docker-server=docker.io \
  --docker-username=<user> \
  --docker-password=<password> \
  -n kubeedge

kubectl patch deployment cloudcore -n kubeedge --type='json' \
  -p='[{"op":"add","path":"/spec/template/spec/imagePullSecrets","value":[{"name":"neotera-pull-secret"}]}]'
```

### kubectl logs Returns "No resources found"

The correct label selector is `kubeedge=cloudcore`, not `app=cloudcore`:

```bash
kubectl logs -n kubeedge -l kubeedge=cloudcore --tail=50
# or by pod name:
kubectl logs -n kubeedge cloudcore-<hash> --tail=50
```

### CloudCore Certificate Missing a SAN

SANs are embedded at install time and cannot be added in-place. Clean reinstall:

```bash
sudo cxadm reset --kube-config=/root/.kube/config
kubectl get namespace kubeedge 2>/dev/null && echo "NOT CLEAN, wait" || echo "Clean"

sudo cxadm init \
  --advertise-address="192.168.56.10" \
  --kubeedge-version=v1.23.0 \
  --image-repository=neotera \
  --kube-config=/root/.kube/config \
  --set cloudCore.image.tag=v1.23.0 \
  --set cloudCore.modules.cloudHub.dnsNames[0]="u2deb-cloud" \
  --set cloudCore.modules.cloudHub.dnsNames[1]="u2deb-cloud.local" \
  --set cloudCore.modules.cloudHub.dnsNames[2]="u2deb-cloud.lan" \
  --force
```

### CA Certificate Extraction Returns Binary Garbage

Always use `-inform DER` when converting from `casecret`:

```bash
kubectl get secret casecret -n kubeedge \
  -o jsonpath='{.data.cadata}' | base64 -d | \
  openssl x509 -inform DER -out /tmp/cloudcore-ca.crt

head -1 /tmp/cloudcore-ca.crt
# Must show: -----BEGIN CERTIFICATE-----
```

### TLS Validation Fails with "no certificate or crl found"

The CA cert on the edge worker node is empty or in DER format. Re-copy from the control
plane:

```bash
# On the control plane host, verify local copy first
head -1 /tmp/cloudcore-ca.crt    # must be -----BEGIN CERTIFICATE-----
ls -lh /tmp/cloudcore-ca.crt     # must be > 0 bytes

scp /tmp/cloudcore-ca.crt user@<edge-node-ip>:/tmp/cloudcore-ca.crt
```

### Port Not Reachable from Edge Worker Node

```bash
# On the control plane host
kubectl get pod -n kubeedge -l kubeedge=cloudcore \
  -o jsonpath='{.items[0].spec.hostNetwork}'
# Expected: true

ss -tlnp | grep -E '10000|10002'
# Expected: LISTEN  0  4096  *:10000  *:*
```

CloudCore listens on ports **10000** and **10002** directly. There are no NodePorts.

---

## A.2 EdgeCore Issues

### cxadm join Fails, TLS / Certificate Error

The hostname in `--cloudcore-ipport` must match a SAN in the CloudCore certificate.
Valid values: `u2deb-cloud:10000`, `u2deb-cloud.local:10000`, `u2deb-cloud.lan:10000`,
`192.168.56.10:10000`. Do not use the raw DHCP LAN IP.

Verify the SANs:

```bash
# On the control plane host
kubectl get secret cloudcoresecret -n kubeedge \
  -o jsonpath='{.data.cloudcoredata}' | base64 -d | \
  openssl x509 -noout -ext subjectAltName
```

### cxadm join Fails, Token Error

Tokens expire after 24 hours. Issue a fresh one and retry immediately:

```bash
# On the control plane host
sudo cxadm gettoken --kube-config=/root/.kube/config
```

Verify CloudCore is reachable before retrying:

```bash
# On the edge worker node
nc -zv u2deb-cloud.local 10000
```

### Edge Node Shows NotReady After Join

Wait 60 seconds. If it persists, check EdgeCore logs:

```bash
journalctl -u edgecore -n 50 --no-pager
```

Common causes: clock skew (`sudo systemctl restart systemd-timesyncd`), containerd not
running (`systemctl is-active containerd`), firewall blocking outbound port 10000.

### EdgeCore Service Fails to Start

```bash
systemctl status edgecore --no-pager -l
journalctl -u edgecore -n 50 --no-pager
```

Most common cause: misconfigured containerd. Verify:

```bash
systemctl is-active containerd
grep 'SystemdCgroup' /etc/containerd/config.toml
# Expected: SystemdCgroup = true
```

### Cilium configure_cilium.sh Fails Prerequisites Check

The script checks for `kubectl`, `jq`, and access to the `kubeedge` namespace (cloud
side) or `edgecore.service` (edge side). Verify:

```bash
# Cloud side
kubectl get namespace kubeedge
which jq || sudo apt install -y jq

# Edge side
systemctl is-active edgecore
```

### cilium-agent Not Scheduled on Edge Node

Verify the node labels and DaemonSet affinity. Edge nodes should NOT have the
`node-role.kubernetes.io/edge` label excluded by the Cilium DaemonSet patch:

```bash
# Check node labels
kubectl get node <edge-node-name> --show-labels | grep edge

# Check Cilium DaemonSet affinity
kubectl get daemonset cilium -n kube-system -o yaml | grep -A 20 affinity
```

If `cilium-agent` is excluded, re-run `configure_cilium.sh cloudcore` on the control
plane host and restart CloudCore.

---

---

# Appendix B, Uninstalling

---

## B.1 Uninstalling EdgeCore

Run on the **edge worker node**:

```bash
sudo cxadm reset
```

This stops `edgecore.service`, removes EdgeCore certificates from `/etc/kubeedge/`, and
removes the EdgeCore binary. It does not remove containerd or the `/etc/hosts` entry.

After reset, clean up on the control plane:

```bash
# On the control plane host
kubectl get nodes
# If the node still appears as NotReady/Unknown:
kubectl delete node <edge-node-name>
```

---

## B.2 Uninstalling CloudCore

Run on the **K8S control plane host**:

```bash
sudo cxadm reset --kube-config=/root/.kube/config
```

This removes the Helm release, the `kubeedge` namespace, all KubeEdge CRDs, and the
CloudCore certificates. It does not affect Kubernetes, Cilium, Flannel, or any other
workloads.

Verify cleanup:

```bash
kubectl get namespace kubeedge 2>/dev/null && echo "Still exists" || echo "Clean"
kubectl get crd | grep kubeedge
# Expected: no output
```

> **Reinstall after reset:** Re-run Section I.4 followed by Section I.6 (Cilium
> cloud-side configuration) before joining any edge worker nodes.

---

*Guide scope: ContinuumX v1.23.0 · `neotera/cloudcore:v1.23.0` · `neotera/edgecore:v1.23.0` ·
Reference control plane: `u2deb-cloud` Debian 13 (Trixie) · Kubernetes v1.32 · Cilium CNI ·
Host-Only (`enp0s8 / 192.168.56.10`) + Bridged LAN (`enp0s9`, /etc/hosts resolution) ·
DNS SANs: `u2deb-cloud`, `u2deb-cloud.local`, `u2deb-cloud.lan` ·
v8, CloudCore verified against live deployment · EdgeCore and Cilium integration based on
ContinuumX v1.23.0 / upstream KubeEdge v1.23 + KubeEdge Cilium documentation*
