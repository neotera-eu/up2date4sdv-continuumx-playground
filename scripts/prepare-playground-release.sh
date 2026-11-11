#!/usr/bin/env bash
# Run once by the Playground release maintainer after supplying a validated mapper binary.
# This is NOT a mapper build script; end users receive a preassembled release.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"
files=(
 bin/mapper/linux-amd64/virtual-ethernet-mapper
 bin/ecu/linux-amd64/virtual-thermal-ecu-sim-1.0.0
 bin/ecu/linux-amd64/virtual-thermal-ecu-sim-1.1.0
 config/virtual-ethernet-mapper.yaml
 deploy/libexec/activate-virtual-ecu
 deploy/systemd/continuumx-virtual-ethernet-mapper.service
 deploy/systemd/continuumx-virtual-ecu.service
 manifests/samples/devices/device-model.yaml
 manifests/samples/devices/device-instance.yaml
)
for file in "${files[@]}"; do
  [[ -s "$file" ]] || { echo "Missing release artifact: $file" >&2; exit 1; }
done
for file in "${files[@]:0:3}" deploy/libexec/activate-virtual-ecu; do
  [[ -x "$file" ]] || { echo "Not executable: $file" >&2; exit 1; }
done
[[ $(bin/ecu/linux-amd64/virtual-thermal-ecu-sim-1.0.0 -version) == sim-1.0.0 ]]
[[ $(bin/ecu/linux-amd64/virtual-thermal-ecu-sim-1.1.0 -version) == sim-1.1.0 ]]
sha256sum "${files[@]}" > SHA256SUMS
sha256sum -c SHA256SUMS
printf 'Release checksums generated: %s/SHA256SUMS\n' "$ROOT"
