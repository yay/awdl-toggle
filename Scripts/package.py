#!/usr/bin/env python3
"""Package the locally signed app and an administrator-installed launchd helper.

Repair contains only the daemon and launchd plist, avoiding a recursive app bundle.
The postinstall script pins client hashes from the final installed signed app.
"""
import hashlib
import plistlib
import shutil
import subprocess
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PRODUCTS = ROOT / "build/Products/Release"
STAGING = ROOT / "build/packaging"
DIST = ROOT / "dist"


def run(*args):
    subprocess.run([str(arg) for arg in args], check=True)


def scripts(directory, names):
    directory.mkdir(parents=True, exist_ok=True)
    for source, destination in names.items():
        shutil.copy2(ROOT / "Packaging" / source, directory / destination)
        (directory / destination).chmod(0o755)
    return directory


def helper_payload(directory):
    helper_dir = directory / "Library/PrivilegedHelperTools"
    launchd_dir = directory / "Library/LaunchDaemons"
    helper_dir.mkdir(parents=True)
    launchd_dir.mkdir(parents=True)
    shutil.copy2(PRODUCTS / "AWDLToggleHelper", helper_dir / "local.vitaly.AWDLToggle.Helper")
    shutil.copy2(ROOT / "Config/local.vitaly.AWDLToggle.Helper.plist", launchd_dir)


def main():
    if not (PRODUCTS / "AWDL Toggle.app").is_dir():
        raise SystemExit("Run Scripts/build.sh first.")
    app_info = plistlib.loads((PRODUCTS / "AWDL Toggle.app/Contents/Info.plist").read_bytes())
    version = app_info["CFBundleShortVersionString"]
    if STAGING.exists():
        shutil.rmtree(STAGING)
    STAGING.mkdir(parents=True)
    DIST.mkdir(exist_ok=True)
    repair_root = STAGING / "repair-root"
    helper_payload(repair_root)
    install_scripts = scripts(STAGING / "install-scripts", {"preinstall": "preinstall", "postinstall": "postinstall"})
    uninstall_scripts = scripts(STAGING / "uninstall-scripts", {"uninstall": "postinstall"})
    repair = STAGING / "AWDL-Toggle-Repair.pkg"
    uninstall = DIST / "AWDL-Toggle-Uninstall.pkg"
    run("pkgbuild", "--root", repair_root, "--scripts", install_scripts,
        "--identifier", "local.vitaly.AWDLToggle.Repair", "--version", version, "--ownership", "recommended", repair)
    uninstall_component = STAGING / "uninstall-component.pkg"
    run("pkgbuild", "--nopayload", "--scripts", uninstall_scripts,
        "--identifier", "local.vitaly.AWDLToggle.Uninstall", "--version", version, uninstall_component)
    distribution = STAGING / "uninstall-distribution.xml"
    run("productbuild", "--synthesize", "--package", uninstall_component, distribution)
    tree = ET.parse(distribution)
    root = tree.getroot()
    ET.SubElement(root, "title").text = "Uninstall AWDL Toggle"
    ET.SubElement(root, "welcome", file="Welcome.html", **{"mime-type": "text/html"})
    ET.SubElement(root, "conclusion", file="Conclusion.html", **{"mime-type": "text/html"})
    ET.SubElement(root, "domains", enable_anywhere="false", enable_currentUserHome="false", enable_localSystem="true")
    tree.write(distribution, encoding="utf-8", xml_declaration=True)
    run("productbuild", "--distribution", distribution, "--package-path", STAGING,
        "--resources", ROOT / "Resources/Uninstall", uninstall)

    install_root = STAGING / "install-root"
    helper_payload(install_root)
    app = install_root / "Applications/AWDL Toggle.app"
    shutil.copytree(PRODUCTS / "AWDL Toggle.app", app)
    resources = app / "Contents/Resources"
    resources.mkdir(exist_ok=True)
    shutil.copy2(repair, resources)
    shutil.copy2(uninstall, resources)
    shutil.copy2(ROOT / "LICENSE.txt", resources)
    # Resource additions change the app signature. Sign the completed outer bundle;
    # the embedded extension was already signed by Xcode and remains unchanged.
    run("codesign", "--force", "--sign", "-", "--options", "runtime", "--timestamp=none", app)
    run("codesign", "--verify", "--deep", "--strict", app)

    # Disable Installer's relocation heuristics: the privileged service trusts only
    # this administrator-installed app, never a copy found in a development folder.
    components = STAGING / "components.plist"
    run("pkgbuild", "--analyze", "--root", install_root, components)
    entries = plistlib.loads(components.read_bytes())
    for entry in entries:
        entry["BundleIsRelocatable"] = False
        entry["BundleIsVersionChecked"] = False
        entry["BundleOverwriteAction"] = "upgrade"
    components.write_bytes(plistlib.dumps(entries))
    package = DIST / "AWDL-Toggle.pkg"
    run("pkgbuild", "--root", install_root, "--scripts", install_scripts, "--component-plist", components,
        "--identifier", "local.vitaly.AWDLToggle.Installer", "--version", version, "--ownership", "recommended", package)
    shutil.copy2(repair, DIST / repair.name)
    for path in sorted(DIST.glob("*.pkg")):
        print(f"{hashlib.sha256(path.read_bytes()).hexdigest()}  {path.name}")


if __name__ == "__main__":
    main()
