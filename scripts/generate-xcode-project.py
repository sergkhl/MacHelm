#!/usr/bin/env python3
"""Generate MacHelm's Xcode project and bundle metadata from its Swift inventory.

This script uses Python's standard library. Object identifiers derive from
stable semantic keys, so rerunning it produces the same files until an input
changes. Shared source files compile directly into each applicable executable;
SwiftPM remains the independent module/test harness.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import plistlib
import sys
from dataclasses import dataclass
from pathlib import Path
import xml.etree.ElementTree as ET


ROOT = Path(__file__).resolve().parent.parent
PROJECT_NAME = "MacHelm"
PROJECT_PATH = Path("MacHelm.xcodeproj")
BUNDLE_PREFIX = "io.github.sergkhl.MacHelm"
VERSION = "0.1"
BUILD = "2"
APP_ENTITLEMENTS = "MacHelm/MacHelm.entitlements"


class Reference(str):
    """An unquoted reference to another project object."""


def identifier(key: str) -> Reference:
    digest = hashlib.sha256(f"MacHelm.xcode:{key}".encode()).hexdigest()
    return Reference(digest[:24].upper())


def render(value: object, level: int = 0) -> str:
    indent = "\t" * level
    if isinstance(value, Reference):
        return str(value)
    if isinstance(value, str):
        return json.dumps(value, ensure_ascii=False)
    if isinstance(value, int):
        return str(value)
    if isinstance(value, dict):
        lines = ["{"]
        for key, item in value.items():
            name = str(key) if isinstance(key, Reference) else json.dumps(key)
            lines.append(f"{indent}\t{name} = {render(item, level + 1)};")
        lines.append(f"{indent}}}")
        return "\n".join(lines)
    if isinstance(value, (list, tuple)):
        if not value:
            return "()"
        lines = ["("]
        lines.extend(f"{indent}\t{render(item, level + 1)}," for item in value)
        lines.append(f"{indent})")
        return "\n".join(lines)
    raise TypeError(f"Unsupported project value: {value!r}")


def swift_files(*directories: str) -> list[str]:
    paths = {
        path.relative_to(ROOT).as_posix()
        for directory in directories
        for path in (ROOT / directory).glob("*.swift")
    }
    return sorted(paths)


@dataclass(frozen=True)
class Target:
    name: str
    bundle_id: str
    info_path: str
    sources: list[str]
    frameworks: tuple[str, ...]
    app: bool = False


def targets() -> list[Target]:
    app_sources = swift_files(
        "MacHelm",
        "Sources/ActivityCore",
        "Sources/FanControlCore",
        "Sources/PowerCore",
        "Sources/StartupServicesCore",
        "Sources/StorageCore",
        "Sources/ToolkitCore",
    )
    app_sources.append("Sources/FanControlHardware/FanSigning.swift")
    return [
        Target(
            PROJECT_NAME,
            BUNDLE_PREFIX,
            "MacHelm/Info.plist",
            sorted(app_sources),
            (
                "AppKit", "Carbon", "Combine", "CoreGraphics", "CryptoKit",
                "Foundation", "IOKit", "Security", "ServiceManagement",
                "SwiftUI", "UniformTypeIdentifiers", "UserNotifications",
            ),
            app=True,
        ),
        Target(
            "FanControlHelper",
            BUNDLE_PREFIX + ".FanControlHelper",
            "FanControlHelper/Info.plist",
            swift_files(
                "FanControlHelper", "Sources/FanControlCore",
                "Sources/FanControlHardware", "Sources/FanControlRuntime",
            ),
            ("Foundation", "IOKit", "Security"),
        ),
        Target(
            "ToolkitHelper",
            BUNDLE_PREFIX + ".ToolkitHelper",
            "ToolkitHelper/Info.plist",
            swift_files("ToolkitHelper", "Sources/PowerCore"),
            ("Foundation", "IOKit", "Security"),
        ),
        Target(
            "MacHelmServiceRunner",
            BUNDLE_PREFIX + ".ServiceRunner",
            "MacHelmServiceRunner/Info.plist",
            swift_files("Sources/MacHelmServiceRunner", "Sources/StartupServicesCore"),
            ("CryptoKit", "Foundation", "ServiceManagement"),
        ),
    ]


RESOURCES = (
    ("MacHelm/Assets.xcassets", "folder.assetcatalog"),
    ("Storage/cleanup-macos-dev.py", "text.script.python"),
    ("ThirdPartyNotices.txt", "text"),
    ("LICENSE", "text"),
)
DAEMONS = (
    "FanControlHelper/io.github.sergkhl.MacHelm.FanControlHelper.plist",
    "ToolkitHelper/io.github.sergkhl.MacHelm.ToolkitHelper.plist",
)


def project_document(specs: list[Target]) -> str:
    objects: dict[Reference, dict] = {}

    def add(key: str, kind: str, **fields: object) -> Reference:
        object_id = identifier(key)
        assert object_id not in objects, key
        objects[object_id] = {"isa": kind, **fields}
        return object_id

    project_id = identifier("project")
    target_ids = {spec.name: identifier("target:" + spec.name) for spec in specs}
    file_ids: dict[str, Reference] = {}

    def file(path: str, file_type: str) -> Reference:
        if path not in file_ids:
            file_ids[path] = add(
                "file:" + path, "PBXFileReference",
                lastKnownFileType=file_type, name=Path(path).name,
                path=path, sourceTree="SOURCE_ROOT",
            )
        return file_ids[path]

    for spec in specs:
        for path in spec.sources:
            file(path, "sourcecode.swift")
        file(spec.info_path, "text.plist.xml")
    for path, file_type in RESOURCES:
        file(path, file_type)
    for path in DAEMONS:
        file(path, "text.plist.xml")

    framework_ids = {
        name: add(
            "framework:" + name, "PBXFileReference",
            lastKnownFileType="wrapper.framework", name=name + ".framework",
            path="System/Library/Frameworks/" + name + ".framework",
            sourceTree="SDKROOT",
        )
        for name in sorted({name for spec in specs for name in spec.frameworks})
    }
    product_ids = {
        spec.name: add(
            "product:" + spec.name, "PBXFileReference",
            explicitFileType="wrapper.application" if spec.app else "compiled.mach-o.executable",
            includeInIndex=0, path=spec.name + (".app" if spec.app else ""),
            sourceTree="BUILT_PRODUCTS_DIR",
        )
        for spec in specs
    }

    def build_file(target: str, phase: str, path: str, reference: Reference,
                   signed: bool = False) -> Reference:
        fields: dict[str, object] = {"fileRef": reference}
        if signed:
            fields["settings"] = {"ATTRIBUTES": ["CodeSignOnCopy"]}
        return add(f"build:{target}:{phase}:{path}", "PBXBuildFile", **fields)

    def phase(target: str, phase_name: str, kind: str,
              entries: list[Reference], **fields: object) -> Reference:
        return add(
            f"phase:{target}:{phase_name}", kind,
            buildActionMask=2147483647, files=entries,
            runOnlyForDeploymentPostprocessing=0, **fields,
        )

    def configurations(owner: str, target: Target | None = None) -> Reference:
        config_ids = []
        for mode in ("Debug", "Release"):
            if target is None:
                settings: dict[str, object] = {
                    "ALWAYS_SEARCH_USER_PATHS": "NO",
                    "CLANG_ENABLE_MODULES": "YES",
                    "CLANG_ENABLE_OBJC_ARC": "YES",
                    "ENABLE_USER_SCRIPT_SANDBOXING": "YES",
                    "MACOSX_DEPLOYMENT_TARGET": "26.0",
                    "SDKROOT": "macosx",
                    "SUPPORTED_PLATFORMS": "macosx",
                    "SWIFT_VERSION": "5.0",
                }
                if mode == "Debug":
                    settings.update(
                        DEBUG_INFORMATION_FORMAT="dwarf",
                        ENABLE_TESTABILITY="YES",
                        GCC_OPTIMIZATION_LEVEL="0",
                        GCC_PREPROCESSOR_DEFINITIONS=["$(inherited)", "DEBUG=1"],
                        ONLY_ACTIVE_ARCH="YES",
                        SWIFT_ACTIVE_COMPILATION_CONDITIONS="$(inherited) DEBUG",
                        SWIFT_OPTIMIZATION_LEVEL="-Onone",
                    )
                else:
                    settings.update(
                        DEBUG_INFORMATION_FORMAT="dwarf-with-dsym",
                        GCC_OPTIMIZATION_LEVEL="s",
                        ONLY_ACTIVE_ARCH="NO",
                        SWIFT_ACTIVE_COMPILATION_CONDITIONS="$(inherited)",
                        SWIFT_COMPILATION_MODE="wholemodule",
                        SWIFT_OPTIMIZATION_LEVEL="-O",
                    )
            else:
                settings = {
                    "CODE_SIGN_IDENTITY": "Apple Development",
                    "CODE_SIGN_STYLE": "Manual",
                    "CURRENT_PROJECT_VERSION": BUILD,
                    "DEAD_CODE_STRIPPING": "YES",
                    "ENABLE_APP_SANDBOX": "NO",
                    "ENABLE_HARDENED_RUNTIME": "YES",
                    "GENERATE_INFOPLIST_FILE": "NO",
                    "INFOPLIST_FILE": target.info_path,
                    "MARKETING_VERSION": VERSION,
                    "PRODUCT_BUNDLE_IDENTIFIER": target.bundle_id,
                    "PRODUCT_NAME": target.name,
                    "SWIFT_VERSION": "5.0",
                }
                if target.app:
                    settings.update(
                        ASSETCATALOG_COMPILER_APPICON_NAME="AppIcon",
                        CODE_SIGN_ENTITLEMENTS=APP_ENTITLEMENTS,
                        COMBINE_HIDPI_IMAGES="YES",
                        INSTALL_PATH="$(LOCAL_APPS_DIR)",
                        LD_RUNPATH_SEARCH_PATHS=["$(inherited)", "@executable_path/../Frameworks"],
                        SKIP_INSTALL="NO",
                        SWIFT_EMIT_LOC_STRINGS="YES",
                    )
                else:
                    settings.update(
                        CREATE_INFOPLIST_SECTION_IN_BINARY="YES",
                        INSTALL_PATH="/usr/local/bin",
                        MACH_O_TYPE="mh_execute",
                        SKIP_INSTALL="YES",
                    )
            config_ids.append(add(
                f"config:{owner}:{mode}", "XCBuildConfiguration",
                buildSettings=settings, name=mode,
            ))
        return add(
            "config-list:" + owner, "XCConfigurationList",
            buildConfigurations=config_ids, defaultConfigurationIsVisible=0,
            defaultConfigurationName="Release",
        )

    for spec in specs:
        phases = [
            phase(
                spec.name, "sources", "PBXSourcesBuildPhase",
                [build_file(spec.name, "sources", path, file_ids[path]) for path in spec.sources],
            ),
            phase(
                spec.name, "frameworks", "PBXFrameworksBuildPhase",
                [build_file(spec.name, "frameworks", name, framework_ids[name]) for name in spec.frameworks],
            ),
        ]
        dependencies = []
        if spec.app:
            phases.extend([
                phase(
                    spec.name, "resources", "PBXResourcesBuildPhase",
                    [build_file(spec.name, "resources", path, file_ids[path]) for path, _ in RESOURCES],
                ),
                phase(
                    spec.name, "tools", "PBXCopyFilesBuildPhase",
                    [build_file(spec.name, "tools", other.name, product_ids[other.name], signed=True)
                     for other in specs if not other.app],
                    dstPath="Contents/Library/HelperTools", dstSubfolderSpec=1,
                    name="Embed Helper Tools",
                ),
                phase(
                    spec.name, "daemons", "PBXCopyFilesBuildPhase",
                    [build_file(spec.name, "daemons", path, file_ids[path]) for path in DAEMONS],
                    dstPath="Contents/Library/LaunchDaemons", dstSubfolderSpec=1,
                    name="Embed LaunchDaemons",
                ),
            ])
            for other in specs:
                if other.app:
                    continue
                proxy = add(
                    "proxy:" + other.name, "PBXContainerItemProxy",
                    containerPortal=project_id, proxyType=1,
                    remoteGlobalIDString=target_ids[other.name], remoteInfo=other.name,
                )
                dependencies.append(add(
                    "dependency:" + other.name, "PBXTargetDependency",
                    target=target_ids[other.name], targetProxy=proxy,
                ))
        add(
            "target:" + spec.name, "PBXNativeTarget",
            buildConfigurationList=configurations(spec.name, spec),
            buildPhases=phases, buildRules=[], dependencies=dependencies,
            name=spec.name, productName=spec.name, productReference=product_ids[spec.name],
            productType="com.apple.product-type.application" if spec.app else "com.apple.product-type.tool",
        )

    grouped: dict[str, list[Reference]] = {}
    for path, reference in sorted(file_ids.items()):
        group = str(Path(path).parent)
        grouped.setdefault("Resources" if group == "." or group == "Storage" else group, []).append(reference)
    source_groups = [
        add("group:" + name, "PBXGroup", children=references, name=name, sourceTree="<group>")
        for name, references in sorted(grouped.items())
    ]
    frameworks = add(
        "group:frameworks", "PBXGroup", children=list(framework_ids.values()),
        name="Frameworks", sourceTree="<group>",
    )
    products = add(
        "group:products", "PBXGroup", children=list(product_ids.values()),
        name="Products", sourceTree="<group>",
    )
    main_group = add(
        "group:main", "PBXGroup",
        children=source_groups + [frameworks, products], sourceTree="<group>",
    )
    add(
        "project", "PBXProject",
        attributes={
            "BuildIndependentTargetsInParallel": 1,
            "LastUpgradeCheck": "2600",
            "TargetAttributes": {
                target_ids[spec.name]: {"CreatedOnToolsVersion": "26.0", "ProvisioningStyle": "Manual"}
                for spec in specs
            },
        },
        buildConfigurationList=configurations("project"),
        compatibilityVersion="Xcode 15.0", developmentRegion="en",
        hasScannedForEncodings=0, knownRegions=["en", "Base"],
        mainGroup=main_group, productRefGroup=products,
        projectDirPath="", projectRoot="",
        targets=[target_ids[spec.name] for spec in specs],
    )
    document = {
        "archiveVersion": 1,
        "classes": {},
        "objectVersion": 60,
        "objects": dict(sorted(objects.items())),
        "rootObject": project_id,
    }
    return "// !$*UTF8*$!\n// Generated by scripts/generate-xcode-project.py.\n" + render(document) + "\n"


def xml_bytes(element: ET.Element) -> bytes:
    ET.indent(element, space="   ")
    return ET.tostring(element, encoding="utf-8", xml_declaration=True) + b"\n"


def scheme_document() -> bytes:
    root = ET.Element("Scheme", LastUpgradeVersion="2600", version="1.7")

    def buildable(parent: ET.Element) -> None:
        ET.SubElement(
            parent, "BuildableReference",
            BuildableIdentifier="primary", BlueprintIdentifier=identifier("target:" + PROJECT_NAME),
            BuildableName="MacHelm.app", BlueprintName=PROJECT_NAME,
            ReferencedContainer="container:MacHelm.xcodeproj",
        )

    action = ET.SubElement(root, "BuildAction", parallelizeBuildables="YES", buildImplicitDependencies="YES")
    entries = ET.SubElement(action, "BuildActionEntries")
    entry = ET.SubElement(
        entries, "BuildActionEntry", buildForTesting="YES", buildForRunning="YES",
        buildForProfiling="YES", buildForArchiving="YES", buildForAnalyzing="YES",
    )
    buildable(entry)
    ET.SubElement(
        root, "TestAction", buildConfiguration="Debug",
        selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB",
        selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB",
        shouldUseLaunchSchemeArgsEnv="YES",
    )
    launch = ET.SubElement(
        root, "LaunchAction", buildConfiguration="Debug",
        selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB",
        selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB",
        launchStyle="0", useCustomWorkingDirectory="NO",
        ignoresPersistentStateOnLaunch="NO", debugDocumentVersioning="YES",
        debugServiceExtension="internal", allowLocationSimulation="YES",
    )
    buildable(ET.SubElement(launch, "BuildableProductRunnable", runnableDebuggingMode="0"))
    profile = ET.SubElement(
        root, "ProfileAction", buildConfiguration="Release",
        shouldUseLaunchSchemeArgsEnv="YES", savedToolIdentifier="",
        useCustomWorkingDirectory="NO", debugDocumentVersioning="YES",
    )
    buildable(ET.SubElement(profile, "BuildableProductRunnable", runnableDebuggingMode="0"))
    ET.SubElement(root, "AnalyzeAction", buildConfiguration="Debug")
    ET.SubElement(root, "ArchiveAction", buildConfiguration="Release", revealArchiveInOrganizer="YES")
    return xml_bytes(root)


def bundle_metadata(spec: Target) -> bytes:
    values: dict[str, object] = {
        "CFBundleDevelopmentRegion": "en",
        "CFBundleExecutable": "$(EXECUTABLE_NAME)",
        "CFBundleIdentifier": "$(PRODUCT_BUNDLE_IDENTIFIER)",
        "CFBundleInfoDictionaryVersion": "6.0",
        "CFBundleName": spec.name,
        "CFBundleShortVersionString": "$(MARKETING_VERSION)",
        "CFBundleVersion": "$(CURRENT_PROJECT_VERSION)",
        "LSMinimumSystemVersion": "$(MACOSX_DEPLOYMENT_TARGET)",
    }
    if spec.app:
        values.update(
            CFBundleDisplayName="MacHelm",
            CFBundlePackageType="APPL",
            LSApplicationCategoryType="public.app-category.utilities",
            NSHighResolutionCapable=True,
            NSPrincipalClass="NSApplication",
            # Storage asks Finder to empty the Trash (ADR 0008); macOS shows this when it asks.
            NSAppleEventsUsageDescription="MacHelm asks Finder to empty the Trash when you choose "
            "it in Storage.",
            # A fan recovery alert stays on screen until dismissed (Z-Q5); the owner can change it.
            NSUserNotificationAlertStyle="alert",
        )
    return plistlib.dumps(values, fmt=plistlib.FMT_XML, sort_keys=True)


def app_entitlements() -> bytes:
    # The hardened runtime refuses Apple events without this, even from a program the app starts.
    values = {"com.apple.security.automation.apple-events": True}
    return plistlib.dumps(values, fmt=plistlib.FMT_XML, sort_keys=True)


def generated_files(specs: list[Target]) -> dict[Path, bytes]:
    workspace = ET.Element("Workspace", version="1.0")
    ET.SubElement(workspace, "FileRef", location="self:")
    outputs = {
        PROJECT_PATH / "project.pbxproj": project_document(specs).encode(),
        PROJECT_PATH / "xcshareddata/xcschemes/MacHelm.xcscheme": scheme_document(),
        PROJECT_PATH / "project.xcworkspace/contents.xcworkspacedata": xml_bytes(workspace),
    }
    outputs.update({Path(spec.info_path): bundle_metadata(spec) for spec in specs})
    outputs[Path(APP_ENTITLEMENTS)] = app_entitlements()
    return outputs


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="Report generated-file drift without writing.")
    parser.add_argument("--list-sources", action="store_true", help="Print each target's included Swift sources.")
    args = parser.parse_args()
    specs = targets()
    outputs = generated_files(specs)
    drift = []
    for relative, data in outputs.items():
        path = ROOT / relative
        if path.exists() and path.read_bytes() == data:
            continue
        drift.append(relative.as_posix())
        if not args.check:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
    if args.check and drift:
        print("Regenerate stale project files:", *drift, sep="\n  ", file=sys.stderr)
        return 1
    for spec in specs:
        print(f"{spec.name}: {len(spec.sources)} Swift sources, {spec.bundle_id}")
        if args.list_sources:
            for path in spec.sources:
                print("  " + path)
    for path, _ in RESOURCES:
        if not (ROOT / path).exists():
            print(f"Resource pending: {path}", file=sys.stderr)
    print("Generated project is current." if args.check else f"Updated {len(drift)} generated files.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
