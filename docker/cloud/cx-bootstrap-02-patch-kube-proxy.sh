#!/bin/bash
# Keep kube-proxy off edge nodes.

if ! kubectl -n kube-system get ds kube-proxy >/dev/null 2>&1; then
  return 0 2>/dev/null || exit 0
fi

if ! kubectl -n kube-system get ds kube-proxy -o jsonpath='{.spec.template.spec.affinity}' | grep -q 'node-role.kubernetes.io/edge'; then
  kubectl patch daemonset kube-proxy -n kube-system --type=json -p='[
    {"op":"add","path":"/spec/template/spec/affinity","value":{"nodeAffinity":{"requiredDuringSchedulingIgnoredDuringExecution":{"nodeSelectorTerms":[{"matchExpressions":[{"key":"node-role.kubernetes.io/edge","operator":"DoesNotExist"}]}]}}}}
  ]' >/dev/null
fi
