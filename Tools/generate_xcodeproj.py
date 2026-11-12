#!/usr/bin/env python3
"""Regenerates HCGSentinel.xcodeproj from the files on disk.

The project file is committed, so you only need this after adding, removing or
renaming source files without Xcode:

  python3 Tools/generate_xcodeproj.py

Output is deterministic: identifiers are derived from file paths.
"""
import hashlib
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PROJECT = "HCGSentinel"
APP_DIR, TEST_DIR, PACKAGE = "HCGSentinel", "HCGSentinelTests", "SentinelCore"
# Legacy route (default): runs on the iPhone X with iOS 14.7 and on everything newer.
DEPLOYMENT_TARGET = "14.7"
# Modern route: for an Xcode whose supported deployment range starts above 14.7. Does NOT run on iOS 14.
MODERN_DEPLOYMENT_TARGET = "15.0"
MODERN = f"{PROJECT}Modern"
BUNDLE_ID = "com.hcg.sentinel"


def uid(key):
    return hashlib.md5(f"{PROJECT}:{key}".encode()).hexdigest()[:24].upper()


def quote(value):
    value = str(value)
    if re.fullmatch(r"[A-Za-z0-9_./]+", value):
        return value
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'


def render(value, depth):
    pad = "\t" * depth
    if isinstance(value, dict):
        lines = ["{"]
        for key, item in value.items():
            lines.append(f"{pad}\t{quote(key)} = {render(item, depth + 1)};")
        return "\n".join(lines) + f"\n{pad}}}"
    if isinstance(value, (list, tuple)):
        lines = ["("]
        for item in value:
            lines.append(f"{pad}\t{render(item, depth + 1)},")
        return "\n".join(lines) + f"\n{pad})"
    return quote(value)


objects = {}


def add(key, isa, **fields):
    identifier = uid(key)
    objects[identifier] = {"isa": isa, **fields}
    return identifier


def file_type(path):
    return {".swift": "sourcecode.swift", ".plist": "text.plist.xml", ".xcassets": "folder.assetcatalog"}.get(path.suffix, "text")


def build_group(directory, key):
    """Creates a group mirroring `directory`; returns (group id, [(file ref id, path)])."""
    children, files = [], []
    for entry in sorted(directory.iterdir(), key=lambda p: (p.is_file() and p.suffix != ".xcassets", p.name.lower())):
        if entry.name.startswith("."):
            continue
        relative = entry.relative_to(ROOT).as_posix()
        if entry.is_dir() and entry.suffix != ".xcassets":
            group, nested = build_group(entry, relative)
            children.append(group)
            files.extend(nested)
        else:
            ref = add(f"ref:{relative}", "PBXFileReference", lastKnownFileType=file_type(entry), path=entry.name, sourceTree="<group>")
            children.append(ref)
            files.append((ref, entry))
    return add(f"group:{key}", "PBXGroup", children=children, path=directory.name, sourceTree="<group>"), files


def build_file(ref, path, phase):
    return add(f"build:{phase}:{path.relative_to(ROOT).as_posix()}", "PBXBuildFile", fileRef=ref)


def configurations(key, debug, release):
    ids = [add(f"config:{key}:Debug", "XCBuildConfiguration", buildSettings=debug, name="Debug"),
           add(f"config:{key}:Release", "XCBuildConfiguration", buildSettings=release, name="Release")]
    return add(f"configlist:{key}", "XCConfigurationList", buildConfigurations=ids,
               defaultConfigurationIsVisible=0, defaultConfigurationName="Release")


def main():
    app_group, app_files = build_group(ROOT / APP_DIR, APP_DIR)
    test_group, test_files = build_group(ROOT / TEST_DIR, TEST_DIR)

    package_ref = add("ref:package", "PBXFileReference", lastKnownFileType="wrapper", path=PACKAGE, sourceTree="<group>")
    package_product = add("package-product", "XCSwiftPackageProductDependency", productName=PACKAGE)
    package_build = add("build:package", "PBXBuildFile", productRef=package_product)

    app_product = add("product:app", "PBXFileReference", explicitFileType="wrapper.application",
                      includeInIndex=0, path=f"{PROJECT}.app", sourceTree="BUILT_PRODUCTS_DIR")
    test_product = add("product:tests", "PBXFileReference", explicitFileType="wrapper.cfbundle",
                       includeInIndex=0, path=f"{PROJECT}Tests.xctest", sourceTree="BUILT_PRODUCTS_DIR")
    modern_product = add("product:modern", "PBXFileReference", explicitFileType="wrapper.application",
                         includeInIndex=0, path=f"{PROJECT}.app", sourceTree="BUILT_PRODUCTS_DIR")
    products_group = add("group:Products", "PBXGroup", children=[app_product, modern_product, test_product],
                         name="Products", sourceTree="<group>")
    main_group = add("group:main", "PBXGroup", children=[app_group, test_group, package_ref, products_group], sourceTree="<group>")

    app_sources = add("phase:app:sources", "PBXSourcesBuildPhase", buildActionMask=2147483647,
                      files=[build_file(r, p, "app-src") for r, p in app_files if p.suffix == ".swift"],
                      runOnlyForDeploymentPostprocessing=0)
    app_frameworks = add("phase:app:frameworks", "PBXFrameworksBuildPhase", buildActionMask=2147483647,
                         files=[package_build], runOnlyForDeploymentPostprocessing=0)
    app_resources = add("phase:app:resources", "PBXResourcesBuildPhase", buildActionMask=2147483647,
                        files=[build_file(r, p, "app-res") for r, p in app_files if p.suffix == ".xcassets"],
                        runOnlyForDeploymentPostprocessing=0)
    test_sources = add("phase:tests:sources", "PBXSourcesBuildPhase", buildActionMask=2147483647,
                       files=[build_file(r, p, "test-src") for r, p in test_files if p.suffix == ".swift"],
                       runOnlyForDeploymentPostprocessing=0)
    test_frameworks = add("phase:tests:frameworks", "PBXFrameworksBuildPhase", buildActionMask=2147483647,
                          files=[], runOnlyForDeploymentPostprocessing=0)

    common = {
        "ALWAYS_SEARCH_USER_PATHS": "NO",
        "CLANG_ANALYZER_NONNULL": "YES",
        "CLANG_ENABLE_MODULES": "YES",
        "CLANG_ENABLE_OBJC_ARC": "YES",
        "CLANG_WARN_BOOL_CONVERSION": "YES",
        "CLANG_WARN_EMPTY_BODY": "YES",
        "CLANG_WARN_ENUM_CONVERSION": "YES",
        "CLANG_WARN_INT_CONVERSION": "YES",
        "CLANG_WARN_UNREACHABLE_CODE": "YES",
        "COPY_PHASE_STRIP": "NO",
        "ENABLE_STRICT_OBJC_MSGSEND": "YES",
        "ENABLE_USER_SCRIPT_SANDBOXING": "YES",
        "GCC_NO_COMMON_BLOCKS": "YES",
        "GCC_WARN_UNUSED_VARIABLE": "YES",
        "IPHONEOS_DEPLOYMENT_TARGET": DEPLOYMENT_TARGET,
        "SDKROOT": "iphoneos",
        "SWIFT_VERSION": "5.0",
        "TARGETED_DEVICE_FAMILY": "1,2",
    }
    project_configs = configurations(
        "project",
        {**common, "DEBUG_INFORMATION_FORMAT": "dwarf", "ENABLE_TESTABILITY": "YES", "GCC_DYNAMIC_NO_PIC": "NO",
         "GCC_OPTIMIZATION_LEVEL": 0, "GCC_PREPROCESSOR_DEFINITIONS": ["DEBUG=1", "$(inherited)"],
         "ONLY_ACTIVE_ARCH": "YES", "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "DEBUG", "SWIFT_OPTIMIZATION_LEVEL": "-Onone"},
        {**common, "DEBUG_INFORMATION_FORMAT": "dwarf-with-dsym", "ENABLE_NS_ASSERTIONS": "NO",
         "SWIFT_COMPILATION_MODE": "wholemodule", "SWIFT_OPTIMIZATION_LEVEL": "-O", "VALIDATE_PRODUCT": "YES"})

    app_settings = {
        "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
        "ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME": "AccentColor",
        "CODE_SIGN_STYLE": "Automatic",
        "CURRENT_PROJECT_VERSION": 1,
        "DEVELOPMENT_TEAM": "",
        "GENERATE_INFOPLIST_FILE": "NO",
        "INFOPLIST_FILE": f"{APP_DIR}/Resources/Info.plist",
        "LD_RUNPATH_SEARCH_PATHS": ["$(inherited)", "@executable_path/Frameworks"],
        "MARKETING_VERSION": "0.1.0",
        "PRODUCT_BUNDLE_IDENTIFIER": BUNDLE_ID,
        "PRODUCT_NAME": PROJECT,
        "SUPPORTS_MACCATALYST": "NO",
        "SWIFT_EMIT_LOC_STRINGS": "NO",
    }
    app_configs = configurations("app", dict(app_settings), dict(app_settings))

    # The modern target is the same app (same sources, resources, Info.plist, bundle identifier and product
    # name). Only its deployment target differs. It exists as a target, not a build configuration, so that
    # tools which always pass "-configuration Release" (HCG Executable Maker) can select it by scheme.
    modern_settings = {**app_settings, "IPHONEOS_DEPLOYMENT_TARGET": MODERN_DEPLOYMENT_TARGET}
    modern_configs = configurations("modern", dict(modern_settings), dict(modern_settings))
    modern_package_product = add("package-product:modern", "XCSwiftPackageProductDependency", productName=PACKAGE)
    modern_sources = add("phase:modern:sources", "PBXSourcesBuildPhase", buildActionMask=2147483647,
                         files=[build_file(r, p, "modern-src") for r, p in app_files if p.suffix == ".swift"],
                         runOnlyForDeploymentPostprocessing=0)
    modern_frameworks = add("phase:modern:frameworks", "PBXFrameworksBuildPhase", buildActionMask=2147483647,
                            files=[add("build:package:modern", "PBXBuildFile", productRef=modern_package_product)],
                            runOnlyForDeploymentPostprocessing=0)
    modern_resources = add("phase:modern:resources", "PBXResourcesBuildPhase", buildActionMask=2147483647,
                           files=[build_file(r, p, "modern-res") for r, p in app_files if p.suffix == ".xcassets"],
                           runOnlyForDeploymentPostprocessing=0)

    test_settings = {
        "BUNDLE_LOADER": "$(TEST_HOST)",
        "CODE_SIGN_STYLE": "Automatic",
        "CURRENT_PROJECT_VERSION": 1,
        "DEVELOPMENT_TEAM": "",
        "GENERATE_INFOPLIST_FILE": "YES",
        "LD_RUNPATH_SEARCH_PATHS": ["$(inherited)", "@executable_path/Frameworks", "@loader_path/Frameworks"],
        "MARKETING_VERSION": "0.1.0",
        "PRODUCT_BUNDLE_IDENTIFIER": f"{BUNDLE_ID}.tests",
        "PRODUCT_NAME": "$(TARGET_NAME)",
        "TEST_HOST": f"$(BUILT_PRODUCTS_DIR)/{PROJECT}.app/{PROJECT}",
    }
    test_configs = configurations("tests", dict(test_settings), dict(test_settings))

    project_id = uid("project")
    app_target = add("target:app", "PBXNativeTarget", buildConfigurationList=app_configs,
                     buildPhases=[app_sources, app_frameworks, app_resources], buildRules=[], dependencies=[],
                     name=PROJECT, packageProductDependencies=[package_product], productName=PROJECT,
                     productReference=app_product, productType="com.apple.product-type.application")
    modern_target = add("target:modern", "PBXNativeTarget", buildConfigurationList=modern_configs,
                        buildPhases=[modern_sources, modern_frameworks, modern_resources], buildRules=[], dependencies=[],
                        name=MODERN, packageProductDependencies=[modern_package_product], productName=MODERN,
                        productReference=modern_product, productType="com.apple.product-type.application")
    proxy = add("proxy:tests->app", "PBXContainerItemProxy", containerPortal=project_id, proxyType=1,
                remoteGlobalIDString=app_target, remoteInfo=PROJECT)
    dependency = add("dependency:tests->app", "PBXTargetDependency", target=app_target, targetProxy=proxy)
    test_target = add("target:tests", "PBXNativeTarget", buildConfigurationList=test_configs,
                      buildPhases=[test_sources, test_frameworks], buildRules=[], dependencies=[dependency],
                      name=f"{PROJECT}Tests", productName=f"{PROJECT}Tests", productReference=test_product,
                      productType="com.apple.product-type.bundle.unit-test")

    objects[project_id] = {
        "isa": "PBXProject",
        "attributes": {"BuildIndependentTargetsInParallel": 1, "LastSwiftUpdateCheck": 1500, "LastUpgradeCheck": 1500,
                       "TargetAttributes": {app_target: {"CreatedOnToolsVersion": "15.0"},
                                            modern_target: {"CreatedOnToolsVersion": "15.0"},
                                            test_target: {"CreatedOnToolsVersion": "15.0", "TestTargetID": app_target}}},
        "buildConfigurationList": project_configs,
        "compatibilityVersion": "Xcode 13.0",
        "developmentRegion": "en",
        "hasScannedForEncodings": 0,
        "knownRegions": ["en", "Base"],
        "mainGroup": main_group,
        "productRefGroup": products_group,
        "projectDirPath": "",
        "projectRoot": "",
        "targets": [app_target, modern_target, test_target],
    }

    document = {"archiveVersion": 1, "classes": {}, "objectVersion": 54,
                "objects": dict(sorted(objects.items(), key=lambda item: (item[1]["isa"], item[0]))),
                "rootObject": project_id}
    project_dir = ROOT / f"{PROJECT}.xcodeproj"
    (project_dir / "xcshareddata/xcschemes").mkdir(parents=True, exist_ok=True)
    (project_dir / "project.pbxproj").write_text("// !$*UTF8*$!\n" + render(document, 0) + "\n")
    schemes = project_dir / "xcshareddata/xcschemes"
    (schemes / f"{PROJECT}.xcscheme").write_text(scheme(app_target, PROJECT, test_target))
    (schemes / f"{MODERN}.xcscheme").write_text(scheme(modern_target, MODERN, None))
    print(f"wrote {project_dir.name}: {len(app_files)} app files, {len(test_files)} test files, {len(objects)} objects")


def scheme(app_target, app_name, test_target):
    def reference(identifier, buildable, name, container=f"container:{PROJECT}.xcodeproj"):
        return (f'<BuildableReference\n               BuildableIdentifier = "primary"\n'
                f'               BlueprintIdentifier = "{identifier}"\n               BuildableName = "{buildable}"\n'
                f'               BlueprintName = "{name}"\n               ReferencedContainer = "{container}">\n'
                f'            </BuildableReference>')

    app = reference(app_target, f"{PROJECT}.app", app_name)
    testables = ""
    if test_target is not None:
        tests = reference(test_target, f"{PROJECT}Tests.xctest", f"{PROJECT}Tests")
        core = reference(f"{PACKAGE}Tests", f"{PACKAGE}Tests", f"{PACKAGE}Tests", f"container:{PACKAGE}")
        testables = f"""
         <TestableReference
            skipped = "NO">
            {tests}
         </TestableReference>
         <TestableReference
            skipped = "NO">
            {core}
         </TestableReference>"""
    return f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme
   LastUpgradeVersion = "1500"
   version = "1.7">
   <BuildAction
      parallelizeBuildables = "YES"
      buildImplicitDependencies = "YES">
      <BuildActionEntries>
         <BuildActionEntry
            buildForTesting = "YES"
            buildForRunning = "YES"
            buildForProfiling = "YES"
            buildForArchiving = "YES"
            buildForAnalyzing = "YES">
            {app}
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      shouldUseLaunchSchemeArgsEnv = "YES">
      <Testables>{testables}
      </Testables>
   </TestAction>
   <LaunchAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      launchStyle = "0"
      useCustomWorkingDirectory = "NO"
      ignoresPersistentStateOnLaunch = "NO"
      debugDocumentVersioning = "YES"
      debugServiceExtension = "internal"
      allowLocationSimulation = "YES">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
         {app}
      </BuildableProductRunnable>
   </LaunchAction>
   <ProfileAction
      buildConfiguration = "Release"
      shouldUseLaunchSchemeArgsEnv = "YES"
      savedToolIdentifier = ""
      useCustomWorkingDirectory = "NO"
      debugDocumentVersioning = "YES">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
         {app}
      </BuildableProductRunnable>
   </ProfileAction>
   <AnalyzeAction
      buildConfiguration = "Debug">
   </AnalyzeAction>
   <ArchiveAction
      buildConfiguration = "Release"
      revealArchiveInOrganizer = "YES">
   </ArchiveAction>
</Scheme>
'''


if __name__ == "__main__":
    main()
