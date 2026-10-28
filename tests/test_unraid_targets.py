# SPDX-License-Identifier: GPL-2.0-only
"""Regression tests for Unraid GPU target selection."""
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
INSTALLER = ROOT / "unraid/install.sh"
HOOK = ROOT / "unraid/pre-nvidia.sh"


class UnraidTargetTests(unittest.TestCase):
    def test_shell_syntax(self):
        subprocess.run(["bash", "-n", str(INSTALLER)], check=True)
        subprocess.run(["sh", "-n", str(HOOK)], check=True)

    def test_installer_accepts_target_formats(self):
        text = INSTALLER.read_text()
        match = re.search(
            r'if \[\[ "\$TARGET" != all \]\]; then\n(.*?)\nfi',
            text, re.S
        )
        self.assertIsNotNone(match)
        validation = match.group(0)

        for target, expected in (
            ("all", True),
            ("0000:81:00.0", True),
            ("0000:81:00.0,0000:82:00.0", True),
            ("invalid", False),
            ("0000:81:00.0,", False),
            ("0000:81:00.0,,0000:82:00.0", False),
        ):
            with self.subTest(target=target):
                with tempfile.TemporaryDirectory() as tmp:
                    pci = Path(tmp)
                    for device in ("0000:81:00.0", "0000:82:00.0"):
                        d = pci / device
                        d.mkdir()
                        (d / "vendor").write_text("0x10de\n")
                        (d / "class").write_text("0x030000\n")

                    # Substitute only the sysfs root in the extracted
                    # installer validation, not the source file.
                    snippet = validation.replace(
                        "/sys/bus/pci/devices", str(pci)
                    )
                    script = (
                        "set -e\n"
                        f"TARGET={target!r}\n"
                        + snippet + "\n"
                    )
                    result = subprocess.run(
                        ["bash", "-c", script],
                        capture_output=True, text=True
                    )
                    self.assertEqual(
                        result.returncode == 0, expected,
                        msg=f"{target}: {result.stderr}"
                    )

    def test_duplicate_target_rejected(self):
        text = INSTALLER.read_text()
        self.assertIn("duplicate PCI target", text)
        self.assertIn("declare -A SEEN", text)

    def test_hook_excludes_nvidia_audio(self):
        text = HOOK.read_text()
        self.assertIn('case "$CLASS" in', text)
        self.assertIn("0x03*)", text)
        self.assertIn('"$DEVICE_PATH/vendor"', text)
        self.assertIn('"$DEVICE_PATH/driver"', text)

    def test_hook_preserves_safety_checks(self):
        text = HOOK.read_text()
        for required in (
            "gpu_unlock.targets=$TARGET",
            "unraidsafemode",
            "sha256sum -c SHA256SUMS",
            "/sys/module/gpu_unlock",
            'targets=$TARGET',
        ):
            with self.subTest(required=required):
                self.assertIn(required, text)


if __name__ == "__main__":
    unittest.main()
