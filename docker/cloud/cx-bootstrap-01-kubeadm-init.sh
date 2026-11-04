#!/bin/bash
# Init Kubernetes control plane (skipped if already done on the volume).

: "${CX_HOST_IP:=$(ip -4 -o addr show scope global | awk '{print $4}' | cut -d/ -f1 | head -1)}"
[[ -n "$CX_HOST_IP" ]]

sed "s/__ADVERTISE_IP__/${CX_HOST_IP}/g" /opt/cx/kubeadm-config.yaml.tmpl \
  > /run/cx-kubeadm-config.yaml

if [[ ! -f /var/lib/cx-playground/kubeadm-ok ]]; then
  if [[ -d /etc/kubernetes/pki || -f /etc/kubernetes/admin.conf ]]; then
    kubeadm reset -f || true
    rm -rf /etc/kubernetes /var/lib/etcd/* /var/lib/kubelet/*
    mkdir -p /etc/kubernetes
  fi
  kubeadm init --config /run/cx-kubeadm-config.yaml \
    --ignore-preflight-errors=Swap,SystemVerification,DirAvailable--var-lib-etcd
  touch /var/lib/cx-playground/kubeadm-ok
fi

if [[ -f /etc/kubernetes/admin.conf && ! -f /var/lib/cx-playground/kubeadm-ok ]]; then
  touch /var/lib/cx-playground/kubeadm-ok
fi

cp /etc/kubernetes/admin.conf /root/.kube/config
chmod 600 /root/.kube/config
install -d -m 700 /home/user/.kube
cp /root/.kube/config /home/user/.kube/config
chown -R user:user /home/user/.kube
export KUBECONFIG=/root/.kube/config

for _ in $(seq 1 60); do
  kubectl get nodes >/dev/null 2>&1 && break
  sleep 1
done
kubectl get nodes >/dev/null
