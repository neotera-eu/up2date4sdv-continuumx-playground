#!/bin/bash
# Allow pods on the control-plane node (needed for CloudCore).

kubectl taint nodes u2deb-cloud node-role.kubernetes.io/control-plane:NoSchedule- || true
