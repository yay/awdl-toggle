#!/usr/bin/env python3
"""Inspect the actual installer payload and exercise its signature allowlist.

Does not install software, contact the helper, or change network state.
"""
import hashlib
import plistlib
import re
import shutil
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def run(*args, check=True):
    return subprocess.run([str(x) for x in args], check=check, capture_output=True, text=True)


def main():
    with tempfile.TemporaryDirectory(prefix="package-test-", dir=ROOT / "build") as temporary:
        expanded = Path(temporary) / "expanded"
        run("pkgutil", "--expand-full", ROOT / "dist/AWDL-Toggle.pkg", expanded)
        payload = expanded / "Payload"
        app = payload / "Applications/AWDL Toggle.app"
        extension = app / "Contents/PlugIns/AWDLToggleExtension.appex"
        helper = payload / "Library/PrivilegedHelperTools/local.vitaly.AWDLToggle.Helper"
        run("codesign", "--verify", "--deep", "--strict", app)
        run("codesign", "--verify", "--strict", helper)
        assert hashlib.sha256(helper.read_bytes()).digest() == hashlib.sha256((ROOT / "build/Products/Release/AWDLToggleHelper").read_bytes()).digest()
        assert (extension / "Contents/Resources/Metadata.appintents/extract.actionsdata").is_file()
        for filename in ("AWDL-Toggle-Repair.pkg", "AWDL-Toggle-Uninstall.pkg"):
            assert (app / "Contents/Resources" / filename).is_file()

        clauses = []
        for bundle, identifier in [(app, "local.vitaly.AWDLToggle"), (extension, "local.vitaly.AWDLToggle.Control")]:
            info = plistlib.loads((bundle / "Contents/Info.plist").read_bytes())
            assert info["CFBundleIdentifier"] == identifier
            executable = bundle / "Contents/MacOS" / info["CFBundleExecutable"]
            architectures = run("lipo", "-archs", executable).stdout.split()
            assert set(architectures) == {"arm64", "x86_64"}
            for architecture in architectures:
                output = run("codesign", "-d", "--arch", architecture, "--verbose=4", bundle).stderr
                digest = re.search(r"^CDHash=([0-9a-f]{40})$", output, re.MULTILINE).group(1)
                clauses.append(f'(identifier "{identifier}" and cdhash H"{digest}")')
        requirement = " or ".join(clauses)
        for bundle in (app, extension):
            run("codesign", "--verify", "--strict", "-R", "=" + requirement, bundle)

        # Same identifier, different content/signature: the helper must not trust it.
        modified = Path(temporary) / "Modified.app"
        shutil.copytree(app, modified)
        (modified / "Contents/Resources/tampered.txt").write_text("Different build, same bundle identifier")
        run("codesign", "--force", "--sign", "-", "--options", "runtime", "--timestamp=none", modified)
        assert run("codesign", "--verify", "--strict", "-R", "=" + requirement, modified, check=False).returncode != 0
        print("PASS: extracted package signatures, universal binaries, App Intents metadata, embedded maintenance packages, and rejection of a modified client")


if __name__ == "__main__":
    main()
