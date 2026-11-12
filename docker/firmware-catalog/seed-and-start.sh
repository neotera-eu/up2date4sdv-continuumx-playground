#!/bin/sh
# Seed Virtual ECU firmware binaries into the catalog volume, then start Next.js.
set -eu

DATA_DIR="${FIRMWARE_DATA_DIR:-/data/firmwares}"
SEED_DIR="${FIRMWARE_SEED_DIR:-/opt/firmware-seed}"
META="${DATA_DIR}/meta.json"
FILES="${DATA_DIR}/files"

mkdir -p "$FILES"

seed_one() {
  name="$1"
  version="$2"
  src="$3"
  desc="$4"

  if [ ! -f "$src" ]; then
    echo "seed skip ${name}@${version}: missing ${src}"
    return 0
  fi

  stored="$(printf '%s__%s.bin' "$name" "$version")"
  dest="${FILES}/${stored}"
  cp -f "$src" "$dest"
  size="$(wc -c <"$dest" | tr -d ' ')"
  sha="$(sha256sum "$dest" | awk '{print $1}')"
  id="$(cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "${name}-${version}")"
  uploaded="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  node - "$META" "$name" "$version" "$desc" "$stored" "$size" "$sha" "$id" "$uploaded" "$src" <<'NODE'
const fs = require("fs");
const path = require("path");
const [metaPath, name, version, description, storedAs, size, sha256, id, uploadedAt, src] = process.argv.slice(2);
let items = [];
try {
  const parsed = JSON.parse(fs.readFileSync(metaPath, "utf8"));
  if (Array.isArray(parsed.items)) items = parsed.items;
} catch {}
items = items.filter((x) => !(x.name === name && x.version === version));
items.push({
  id,
  name,
  version,
  description,
  deviceModel: "automotive-thermal-ecu-fw-demo",
  originalName: path.basename(src),
  storedAs,
  size: Number(size),
  sha256,
  uploadedAt,
});
fs.writeFileSync(metaPath, JSON.stringify({ items }, null, 2));
console.log(`seeded ${name}@${version} (${size} bytes)`);
NODE
}

# Official playground binaries from bin/ecu/linux-amd64/.
seed_one virtual-thermal-ecu sim-1.0.0 \
  "${SEED_DIR}/virtual-thermal-ecu-sim-1.0.0" \
  "Initial Virtual Thermal ECU (bin/ecu …-sim-1.0.0) — edge boot baseline"

seed_one virtual-thermal-ecu sim-1.1.0 \
  "${SEED_DIR}/virtual-thermal-ecu-sim-1.1.0" \
  "Update candidate Virtual Thermal ECU (bin/ecu …-sim-1.1.0) — twin OTA target"

exec node server.js
