"""Offline checks for the public Multi-ECU runtime release verifier.

Test fixtures compile tiny native ELF programs; no private mapper source, SDK,
Kubernetes cluster, or published release archive is required.
"""

import hashlib
import os
import platform
import re
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
SCRIPT = REPO / "scripts" / "prepare-playground-release.sh"

ARTIFACTS = [
    "bin/mapper/linux-amd64/virtual-ethernet-mapper",
    "bin/ecu/linux-amd64/virtual-thermal-ecu-sim-1.0.0",
    "bin/ecu/linux-amd64/virtual-thermal-ecu-sim-1.1.0",
    "bin/ecu/linux-amd64/virtual-tire-pressure-ecu-sim-1.0.0",
    "bin/ecu/linux-amd64/virtual-tire-pressure-ecu-sim-1.1.0",
    "config/virtual-ethernet-mapper.yaml",
    "deploy/systemd/continuumx-virtual-ethernet-mapper.service",
    "deploy/systemd/continuumx-virtual-thermal-ecu.service",
    "deploy/systemd/continuumx-virtual-tire-ecu.service",
    "deploy/libexec/activate-virtual-thermal-ecu",
    "deploy/libexec/activate-virtual-tire-ecu",
    "manifests/samples/devices/thermal-device-model.yaml",
    "manifests/samples/devices/thermal-device-instance.yaml",
    "manifests/samples/devices/tire-pressure-device-model.yaml",
    "manifests/samples/devices/tire-pressure-device-instance.yaml",
    "RELEASE-METADATA.txt",
]

METADATA = """release=v1.0.0
format=continuumx-playground-runtime-v1
created_utc=2026-11-18T00:00:00Z
source_git_commit={commit}
source_worktree=clean
sdk_api_git_commit={commit}
sdk_mapper_framework_git_commit={commit}
go_toolchain=go version go1.23.12 linux/amd64
binary_target=linux/amd64
mapper_protocol=virtual-ethernet
firmware_versions=sim-1.0.0,sim-1.1.0
candidate_type=local-demo-binaries
source_disclosure=no-source-or-sdk-in-runtime-archive
provenance_note=source-and-SDK-commits-recorded-at-packaging-time
""".format(commit="a" * 40)


@unittest.skipUnless(
    shutil.which("cc") and shutil.which("file") and shutil.which("sha256sum")
    and platform.machine().lower() in {"x86_64", "amd64"},
    "Requires an x86-64 Linux build host with cc, file, and sha256sum",
)
class MultiECUReleaseVerifierTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tools = tempfile.TemporaryDirectory(prefix="cx-release-test-binaries-")
        cls.binary_dir = Path(cls.tools.name)
        versions = {"mapper": "sim-1.0.0", "sim-1.0.0": "sim-1.0.0", "sim-1.1.0": "sim-1.1.0"}
        for name, version in versions.items():
            source = cls.binary_dir / f"{name}.c"
            source.write_text(
                '#include <stdio.h>\n#include <string.h>\n'
                'int main(int argc, char **argv) {\n'
                f' if (argc == 2 && strcmp(argv[1], "-version") == 0) puts("{version}");\n'
                ' return 0;\n}\n',
                encoding="utf-8",
            )
            subprocess.run(["cc", str(source), "-o", str(cls.binary_dir / name)], check=True, capture_output=True)

    @classmethod
    def tearDownClass(cls):
        cls.tools.cleanup()

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="cx-public-release-")
        self.root = Path(self.tmp.name)
        (self.root / "scripts").mkdir()
        shutil.copy2(SCRIPT, self.root / "scripts" / SCRIPT.name)
        for path in ARTIFACTS:
            dest = self.root / path
            dest.parent.mkdir(parents=True, exist_ok=True)
            if path == "RELEASE-METADATA.txt":
                dest.write_text(METADATA, encoding="utf-8")
            elif path.endswith("virtual-ethernet-mapper") and path.startswith("bin/"):
                shutil.copy2(self.binary_dir / "mapper", dest)
            elif path.startswith("bin/ecu/"):
                version = "sim-1.1.0" if path.endswith("sim-1.1.0") else "sim-1.0.0"
                shutil.copy2(self.binary_dir / version, dest)
            elif path.startswith("deploy/libexec/"):
                dest.write_text("#!/usr/bin/env bash\nexit 0\n", encoding="utf-8")
                dest.chmod(0o755)
            else:
                dest.write_text(f"test artifact: {path}\n", encoding="utf-8")
        # A nonrelease legacy artifact must be ignored; the Docker folder is separately owned.
        (self.root / "docker").mkdir()
        (self.root / "docker" / "owned-by-colleague.txt").write_text("unchanged\n", encoding="utf-8")
        self.write_checksums()

    def tearDown(self):
        self.tmp.cleanup()

    def write_checksums(self):
        lines = []
        for path in sorted(ARTIFACTS):
            digest = hashlib.sha256((self.root / path).read_bytes()).hexdigest()
            lines.append(f"{digest}  ./{path}\n")
        (self.root / "SHA256SUMS").write_text("".join(lines), encoding="utf-8")

    def verify(self):
        return subprocess.run(
            ["bash", str(self.root / "scripts" / SCRIPT.name), "--verify"],
            cwd=self.root, text=True, capture_output=True, check=False,
        )

    def test_valid_release_passes_without_modifying_any_file(self):
        sums = (self.root / "SHA256SUMS").read_bytes()
        metadata = (self.root / "RELEASE-METADATA.txt").read_bytes()
        result = self.verify()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("16 artifacts", result.stdout)
        self.assertEqual((self.root / "SHA256SUMS").read_bytes(), sums)
        self.assertEqual((self.root / "RELEASE-METADATA.txt").read_bytes(), metadata)
        self.assertEqual((self.root / "docker" / "owned-by-colleague.txt").read_text(), "unchanged\n")

    def test_modified_config_fails_and_does_not_rewrite_checksums(self):
        sums = (self.root / "SHA256SUMS").read_bytes()
        (self.root / "config" / "virtual-ethernet-mapper.yaml").write_text("altered\n")
        result = self.verify()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("checksum", result.stderr.lower())
        self.assertEqual((self.root / "SHA256SUMS").read_bytes(), sums)

    def test_missing_firmware_candidate_fails(self):
        (self.root / "bin" / "ecu" / "linux-amd64" / "virtual-tire-pressure-ecu-sim-1.1.0").unlink()
        result = self.verify()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Missing", result.stderr)

    def test_unexpected_checksums_entry_is_rejected(self):
        with (self.root / "SHA256SUMS").open("a") as f:
            f.write(f"{'a'*64}  ./docker/owned-by-colleague.txt\n")
        result = self.verify()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Unexpected", result.stderr)

    def test_duplicate_checksums_entry_is_rejected(self):
        with (self.root / "SHA256SUMS").open("a") as f:
            f.write((self.root / "SHA256SUMS").read_text().splitlines()[0] + "\n")
        result = self.verify()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Duplicate", result.stderr)

    def test_firmware_identity_mismatch_is_rejected_even_with_valid_checksums(self):
        wrong = self.root / "bin/ecu/linux-amd64/virtual-thermal-ecu-sim-1.1.0"
        shutil.copy2(self.binary_dir / "sim-1.0.0", wrong)
        self.write_checksums()
        result = self.verify()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Firmware identity mismatch", result.stderr)

    def test_release_metadata_must_match_contract_even_when_resigned(self):
        meta = self.root / "RELEASE-METADATA.txt"
        meta.write_text(METADATA.replace("binary_target=linux/amd64", "binary_target=linux/arm64"))
        self.write_checksums()
        result = self.verify()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("metadata", result.stderr)

    def test_dirty_source_metadata_is_not_accepted_for_public_release(self):
        meta = self.root / "RELEASE-METADATA.txt"
        meta.write_text(METADATA.replace("source_worktree=clean", "source_worktree=dirty"))
        self.write_checksums()
        result = self.verify()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("metadata", result.stderr)

    def test_missing_executable_permission_is_rejected(self):
        helper = self.root / "deploy/libexec/activate-virtual-thermal-ecu"
        helper.chmod(0o644)
        result = self.verify()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Not executable", result.stderr)

    def test_wrong_executable_architecture_is_rejected(self):
        p = self.root / "bin/mapper/linux-amd64/virtual-ethernet-mapper"
        p.write_text("#!/bin/sh\nexit 0\n")
        p.chmod(0o755)
        self.write_checksums()
        result = self.verify()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Not a Linux/AMD64 ELF", result.stderr)


if __name__ == "__main__":
    unittest.main()
