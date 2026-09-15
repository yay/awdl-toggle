#!/usr/bin/env python3
"""Generate a dependency-free Xcode project with app, control, and helper targets."""
import hashlib
import json
import plistlib
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
objects = {}


def uid(name):
    return hashlib.sha256(name.encode()).hexdigest()[:24].upper()


def add(key, isa, **values):
    identifier = uid(key)
    objects[identifier] = dict(isa=isa, **values)
    return identifier


def serialize(value, depth=0):
    tab = "\t" * depth
    if isinstance(value, dict):
        return "{\n" + "".join(f"{tab}\t{json.dumps(k)} = {serialize(v, depth + 1)};\n" for k, v in value.items()) + tab + "}"
    if isinstance(value, list):
        return "(\n" + "".join(f"{tab}\t{serialize(v, depth + 1)},\n" for v in value) + tab + ")"
    return str(value) if isinstance(value, int) else json.dumps(value)


def configurations(name, settings):
    configs = []
    for variant in ("Debug", "Release"):
        config = dict(settings)
        config["SWIFT_OPTIMIZATION_LEVEL"] = "-Onone" if variant == "Debug" else "-O"
        config["GCC_OPTIMIZATION_LEVEL"] = "0" if variant == "Debug" else "s"
        configs.append(add(f"{name}.{variant}", "XCBuildConfiguration", name=variant, buildSettings=config))
    return add(name + ".configs", "XCConfigurationList", buildConfigurations=configs,
               defaultConfigurationIsVisible=0, defaultConfigurationName="Release")


def reference(path, kind):
    return add(path, "PBXFileReference", path=path, sourceTree="<group>", lastKnownFileType=kind)


def target(name, sources, bundle, product_type, product_path, extra, dependencies=(), embed=(), resources=()):
    references = [reference(p, "sourcecode.swift" if p.endswith(".swift") else "sourcecode.c.objc") for p in sources]
    source_phase = add(name + ".sources", "PBXSourcesBuildPhase", buildActionMask=2147483647,
                       files=[add(name + "." + p, "PBXBuildFile", fileRef=r) for p, r in zip(sources, references)], runOnlyForDeploymentPostprocessing=0)
    phases = [source_phase, add(name + ".frameworks", "PBXFrameworksBuildPhase", buildActionMask=2147483647, files=[], runOnlyForDeploymentPostprocessing=0)]
    if resources:
        resource_refs = [reference(p, "image.icns") for p in resources]
        references += resource_refs
        phases.append(add(name + ".resources", "PBXResourcesBuildPhase", buildActionMask=2147483647,
                          files=[add(name + ".resource." + p, "PBXBuildFile", fileRef=r) for p, r in zip(resources, resource_refs)], runOnlyForDeploymentPostprocessing=0))
    if embed:
        phases.append(add(name + ".embed", "PBXCopyFilesBuildPhase", buildActionMask=2147483647,
                          dstPath="", dstSubfolderSpec=13, name="Embed Control Extension",
                          files=[add(name + ".embed." + p, "PBXBuildFile", fileRef=uid(p + ".product"), settings={"ATTRIBUTES": ["RemoveHeadersOnCopy", "CodeSignOnCopy"]}) for p in embed], runOnlyForDeploymentPostprocessing=0))
    product = add(name + ".product", "PBXFileReference", explicitFileType=product_type,
                  path=product_path, sourceTree="BUILT_PRODUCTS_DIR", includeInIndex=0)
    settings = {
        "PRODUCT_NAME": name, "PRODUCT_BUNDLE_IDENTIFIER": bundle,
        "CODE_SIGN_STYLE": "Manual", "CODE_SIGN_IDENTITY": "-", "DEVELOPMENT_TEAM": "",
        "ENABLE_HARDENED_RUNTIME": "YES", "ENABLE_DEBUG_DYLIB": "NO",
        "SWIFT_VERSION": "5.0", "GENERATE_INFOPLIST_FILE": "NO",
        "LD_RUNPATH_SEARCH_PATHS": ["$(inherited)", "@executable_path/../Frameworks"],
    }
    settings.update(extra)
    deps = []
    for dep in dependencies:
        proxy = add(name + ".proxy." + dep, "PBXContainerItemProxy", containerPortal=uid("project"), proxyType=1, remoteGlobalIDString=uid(dep), remoteInfo=dep)
        deps.append(add(name + ".dep." + dep, "PBXTargetDependency", target=uid(dep), targetProxy=proxy))
    add(name, "PBXNativeTarget", name=name, productName=name, productReference=product,
        productType={"wrapper.application": "com.apple.product-type.application", "wrapper.app-extension": "com.apple.product-type.app-extension", "compiled.mach-o.executable": "com.apple.product-type.tool"}[product_type],
        buildConfigurationList=configurations(name, settings), buildPhases=phases, buildRules=[], dependencies=deps)
    return references, product


shared = ["Sources/Shared/HelperClient.swift"]
bridging = "Sources/Shared/BridgingHeader.h"
all_refs, products = [], []
for args in [
    ("AWDLToggleExtension", shared + ["Sources/Control/AWDLToggle.swift"], "local.vitaly.AWDLToggle.Control", "wrapper.app-extension", "AWDLToggleExtension.appex", {
        "INFOPLIST_FILE": "Config/Control-Info.plist", "CODE_SIGN_ENTITLEMENTS": "Config/Control.entitlements",
        "APPLICATION_EXTENSION_API_ONLY": "YES", "SKIP_INSTALL": "YES", "SWIFT_OBJC_BRIDGING_HEADER": bridging,
        "LD_RUNPATH_SEARCH_PATHS": ["$(inherited)", "@executable_path/../Frameworks", "@executable_path/../../../../Frameworks"],
    }),
    ("AWDL Toggle", shared + ["Sources/App/AWDLToggleApp.swift"], "local.vitaly.AWDLToggle", "wrapper.application", "AWDL Toggle.app", {
        "INFOPLIST_FILE": "Config/App-Info.plist", "SWIFT_OBJC_BRIDGING_HEADER": bridging,
    }, ["AWDLToggleExtension"], ["AWDLToggleExtension"], ["Resources/AppIcon.icns"]),
    ("AWDLToggleHelper", ["Sources/Helper/AWDLMonitor.m", "Sources/Helper/main.m"], "local.vitaly.AWDLToggle.Helper", "compiled.mach-o.executable", "AWDLToggleHelper", {
        "OTHER_LDFLAGS": ["-framework", "Foundation", "-framework", "Security"],
        "CREATE_INFOPLIST_SECTION_IN_BINARY": "YES", "GENERATE_INFOPLIST_FILE": "YES", "SKIP_INSTALL": "YES",
    }),
]:
    refs, product = target(*args)
    all_refs += refs
    products.append(product)

for path in sorted((ROOT / "Sources").rglob("*.h")):
    all_refs.append(reference(str(path.relative_to(ROOT)), "sourcecode.c.h"))
product_group = add("products", "PBXGroup", children=products, name="Products", sourceTree="<group>")
group = add("root", "PBXGroup", children=list(dict.fromkeys(all_refs)) + [product_group], sourceTree="<group>")
add("project", "PBXProject", attributes={"LastUpgradeCheck": "2700"},
    buildConfigurationList=configurations("project", {
        "SDKROOT": "macosx", "MACOSX_DEPLOYMENT_TARGET": "26.0", "ARCHS": "$(ARCHS_STANDARD)",
        "CLANG_ENABLE_MODULES": "YES", "CLANG_ENABLE_OBJC_ARC": "YES",
        "CLANG_WARN_DOCUMENTATION_COMMENTS": "YES", "GCC_WARN_64_TO_32_BIT_CONVERSION": "YES",
        "GCC_WARN_UNDECLARED_SELECTOR": "YES", "GCC_WARN_UNINITIALIZED_AUTOS": "YES_AGGRESSIVE",
    }), compatibilityVersion="Xcode 14.0", developmentRegion="en", hasScannedForEncodings=0,
    knownRegions=["en", "Base"], mainGroup=group, productRefGroup=product_group,
    projectDirPath="", projectRoot="", targets=[uid(n) for n in ["AWDL Toggle", "AWDLToggleExtension", "AWDLToggleHelper"]])
project = ROOT / "AWDLToggle.xcodeproj"
project.mkdir(exist_ok=True)
(project / "project.pbxproj").write_text("// !$*UTF8*$!\n" + serialize(dict(archiveVersion=1, classes={}, objectVersion=56, objects=objects, rootObject=uid("project"))) + "\n")
scheme_dir = project / "xcshareddata/xcschemes"
scheme_dir.mkdir(parents=True, exist_ok=True)
entries = "".join(f'<BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{uid(n)}" BuildableName="{p}" BlueprintName="{n}" ReferencedContainer="container:AWDLToggle.xcodeproj"/></BuildActionEntry>' for n, p in [("AWDLToggleHelper", "AWDLToggleHelper"), ("AWDL Toggle", "AWDL Toggle.app")])
(scheme_dir / "AWDLToggle.xcscheme").write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2700" version="1.7">
<BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries>{entries}</BuildActionEntries></BuildAction>
<LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{uid('AWDL Toggle')}" BuildableName="AWDL Toggle.app" BlueprintName="AWDL Toggle" ReferencedContainer="container:AWDLToggle.xcodeproj"/></BuildableProductRunnable></LaunchAction>
<ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
''')

base = {"CFBundleDevelopmentRegion": "en", "CFBundleExecutable": "$(EXECUTABLE_NAME)",
        "CFBundleIdentifier": "$(PRODUCT_BUNDLE_IDENTIFIER)", "CFBundleInfoDictionaryVersion": "6.0",
        "CFBundleName": "$(PRODUCT_NAME)", "CFBundleShortVersionString": "1.0.1", "CFBundleVersion": "2",
        "LSMinimumSystemVersion": "$(MACOSX_DEPLOYMENT_TARGET)"}
configs = {
    "App-Info.plist": dict(base, CFBundlePackageType="APPL", CFBundleDisplayName="AWDL Toggle", CFBundleIconFile="AppIcon", NSPrincipalClass="NSApplication"),
    "Control-Info.plist": dict(base, CFBundlePackageType="XPC!", CFBundleDisplayName="AWDL", NSExtension={"NSExtensionPointIdentifier": "com.apple.widgetkit-extension"}),
    "Control.entitlements": {"com.apple.security.app-sandbox": True, "com.apple.security.temporary-exception.mach-lookup.global-name": ["local.vitaly.AWDLToggle.Helper"]},
    "local.vitaly.AWDLToggle.Helper.plist": {"Label": "local.vitaly.AWDLToggle.Helper", "ProgramArguments": ["/Library/PrivilegedHelperTools/local.vitaly.AWDLToggle.Helper"], "MachServices": {"local.vitaly.AWDLToggle.Helper": True}, "RunAtLoad": True, "KeepAlive": True, "ThrottleInterval": 10, "ProcessType": "Background", "AssociatedBundleIdentifiers": ["local.vitaly.AWDLToggle"]},
}
for name, value in configs.items():
    (ROOT / "Config" / name).write_bytes(plistlib.dumps(value, sort_keys=False))
print("Generated AWDLToggle.xcodeproj and Config plists")
