#!/usr/bin/env bash
# Download the requested ECU firmware from the catalog, then run the local activator.
# Usage: activate-from-catalog.sh <catalog-name> <local-activator> <version>
set -euo pipefail

NAME=${1:-}
LOCAL=${2:-}
VERSION=${3:-}
[[ -n "$NAME" && -n "$LOCAL" && -n "$VERSION" ]] || {
  echo "usage: activate-from-catalog.sh <name> <local-activator> <version>" >&2
  exit 2
}
[[ -x "$LOCAL" ]] || { echo "missing local activator $LOCAL" >&2; exit 1; }

/usr/local/libexec/continuumx/fetch-ecu-from-catalog.sh "$NAME" "$VERSION"
exec "$LOCAL" "$VERSION"
