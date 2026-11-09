#!/bin/bash
# Load pre-downloaded images from /opt/cx/images into containerd (first boot only).

set -euo pipefail

marker=/var/lib/containerd/.cx-images-imported
[[ -f "$marker" ]] && exit 0
[[ -d /opt/cx/images ]] || exit 0

echo "importing seeded images into containerd volume (one-time)"
systemctl start containerd
for f in /opt/cx/images/*.tar; do
  [[ -f "$f" ]] || continue
  echo "  ctr import $(basename "$f")"
  ctr -n k8s.io images import "$f" >/dev/null
done
if ! ctr -n k8s.io images ls -q | grep -q 'registry.k8s.io/pause'; then
  echo "pause image missing after import" >&2
  exit 1
fi
touch "$marker"
