#!/usr/bin/env bash
# Docker wrapper around activate-virtual-ecu:
# always download from firmware-catalog, then run the local activator.
# No baked / filesystem-only candidates — catalog is required.
#
# Env: see fetch-ecu-from-catalog.sh

set -euo pipefail

VERSION=${1:-}
case "$VERSION" in
  sim-1.0.0|sim-1.1.0) ;;
  *) echo "Unsupported firmware version: $VERSION" >&2; exit 2 ;;
esac
[[ $(id -u) == 0 ]] || { echo 'Must run as root' >&2; exit 1; }

FETCH=/usr/local/libexec/continuumx/fetch-ecu-from-catalog.sh
LOCAL_ACTIVATE=/usr/local/libexec/continuumx/activate-virtual-ecu.local

"$FETCH" "$VERSION"
exec "$LOCAL_ACTIVATE" "$VERSION"
