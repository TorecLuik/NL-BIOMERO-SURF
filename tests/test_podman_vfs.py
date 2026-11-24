# Copyright (c) 2026, NL-BioImaging. BSD 2-Clause License; see LICENSE.
"""Check nested VFS layer extraction with only AppArmor confinement varied."""

import argparse
import json
import subprocess
import sys
import unittest
from uuid import uuid4

import test_surf_upgrade as configuration

COMMAND_TIMEOUT_SECONDS = 120
LAYER_PROBE = """set -eu
test "$(podman info --format '{{.Store.GraphDriverName}} {{.Host.Security.Rootless}}')" = 'vfs true'
mkdir -p /tmp/surf-vfs-rootfs
printf 'SURF VFS layer test\\n' > /tmp/surf-vfs-rootfs/probe.txt
tar --mtime=@0 --owner=0 --group=0 --numeric-owner -C /tmp/surf-vfs-rootfs -cf /tmp/surf-vfs-rootfs.tar .
podman import /tmp/surf-vfs-rootfs.tar localhost/surf-vfs-probe:test
podman image inspect localhost/surf-vfs-probe:test --format '{{.Id}}'
"""


def docker(*arguments: str, check: bool = True) -> subprocess.CompletedProcess:
    """Run a bounded Docker command without exposing a service environment."""
    return subprocess.run(
        ["docker", *arguments], capture_output=True, text=True, check=check,
        timeout=COMMAND_TIMEOUT_SECONDS,
    )


class PodmanVfsTests(unittest.TestCase):
    """Exercise the site security options with fresh disposable container stores."""

    image: str
    apparmor_available: bool

    @classmethod
    def setUpClass(cls) -> None:
        cls.service = configuration.ComposeIntegrationTests().compose_model()["biomero-importer"]

    def unpack_layer(self, security_options: list[str]) -> tuple[int, str]:
        """Import one tiny layer without network, application startup or host binds."""
        self.assertFalse(self.service.get("privileged", False))
        self.assertFalse(self.service.get("cap_add"))
        self.assertFalse(self.service.get("devices"))
        name = f"surf-vfs-probe-{uuid4().hex}"
        arguments = ["create", "--name", name, "--network", "none",
                     "--user", self.service["user"], "--tmpfs", "/tmp",
                     "--entrypoint", "/bin/sh"]
        for option in security_options:
            arguments.extend(["--security-opt", option])
        docker(*arguments, self.image, "-c", LAYER_PROBE)
        self.addCleanup(docker, "rm", "--force", "--volumes", name)
        # start --attach itself can succeed when the container command fails;
        # the inspected exit code is the result of the actual unpack operation.
        result = docker("start", "--attach", name, check=False)
        container = json.loads(docker("inspect", name).stdout)[0]
        self.assertFalse(container["State"]["Running"])
        self.assertFalse(container["HostConfig"]["Privileged"])
        self.assertFalse(container["HostConfig"].get("CapAdd"))
        self.assertFalse(container["HostConfig"].get("Devices"))
        if self.apparmor_available:
            expected = next(option.split("=", 1)[1] for option in security_options
                            if option.startswith("apparmor="))
            self.assertEqual(container["AppArmorProfile"], expected)
        return container["State"]["ExitCode"], result.stdout + result.stderr

    def test_site_profile_allows_rootless_vfs_unpack(self) -> None:
        code, output = self.unpack_layer(self.service["security_opt"])
        self.assertEqual(code, 0, output)
        self.assertRegex(output, r"[0-9a-f]{64}")

    def test_docker_default_reproduces_remount_denial(self) -> None:
        if not self.apparmor_available:
            self.skipTest("AppArmor host needed for the negative control")
        options = [option for option in self.service["security_opt"]
                   if not option.startswith("apparmor=")]
        options.append("apparmor=docker-default")
        code, output = self.unpack_layer(options)
        self.assertNotEqual(code, 0, output)
        self.assertRegex(output, r"remount /.*permission denied")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--image", required=True, help="Existing pinned importer image")
    parser.add_argument("--require-apparmor", action="store_true",
                        help="Fail instead of skipping the negative control (used in CI)")
    args = parser.parse_args()
    options = json.loads(docker("info", "--format", "{{json .SecurityOptions}}").stdout)
    PodmanVfsTests.apparmor_available = "name=apparmor" in options
    if args.require_apparmor and not PodmanVfsTests.apparmor_available:
        parser.error("Docker must have AppArmor enabled for this regression")
    PodmanVfsTests.image = args.image
    unittest.main(argv=[sys.argv[0]], verbosity=2)
