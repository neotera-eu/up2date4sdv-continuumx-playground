#!/bin/bash
# Make sure CloudCore Router is enabled (needed for ServiceBus REST on :9443).

ns=""
if kubectl -n continuumx get deploy cloudcore >/dev/null 2>&1; then
  ns=continuumx
elif kubectl -n kubeedge get deploy cloudcore >/dev/null 2>&1; then
  ns=kubeedge
fi

if [[ -z "$ns" ]] || ! kubectl -n "$ns" get configmap cloudcore >/dev/null 2>&1; then
  return 0 2>/dev/null || exit 0
fi

tmp=$(mktemp)
kubectl -n "$ns" get configmap cloudcore -o jsonpath='{.data.cloudcore\.yaml}' > "$tmp"

if grep -q '^  router:' "$tmp" && grep -A5 '^  router:' "$tmp" | grep -q 'enable: false'; then
  sed -i '/^  router:/,/^  [a-zA-Z]/ s/^    enable: false$/    enable: true/' "$tmp"
  kubectl -n "$ns" create configmap cloudcore \
    --from-file=cloudcore.yaml="$tmp" \
    --dry-run=client -o yaml | kubectl apply -f -
  kubectl -n "$ns" delete pod -l kubeedge=cloudcore --force --grace-period=0 2>/dev/null || true
  for _ in $(seq 1 60); do
    ss -lnt | grep -q ':10000 ' && break
    sleep 2
  done
fi
rm -f "$tmp"

ss -lnt | grep -q ':10000 '
