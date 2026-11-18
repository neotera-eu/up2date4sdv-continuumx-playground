# Multi-ECU runtime release assets (VirtualBox/VM deployment)

This document defines the **public runtime distribution** consumed by the [ContinuumX Playground](../README.md). It describes the files that must be available to a Playground user. It is **not** a build guide and requires no access to developer source, Go modules, SDKs, or private repositories.

## Distribution layout

The Playground VM demo uses an independently supplied, versioned Linux/AMD64 runtime archive. Once its contents are installed into the Playground checkout, the relevant paths are:

```text
continuumx-playground/
├── bin/
│   ├── mapper/linux-amd64/virtual-ethernet-mapper
│   └── ecu/linux-amd64/
│       ├── virtual-thermal-ecu-sim-1.0.0
│       ├── virtual-thermal-ecu-sim-1.1.0
│       ├── virtual-tire-pressure-ecu-sim-1.0.0
│       └── virtual-tire-pressure-ecu-sim-1.1.0
├── config/virtual-ethernet-mapper.yaml
├── deploy/
│   ├── systemd/
│   │   ├── continuumx-virtual-ethernet-mapper.service
│   │   ├── continuumx-virtual-thermal-ecu.service
│   │   └── continuumx-virtual-tire-ecu.service
│   └── libexec/
│       ├── activate-virtual-thermal-ecu
│       └── activate-virtual-tire-ecu
├── manifests/samples/devices/
│   ├── thermal-device-model.yaml
│   ├── thermal-device-instance.yaml
│   ├── tire-pressure-device-model.yaml
│   └── tire-pressure-device-instance.yaml
├── RELEASE-METADATA.txt
└── SHA256SUMS
```

These files are **runtime artifacts**; the public repository does not contain the mapper's source or the upstream SDK checkouts. The user should obtain them through the project's authorized **public release/distribution channel**. No public download URL is defined here until an artifact has actually been published.

## Maintainer hand-off and verification

A release maintainer receives a versioned `continuumx-playground-release-vX.Y.Z.tar.gz` archive through the authorized internal release process. Its top-level directory is `continuumx-playground-release-vX.Y.Z/` and the contained paths match the tree above. To review it before incorporating into the public repository:

```bash
# Replace the example filename with the actual release artifact.
tar -tzf continuumx-playground-release-v1.0.0.tar.gz
mkdir -p /tmp/cx-public-runtime
# Extract the versioned top-level directory into this separate staging location.
tar -xzf continuumx-playground-release-v1.0.0.tar.gz \
  -C /tmp/cx-public-runtime
cd /tmp/cx-public-runtime/continuumx-playground-release-v1.0.0
sha256sum -c SHA256SUMS
cat RELEASE-METADATA.txt
```

After reviewing the archive contents and redistribution/licensing requirements, copy **only** its runtime directories (`bin/`, `config/`, `deploy/`, `manifests/samples/devices/`) and its `SHA256SUMS` / `RELEASE-METADATA.txt` into the public Playground checkout, using paths relative to the root. No files under `docker/` or `doc/docker-playground-howto.md` belong to this hand-off. Never publish a developer stage, Git history, SDK clones, or source-tree archive as a substitute for this runtime release.

> The runtime release's checksums are computed for its contents. After incorporation, verify them from the root of the Playground checkout with `sha256sum -c SHA256SUMS`. If other tracked runtime files were altered during integration, resolve that discrepancy rather than regenerating hashes without checking provenance.

## Compatibility and safety

- The reference VMs use Debian 13, ContinuumX/EdgeCore based on KubeEdge v1.23 and Linux AMD64.
- Both DeviceModels and Devices are in namespace `default` and target node `u2deb-edge` in the sample manifests. Adapt the node name for a different cluster.
- Use **one** `continuumx-virtual-ethernet-mapper.service` for both ECUs. Its logical DMI protocol remains `virtual-ethernet`.
- The thermal and tire ECUs use separate `systemd` units, Unix sockets, state files, activation helpers, and candidate binaries. Never apply a helper or firmware candidate to the wrong ECU.
- The versioned binaries are **simulated local replacement artifacts**. They are not secured OTA images and do not implement automotive boot authentication or firmware signature verification.
- Public redistribution requires an appropriate license/notice and compliance review. `SHA256SUMS` checks integrity against the supplied manifest, not authenticity.

The VM installation and exercises are in the [main README](../README.md). The separately maintained Docker/Podman environment is outside the scope of this runtime hand-off.
