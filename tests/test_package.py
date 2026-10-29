"""Verify the published tarball and its installed CLI without operating a phone."""

import json
import os
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile
import unittest

ARCHIVE = Path(sys.argv.pop(1)).resolve()


class PackageTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.workspace = tempfile.TemporaryDirectory(prefix="iphctl-package-")
        cls.addClassCleanup(cls.workspace.cleanup)
        cls.root = Path(cls.workspace.name)
        cls.prefix = cls.root / "install"
        subprocess.run(
            ["npm", "install", "--global", "--prefix", str(cls.prefix), "--ignore-scripts",
             "--no-audit", "--no-fund", "--cache", str(cls.root / "cache"), str(ARCHIVE)],
            check=True, capture_output=True, text=True, timeout=60,
        )
        cls.cli = cls.prefix / "bin" / "iphctl"
        cls.package = cls.prefix / "lib" / "node_modules" / "iphctl"
        cls.env = {**os.environ, "IPHONE_CT_CONTROL_DIR": str(cls.root / "control")}

    def run_cli(self, *args, input=None):
        return subprocess.run([str(self.cli), *args], input=input, env=self.env,
                              capture_output=True, text=True, timeout=10)

    def test_archive_contains_only_distribution_files(self):
        with tarfile.open(ARCHIVE) as archive:
            self.assertEqual(set(archive.getnames()), {
                "package/package.json", "package/README.md", "package/LICENSE",
                "package/bin/iphctl.cjs", "package/native/iphctl",
            })
            self.assertTrue(all(member.isfile() for member in archive.getmembers()))

    def test_binary_is_universal_signed_and_targets_macos_15(self):
        binary = self.package / "native" / "iphctl"
        result = subprocess.run(["lipo", "-archs", str(binary)], check=True, capture_output=True, text=True)
        self.assertEqual(set(result.stdout.split()), {"arm64", "x86_64"})
        subprocess.run(["codesign", "--verify", "--strict", str(binary)], check=True, capture_output=True)
        result = subprocess.run(["otool", "-arch", "all", "-l", str(binary)], check=True,
                                capture_output=True, text=True)
        self.assertEqual(result.stdout.count("minos 15.0"), 2)

    def test_installed_command_preserves_help_capabilities_and_exit_codes(self):
        self.assertEqual(self.run_cli("--help").returncode, 0)
        result = self.run_cli("capabilities")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(json.loads(result.stdout)["ok"])
        result = self.run_cli("swipe", "up")
        self.assertEqual(result.returncode, 1)
        self.assertEqual(json.loads(result.stdout)["code"], "unsupported_gesture")

    def test_installed_agent_preserves_ndjson_and_request_ids(self):
        requests = [{"id": "features", "cmd": "capabilities"},
                    {"id": "invalid", "cmd": "click", "x": -1, "y": 10},
                    {"id": "last", "cmd": "capabilities"}]
        result = self.run_cli("agent", input="\n".join(json.dumps(item) for item in requests) + "\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        responses = [json.loads(line) for line in result.stdout.splitlines()]
        self.assertEqual([item["id"] for item in responses], [item["id"] for item in requests])
        self.assertEqual([item["ok"] for item in responses], [True, False, True])
        self.assertFalse(responses[1]["event_sent"])


if __name__ == "__main__":
    unittest.main()
