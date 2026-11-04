#!/bin/bash
# Write join token and CloudCore CA to the shared volume for the edge.

cxadm gettoken --kube-config=/root/.kube/config | tail -n1 | tr -d '[:space:]' > /var/cx-join/token
chmod 644 /var/cx-join/token
[[ -s /var/cx-join/token ]]

ns="${ns:-}"
if [[ -z "$ns" ]]; then
  if kubectl -n continuumx get secret casecret >/dev/null 2>&1; then
    ns=continuumx
  elif kubectl -n kubeedge get secret casecret >/dev/null 2>&1; then
    ns=kubeedge
  fi
fi

if [[ -n "$ns" ]] && kubectl -n "$ns" get secret casecret >/dev/null 2>&1; then
  kubectl -n "$ns" get secret casecret -o jsonpath='{.data.cadata}' \
    | base64 -d | openssl x509 -inform DER -out /var/cx-join/cloudcore-ca.crt
fi
