# Cloud image: Kubernetes control plane + ContinuumX CloudCore.
#
# You may change:
# - K8S_VERSION (keep in sync with kubeadm-config.yaml.tmpl)
# - ContinuumX / cxadm download URL and version
# - image list in the skopeo seed loop (must match what bootstrap needs)
# - SSH password for user (default user123)

FROM debian:13

ENV DEBIAN_FRONTEND=noninteractive \
    container=docker \
    KUBECONFIG=/root/.kube/config \
    K8S_VERSION=1.32.13-1.1

RUN apt-get update && apt-get install -y --no-install-recommends \
      systemd systemd-sysv dbus ca-certificates curl gnupg nano jq \
      iproute2 iptables conntrack socat ethtool kmod openssl sudo procps crun \
      openssh-server \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

RUN install -m 0755 -d /etc/apt/keyrings \
    && curl -fsSL https://download.docker.com/linux/debian/gpg \
      | gpg --batch --dearmor -o /etc/apt/keyrings/docker.gpg \
    && chmod a+r /etc/apt/keyrings/docker.gpg \
    && . /etc/os-release \
    && printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian %s stable\n' \
         "$(dpkg --print-architecture)" "$VERSION_CODENAME" \
         > /etc/apt/sources.list.d/docker.list \
    && apt-get update && apt-get install -y --no-install-recommends containerd.io \
    && apt-get clean && rm -rf /var/lib/apt/lists/* \
    && mkdir -p /etc/containerd \
    && containerd config default > /etc/containerd/config.toml \
    && sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml \
    && sed -i "s|BinaryName = ''|BinaryName = '/usr/local/bin/crun-wrap'|" /etc/containerd/config.toml

RUN ok=0; attempt=1; \
    while [ "$attempt" -le 5 ]; do \
      rm -f /etc/apt/keyrings/kubernetes-apt-keyring.gpg; \
      if curl -fsSL --retry 5 --retry-delay 2 --retry-all-errors \
           https://pkgs.k8s.io/core:/stable:/v1.32/deb/Release.key \
           | gpg --batch --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg; then \
        ok=1; \
        break; \
      fi; \
      echo "kubernetes apt key attempt ${attempt} failed"; \
      sleep $((attempt * 2)); \
      attempt=$((attempt + 1)); \
    done; \
    test "$ok" = 1 \
    && echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.32/deb/ /' \
         > /etc/apt/sources.list.d/kubernetes.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
         "kubelet=${K8S_VERSION}" "kubeadm=${K8S_VERSION}" "kubectl=${K8S_VERSION}" \
    && apt-mark hold kubelet kubeadm kubectl \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

RUN curl -fsSL https://github.com/neotera-eu/continuumx/releases/download/v1.23.0-cx/cxadm-v1.23.0-linux-amd64.tar.gz \
      -o /tmp/cxadm.tgz \
    && mkdir -p /tmp/cxadm \
    && tar -xzf /tmp/cxadm.tgz -C /tmp/cxadm \
    && find /tmp/cxadm -type f -name 'cxadm*' -exec mv {} /usr/local/bin/cxadm \; \
    && chmod 755 /usr/local/bin/cxadm \
    && rm -rf /tmp/cxadm.tgz /tmp/cxadm

RUN mkdir -p /opt/cx \
    && curl -fsSL -o /opt/cx/kube-flannel.yml \
         https://github.com/flannel-io/flannel/releases/download/v0.28.10/kube-flannel.yml \
    && sed -i 's/"EnableNFTables": false/"EnableNFTables": true/' /opt/cx/kube-flannel.yml

# Pre-download images into the image (faster cold start). Imported into the
# containerd volume on first boot by cx-import-images.sh.
RUN apt-get update && apt-get install -y --no-install-recommends skopeo \
    && mkdir -p /opt/cx/images \
    && i=0 \
    && for ref in \
         registry.k8s.io/pause:3.10 \
         registry.k8s.io/pause:3.10.2 \
         registry.k8s.io/kube-apiserver:v1.32.13 \
         registry.k8s.io/kube-controller-manager:v1.32.13 \
         registry.k8s.io/kube-scheduler:v1.32.13 \
         registry.k8s.io/kube-proxy:v1.32.13 \
         registry.k8s.io/etcd:3.5.24-0 \
         registry.k8s.io/coredns/coredns:v1.11.3 \
         ghcr.io/flannel-io/flannel:v0.28.10 \
         ghcr.io/flannel-io/flannel-cni-plugin:v1.9.1-flannel3 \
         docker.io/neotera/cloudcore:v1.23.0 \
         docker.io/neotera/iptables-manager:v1.23.0 \
       ; do \
         i=$((i+1)); \
         dest=$(printf '/opt/cx/images/%02d.tar' "$i"); \
         echo "seed ${ref}"; \
         ok=0; \
         attempt=1; \
         while [ "$attempt" -le 5 ]; do \
           rm -f "$dest"; \
           if skopeo copy "docker://${ref}" "docker-archive:${dest}:${ref}"; then \
             ok=1; \
             break; \
           fi; \
           echo "seed ${ref} failed (attempt ${attempt})"; \
           sleep $((attempt * 3)); \
           attempt=$((attempt + 1)); \
         done; \
         test "$ok" = 1; \
       done \
    && apt-get purge -y skopeo && apt-get autoremove -y \
    && apt-get clean && rm -rf /var/lib/apt/lists/* \
    && du -sh /opt/cx/images

# Do not ask systemd to load kernel modules inside the container.
# Rootless Podman/Docker cannot modprobe the host kernel (EPERM);
# host-prep.sh loads overlay + br_netfilter on the real host instead.
RUN mkdir -p /etc/sysctl.d \
    && printf '%s\n' \
         'net.bridge.bridge-nf-call-iptables = 1' \
         'net.bridge.bridge-nf-call-ip6tables = 1' \
         'net.ipv4.ip_forward = 1' \
         > /etc/sysctl.d/k8s.conf \
    && printf '%s\n' 'KUBELET_EXTRA_ARGS=--feature-gates=KubeletInUserNamespace=true' > /etc/default/kubelet

RUN useradd -m -s /bin/bash -G sudo user \
    && echo 'user:user123' | chpasswd \
    && printf 'user ALL=(ALL) NOPASSWD:ALL\n' > /etc/sudoers.d/user \
    && chmod 440 /etc/sudoers.d/user

COPY docker/cloud/crun-wrap /usr/local/bin/crun-wrap
COPY docker/cloud/kubeadm-config.yaml.tmpl /opt/cx/kubeadm-config.yaml.tmpl
COPY manifests/samples/devices/ /opt/cx/devices/
COPY docker/cloud/cx-bootstrap*.sh docker/cloud/cx-import-images.sh /usr/local/sbin/
COPY docker/cloud/cx-bootstrap.service /etc/systemd/system/cx-bootstrap.service
RUN chmod 755 /usr/local/sbin/cx-bootstrap*.sh /usr/local/sbin/cx-import-images.sh /usr/local/bin/crun-wrap \
    && mkdir -p /etc/systemd/system/multi-user.target.wants \
    && ln -sf /usr/lib/systemd/system/containerd.service /etc/systemd/system/multi-user.target.wants/containerd.service \
    && ln -sf /usr/lib/systemd/system/kubelet.service /etc/systemd/system/multi-user.target.wants/kubelet.service \
    && ln -sf /etc/systemd/system/cx-bootstrap.service /etc/systemd/system/multi-user.target.wants/cx-bootstrap.service \
    && ln -sf /usr/lib/systemd/system/ssh.service /etc/systemd/system/multi-user.target.wants/ssh.service \
    && mkdir -p /etc/systemd/system/sockets.target.wants \
    && ln -sf /usr/lib/systemd/system/dbus.socket /etc/systemd/system/sockets.target.wants/dbus.socket \
    && printf '%s\n' 'PasswordAuthentication yes' > /etc/ssh/sshd_config.d/password.conf \
    && ssh-keygen -A \
    && for unit in systemd-udevd.service systemd-udevd-kernel.socket systemd-udevd-control.socket \
         systemd-networkd.service systemd-resolved.service console-getty.service \
         systemd-modules-load.service; do \
         ln -sf /dev/null "/etc/systemd/system/${unit}"; \
       done \
    && rm -f /etc/machine-id /var/lib/dbus/machine-id

STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]
