#!/usr/bin/env bash
# Host prep before starting the playground (rootless Podman).
#
# You may change the inotify values below if you still hit "too many open files"
# on kubelet / edgecore.

set -euo pipefail

run() {
  if command -v run0 >/dev/null 2>&1; then
    run0 "$@"
  else
    sudo "$@"
  fi
}

run sysctl -w fs.inotify.max_user_instances=1024
run sysctl -w fs.inotify.max_user_watches=1048576
run tee /etc/sysctl.d/99-continuumx-playground.conf >/dev/null <<'EOF'
fs.inotify.max_user_instances=1024
fs.inotify.max_user_watches=1048576
EOF

echo "host prep complete"
