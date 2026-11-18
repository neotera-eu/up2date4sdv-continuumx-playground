#!/usr/bin/env bash
# Verify an already-imported, self-contained Multi-ECU runtime release.
# The private build process creates SHA256SUMS; this verifier MUST NOT rewrite it.
# Existing legacy files and the separately maintained docker/ tree are out of scope.
set -euo pipefail

usage() {
  cat <<'HELP'
Usage: ./scripts/prepare-playground-release.sh [--verify]

Verify the committed Multi-ECU runtime distribution in this Playground checkout:
  * exact release checksum inventory (16 files)
  * hashes of every delivered artifact, including metadata
  * Linux/AMD64 ELF binaries and their firmware version identities
  * executable permissions, required metadata, and canonical paths

This is a read-only verification step. It never generates or changes SHA256SUMS.
HELP
}

case "${1:-}" in
  ''|--verify) [[ $# -le 1 ]] || { usage >&2; exit 2; } ;;
  -h|--help) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"

fail() { printf 'Release verification FAILED: %s\n' "$*" >&2; exit 1; }
for tool in sha256sum file grep; do
  command -v "$tool" >/dev/null 2>&1 || fail "Required command not found: $tool"
done

# This is the canonical public runtime inventory produced by the versioned packager.
# Keep legacy files in the checkout but never include them in this manifest.
artifacts=(
  bin/mapper/linux-amd64/virtual-ethernet-mapper
  bin/ecu/linux-amd64/virtual-thermal-ecu-sim-1.0.0
  bin/ecu/linux-amd64/virtual-thermal-ecu-sim-1.1.0
  bin/ecu/linux-amd64/virtual-tire-pressure-ecu-sim-1.0.0
  bin/ecu/linux-amd64/virtual-tire-pressure-ecu-sim-1.1.0
  config/virtual-ethernet-mapper.yaml
  deploy/systemd/continuumx-virtual-ethernet-mapper.service
  deploy/systemd/continuumx-virtual-thermal-ecu.service
  deploy/systemd/continuumx-virtual-tire-ecu.service
  deploy/libexec/activate-virtual-thermal-ecu
  deploy/libexec/activate-virtual-tire-ecu
  manifests/samples/devices/thermal-device-model.yaml
  manifests/samples/devices/thermal-device-instance.yaml
  manifests/samples/devices/tire-pressure-device-model.yaml
  manifests/samples/devices/tire-pressure-device-instance.yaml
  RELEASE-METADATA.txt
)

[[ -f SHA256SUMS && -s SHA256SUMS && ! -L SHA256SUMS ]] || fail 'SHA256SUMS is missing, empty or a symlink'

declare -A expected=() seen=()
for path in "${artifacts[@]}"; do
  expected["$path"]=1
  [[ -f "$path" && -s "$path" && ! -L "$path" ]] || fail "Missing, empty or linked release artifact: $path"
done

# The public release generator uses `find .` and therefore writes `./path`.
# Accept either `./path` or `path` but reject duplicates and extra entries.
count=0
while IFS= read -r line || [[ -n "$line" ]]; do
  [[ "$line" =~ ^[0-9a-f]{64}[[:space:]][[:space:]](.+)$ ]] || fail 'Malformed SHA256SUMS entry'
  path=${BASH_REMATCH[1]}
  path=${path#./}
  [[ -n ${expected[$path]+yes} ]] || fail "Unexpected checksummed path: $path"
  [[ -z ${seen[$path]+yes} ]] || fail "Duplicate checksummed path: $path"
  seen["$path"]=1
  ((count+=1))
done < SHA256SUMS
[[ $count -eq ${#artifacts[@]} ]] || fail "SHA256SUMS lists $count artifacts, expected ${#artifacts[@]}"
for path in "${artifacts[@]}"; do
  [[ -n ${seen[$path]+yes} ]] || fail "Artifact is not included in SHA256SUMS: $path"
done

# Verify supplied checksums; never regenerate them from potentially modified files.
sha256sum --check --strict --quiet SHA256SUMS || fail 'A release checksum does not match'

metadata=RELEASE-METADATA.txt
metadata_field() {
  local pattern=$1
  grep -Eq "$pattern" "$metadata" || fail "Missing or invalid release metadata: $pattern"
}
metadata_field '^release=v[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9][A-Za-z0-9.-]*)?$'
metadata_field '^format=continuumx-playground-runtime-v1$'
metadata_field '^binary_target=linux/amd64$'
metadata_field '^mapper_protocol=virtual-ethernet$'
metadata_field '^firmware_versions=sim-1\.0\.0,sim-1\.1\.0$'
metadata_field '^candidate_type=local-demo-binaries$'
metadata_field '^source_worktree=clean$'
metadata_field '^source_disclosure=no-source-or-sdk-in-runtime-archive$'
metadata_field '^source_git_commit=[0-9a-f]{40,64}$'
metadata_field '^sdk_api_git_commit=[0-9a-f]{40,64}$'
metadata_field '^sdk_mapper_framework_git_commit=[0-9a-f]{40,64}$'

check_elf() {
  local path=$1 description
  [[ -x "$path" ]] || fail "Not executable: $path"
  description=$(LC_ALL=C file -Lb "$path")
  [[ $description == *'ELF 64-bit'* && ( $description == *'x86-64'* || $description == *'x86_64'* ) ]] || \
    fail "Not a Linux/AMD64 ELF executable: $path ($description)"
}
check_elf bin/mapper/linux-amd64/virtual-ethernet-mapper
for ecu in virtual-thermal-ecu virtual-tire-pressure-ecu; do
  for version in sim-1.0.0 sim-1.1.0; do
    path="bin/ecu/linux-amd64/$ecu-$version"
    check_elf "$path"
    actual=$("$path" -version) || fail "Failed to run firmware identity check: $path"
    [[ "$actual" == "$version" ]] || fail "Firmware identity mismatch: $path reports '$actual', expected '$version'"
  done
done
for helper in deploy/libexec/activate-virtual-thermal-ecu deploy/libexec/activate-virtual-tire-ecu; do
  [[ -x "$helper" ]] || fail "Not executable: $helper"
done

printf 'Multi-ECU runtime verified: %d artifacts, 5 Linux/AMD64 binaries, 2 activation helpers.\n' "$count"
printf 'Checksums and release metadata verified. No files were modified.\n'
