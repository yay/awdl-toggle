import importlib.util
import plistlib
import subprocess
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


class PackagingTests(unittest.TestCase):
    def test_shell_scripts_parse(self):
        for script in (ROOT / "Packaging").iterdir():
            with self.subTest(script=script.name):
                subprocess.run(["/bin/bash", "-n", script], check=True)

    def test_launchd_lifetime(self):
        data = plistlib.loads((ROOT / "Config/local.vitaly.AWDLToggle.Helper.plist").read_bytes())
        self.assertTrue(data["RunAtLoad"])
        self.assertTrue(data["KeepAlive"])
        self.assertEqual(data["MachServices"], {"local.vitaly.AWDLToggle.Helper": True})
        self.assertEqual(data["ProgramArguments"], ["/Library/PrivilegedHelperTools/local.vitaly.AWDLToggle.Helper"])

    def test_extension_has_only_required_sandbox_exception(self):
        data = plistlib.loads((ROOT / "Config/Control.entitlements").read_bytes())
        self.assertEqual(data, {"com.apple.security.app-sandbox": True,
            "com.apple.security.temporary-exception.mach-lookup.global-name": ["local.vitaly.AWDLToggle.Helper"]})

    def test_project_regeneration_is_reproducible(self):
        project = ROOT / "AWDLToggle.xcodeproj/project.pbxproj"
        before = project.read_bytes()
        subprocess.run(["python3", ROOT / "Scripts/project.py"], check=True, stdout=subprocess.DEVNULL)
        self.assertEqual(before, project.read_bytes())

    def test_install_is_restricted_to_startup_volume(self):
        result = subprocess.run(["/bin/bash", ROOT / "Packaging/preinstall", "package", "destination", "/Volumes/Other"], capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(b"startup volume", result.stderr)


if __name__ == "__main__":
    unittest.main()
