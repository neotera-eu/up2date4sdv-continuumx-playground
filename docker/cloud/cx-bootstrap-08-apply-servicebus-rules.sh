#!/bin/bash
# Create ServiceBus demo Rule / RuleEndpoints.
#
# You may change:
# - path /demo (cloud REST path)
# - path /api/echo (edge HTTP path)
# - service_port (must match the app port on the edge, default 3000)

kubectl apply -f - <<'EOF' || true
apiVersion: rules.kubeedge.io/v1
kind: RuleEndpoint
metadata:
  name: demo-rest
  namespace: default
spec:
  ruleEndpointType: rest
  properties: {}
---
apiVersion: rules.kubeedge.io/v1
kind: RuleEndpoint
metadata:
  name: demo-servicebus
  namespace: default
spec:
  ruleEndpointType: servicebus
  properties:
    service_port: "3000"
---
apiVersion: rules.kubeedge.io/v1
kind: Rule
metadata:
  name: demo-rest-to-servicebus
  namespace: default
spec:
  source: demo-rest
  sourceResource:
    path: /demo
  target: demo-servicebus
  targetResource:
    path: /api/echo
EOF

for _ in $(seq 1 30); do
  ss -lnt | grep -q ':9443 ' && break
  sleep 1
done
ss -lnt | grep -q ':9443 '

# Publish ready so the edge can join; device manifests are applied in step 09
# after node u2deb-edge becomes Ready.
touch /var/cx-join/cloud-ready
