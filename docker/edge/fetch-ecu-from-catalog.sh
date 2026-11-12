#!/usr/bin/env bash
# Download a Virtual ECU binary from firmware-catalog and stage it locally.
# Catalog is the only source of truth; nothing is baked into the edge image.
#
# Usage: fetch-ecu-from-catalog.sh <version> [--install-active]
#
# Env:
#   FIRMWARE_CATALOG_URL   default http://firmware-catalog:3100
#   FIRMWARE_CATALOG_NAME  default virtual-thermal-ecu
#   FIRMWARE_FETCH_TIMEOUT default 30
#   FIRMWARE_FETCH_RETRIES default 60

set -euo pipefail

VERSION=${1:-}
INSTALL_ACTIVE=0
[[ "${2:-}" == "--install-active" ]] && INSTALL_ACTIVE=1

case "$VERSION" in
  sim-1.0.0|sim-1.1.0) ;;
  *) echo "Unsupported firmware version: $VERSION" >&2; exit 2 ;;
esac
[[ $(id -u) == 0 ]] || { echo 'Must run as root' >&2; exit 1; }

# Optional drop-in from the container environment / image.
if [[ -f /etc/continuumx/firmware-catalog.env ]]; then
  # shellcheck disable=SC1091
  set -a
  source /etc/continuumx/firmware-catalog.env
  set +a
fi

CANDIDATES=/opt/continuumx/firmware-candidates
ACTIVE=/opt/continuumx/virtual-thermal-ecu/virtual-thermal-ecu
CATALOG_URL="${FIRMWARE_CATALOG_URL:-http://firmware-catalog:3100}"
CATALOG_NAME="${FIRMWARE_CATALOG_NAME:-virtual-thermal-ecu}"
TIMEOUT="${FIRMWARE_FETCH_TIMEOUT:-30}"
RETRIES="${FIRMWARE_FETCH_RETRIES:-60}"
SOURCE="${CANDIDATES}/virtual-thermal-ecu-${VERSION}"
BASE="${CATALOG_URL%/}"
URL="${BASE}/api/download?name=${CATALOG_NAME}&version=${VERSION}"

mkdir -p "$CANDIDATES" "$(dirname "$ACTIVE")" /var/log

echo "waiting for firmware-catalog at ${BASE}/api/health"
ok=0
for _ in $(seq 1 "$RETRIES"); do
  if curl -fsS --max-time 3 "${BASE}/api/health" >/dev/null 2>&1; then
    ok=1
    break
  fi
  sleep 1
done
[[ "$ok" == 1 ]] || {
  echo "error: firmware-catalog unreachable at ${BASE}" >&2
  exit 1
}

echo "fetching firmware ${CATALOG_NAME}@${VERSION} from ${URL}"
tmp="$(mktemp "${CANDIDATES}/.download.XXXXXX")"
if ! curl -fsSL --max-time "$TIMEOUT" -o "$tmp" "$URL"; then
  rm -f "$tmp"
  echo "error: catalog download failed for ${CATALOG_NAME}@${VERSION}" >&2
  exit 1
fi

chmod 0755 "$tmp"
chown root:root "$tmp"
chmod go-w "$tmp"

embedded="$(/usr/bin/env "$tmp" -version 2>/dev/null || true)"
if [[ "$embedded" != "$VERSION" ]]; then
  rm -f "$tmp"
  echo "error: downloaded binary reports '${embedded}', expected '${VERSION}'" >&2
  exit 1
fi

mv -f "$tmp" "$SOURCE"
echo "staged candidate ${SOURCE}"
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) fetched ${CATALOG_NAME}@${VERSION} from ${URL}" \
  >>/var/log/continuumx-catalog-fetch.log

if [[ "$INSTALL_ACTIVE" == 1 ]]; then
  # Do not clobber an already-running/activated version on service restart
  # (OTA installs sim-1.1.0 then systemctl restart; ExecStartPre must not
  # roll that back to sim-1.0.0).
  if [[ -x "$ACTIVE" ]]; then
    echo "active ECU already present at ${ACTIVE}; leaving in place"
  else
    install -o root -g root -m 0755 "$SOURCE" "$ACTIVE"
    echo "installed active ECU ${ACTIVE} (${VERSION})"
  fi
fi
