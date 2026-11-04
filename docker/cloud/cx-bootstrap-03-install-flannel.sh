#!/bin/bash
# Install Flannel CNI (manifest is bundled in the image).

if ! kubectl -n kube-flannel get ds kube-flannel-ds >/dev/null 2>&1; then
  kubectl apply -f /opt/cx/kube-flannel.yml
fi

kubectl patch daemonset kube-flannel-ds -n kube-flannel --type merge -p \
  '{"spec":{"template":{"spec":{"affinity":{"nodeAffinity":{"requiredDuringSchedulingIgnoredDuringExecution":{"nodeSelectorTerms":[{"matchExpressions":[{"key":"node-role.kubernetes.io/edge","operator":"DoesNotExist"}]}]}}}}}}}' \
  >/dev/null 2>&1 || true
