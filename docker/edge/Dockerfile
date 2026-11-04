# Edge image: ContinuumX EdgeCore + containerd.
#
# You may change:
# - ContinuumX / cxadm download URL and version
# - image list in the skopeo seed loop
# - SSH password for user (default user123)
# - CNI subnet in containerd-net.conflist

FROM debian:13

ENV DEBIAN_FRONTEND=noninteractive \
    container=docker

RUN apt-get update && apt-get install -y --no-install-recommends \
      systemd systemd-sysv dbus ca-certificates curl gnupg nano \
      iproute2 iptables conntrack socat ethtool kmod sudo procps crun \
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

RUN curl -fsSL -o /tmp/cni.tgz \
      https://github.com/containernetworking/plugins/releases/download/v1.7.1/cni-plugins-linux-amd64-v1.7.1.tgz \
    && mkdir -p /opt/cni/bin \
    && tar -C /opt/cni/bin -xzf /tmp/cni.tgz \
    && rm /tmp/cni.tgz

COPY containerd-net.conflist /etc/cni/net.d/10-containerd-net.conflist

RUN curl -fsSL https://github.com/neotera-eu/continuumx/releases/download/v1.23.0-cx/cxadm-v1.23.0-linux-amd64.tar.gz \
      -o /tmp/cxadm.tgz \
    && mkdir -p /tmp/cxadm \
    && tar -xzf /tmp/cxadm.tgz -C /tmp/cxadm \
    && find /tmp/cxadm -type f -name 'cxadm*' -exec mv {} /usr/local/bin/cxadm \; \
    && chmod 755 /usr/local/bin/cxadm \
    && rm -rf /tmp/cxadm.tgz /tmp/cxadm

# Pre-download images into the image (faster cold start).
RUN apt-get update && apt-get install -y --no-install-recommends skopeo \
    && mkdir -p /opt/cx/images \
    && i=0 \
    && for ref in \
         registry.k8s.io/pause:3.10.2 \
         docker.io/neotera/installation-package:v1.23.0 \
         docker.io/library/eclipse-mosquitto:1.6.15 \
       ; do \
         i=$((i+1)); \
         printf 'seed %s\n' "$ref"; \
         skopeo copy "docker://${ref}" \
           "docker-archive:/opt/cx/images/$(printf '%02d' "$i").tar:${ref}"; \
       done \
    && apt-get purge -y skopeo && apt-get autoremove -y \
    && apt-get clean && rm -rf /var/lib/apt/lists/* \
    && du -sh /opt/cx/images

RUN mkdir -p /etc/modules-load.d /etc/sysctl.d \
    && printf '%s\n' overlay br_netfilter > /etc/modules-load.d/containerd.conf \
    && printf '%s\n' \
         'net.bridge.bridge-nf-call-iptables = 1' \
         'net.bridge.bridge-nf-call-ip6tables = 1' \
         'net.ipv4.ip_forward = 1' \
         > /etc/sysctl.d/99-containerd.conf

RUN useradd -m -s /bin/bash -G sudo user \
    && echo 'user:user123' | chpasswd \
    && printf 'user ALL=(ALL) NOPASSWD:ALL\n' > /etc/sudoers.d/user \
    && chmod 440 /etc/sudoers.d/user

COPY crun-wrap /usr/local/bin/crun-wrap
COPY cx-bootstrap*.sh cx-import-images.sh /usr/local/sbin/
COPY cx-bootstrap.service /etc/systemd/system/cx-bootstrap.service
RUN chmod 755 /usr/local/sbin/cx-bootstrap*.sh /usr/local/sbin/cx-import-images.sh /usr/local/bin/crun-wrap \
    && mkdir -p /etc/systemd/system/multi-user.target.wants \
    && ln -sf /usr/lib/systemd/system/containerd.service /etc/systemd/system/multi-user.target.wants/containerd.service \
    && ln -sf /etc/systemd/system/cx-bootstrap.service /etc/systemd/system/multi-user.target.wants/cx-bootstrap.service \
    && ln -sf /usr/lib/systemd/system/ssh.service /etc/systemd/system/multi-user.target.wants/ssh.service \
    && mkdir -p /etc/systemd/system/sockets.target.wants \
    && ln -sf /usr/lib/systemd/system/dbus.socket /etc/systemd/system/sockets.target.wants/dbus.socket \
    && printf '%s\n' 'PasswordAuthentication yes' > /etc/ssh/sshd_config.d/password.conf \
    && ssh-keygen -A \
    && for unit in systemd-udevd.service systemd-udevd-kernel.socket systemd-udevd-control.socket \
         systemd-networkd.service systemd-resolved.service console-getty.service; do \
         ln -sf /dev/null "/etc/systemd/system/${unit}"; \
       done \
    && rm -f /etc/machine-id /var/lib/dbus/machine-id

STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]
