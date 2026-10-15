#!/usr/bin/env python3
"""Generate a standard, shared-scheme Xcode project without requiring XcodeGen."""
import hashlib
import json
import plistlib
import re
from pathlib import Path
from xml.etree import ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
objects = {}

def uid(name):
    return hashlib.sha256(name.encode()).hexdigest()[:24].upper()

def add(key_name, isa, **values):
    key = uid(key_name)
    objects[key] = {"isa": isa, **values}
    return key

def build(name, settings):
    return add(name, "XCBuildConfiguration", buildSettings=settings, name=name.rsplit("/", 1)[-1])

def configs(name, base, release_extra=None):
    debug = build(name + "/Debug", {**base, "SWIFT_OPTIMIZATION_LEVEL": "-Onone", "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "DEBUG $(inherited)", "ONLY_ACTIVE_ARCH": "YES", "ENABLE_TESTABILITY": "YES"})
    release = build(name + "/Release", {**base, "SWIFT_OPTIMIZATION_LEVEL": "-O", **(release_extra or {})})
    return add(name + "/ConfigList", "XCConfigurationList", buildConfigurations=[debug, release], defaultConfigurationIsVisible="0", defaultConfigurationName="Release")

app_id = uid("AppTarget")
test_id = uid("TestTarget")
app_product = add("AppProduct", "PBXFileReference", explicitFileType="wrapper.application", includeInIndex="0", path="iPadn.app", sourceTree="BUILT_PRODUCTS_DIR")
test_product = add("TestProduct", "PBXFileReference", explicitFileType="wrapper.cfbundle", includeInIndex="0", path="iPadnTests.xctest", sourceTree="BUILT_PRODUCTS_DIR")
app_files, sources = [], []
for path in sorted((ROOT / "iPadn").rglob("*.swift")):
    relative = path.relative_to(ROOT / "iPadn").as_posix()
    reference = add("File/" + relative, "PBXFileReference", lastKnownFileType="sourcecode.swift", path=relative, sourceTree="<group>")
    app_files.append(reference)
    sources.append(add("Build/" + relative, "PBXBuildFile", fileRef=reference))
resources = []
for path, file_type in [("Resources/SAPRuntime", "folder"), ("Resources/Assets.xcassets", "folder.assetcatalog"), ("Resources/PrivacyInfo.xcprivacy", "text.xml"), ("Resources/app-name-directory.json", "text.json")]:
    reference = add("File/" + path, "PBXFileReference", lastKnownFileType=file_type, path=path, sourceTree="<group>")
    app_files.append(reference)
    resources.append(add("Build/" + path, "PBXBuildFile", fileRef=reference))
# Alternate icons also ship as standalone PNGs for SpringBoard and signing tools.
for path in sorted((ROOT / "iPadn/Resources/AlternateIcons").glob("*.png")):
    relative = path.relative_to(ROOT / "iPadn").as_posix()
    reference = add("File/" + relative, "PBXFileReference", lastKnownFileType="image.png", path=relative, sourceTree="<group>")
    app_files.append(reference)
    resources.append(add("Build/" + relative, "PBXBuildFile", fileRef=reference))
app_files.append(add("InfoPlist", "PBXFileReference", lastKnownFileType="text.plist.xml", path="Info.plist", sourceTree="<group>"))
test_files, test_sources = [], []
for path in sorted((ROOT / "iPadnTests").glob("*.swift")):
    reference = add("TestFile/" + path.name, "PBXFileReference", lastKnownFileType="sourcecode.swift", path=path.name, sourceTree="<group>")
    test_files.append(reference)
    test_sources.append(add("TestBuild/" + path.name, "PBXBuildFile", fileRef=reference))
package = add("ZIPFoundation", "XCRemoteSwiftPackageReference", repositoryURL="https://github.com/weichsel/ZIPFoundation.git",
              requirement={"kind": "exactVersion", "version": "0.9.19"})
app_package = add("ZIPFoundation/App", "XCSwiftPackageProductDependency", package=package, productName="ZIPFoundation")
test_package = add("ZIPFoundation/Tests", "XCSwiftPackageProductDependency", package=package, productName="ZIPFoundation")
app_framework = add("ZIPFoundation/AppBuild", "PBXBuildFile", productRef=app_package)
test_framework = add("ZIPFoundation/TestBuild", "PBXBuildFile", productRef=test_package)
app_group = add("AppGroup", "PBXGroup", children=app_files, path="iPadn", sourceTree="<group>")
test_group = add("TestGroup", "PBXGroup", children=test_files, path="iPadnTests", sourceTree="<group>")
products = add("Products", "PBXGroup", children=[app_product, test_product], name="Products", sourceTree="<group>")
root_group = add("MainGroup", "PBXGroup", children=[app_group, test_group, products], sourceTree="<group>")
app_sources = add("AppSources", "PBXSourcesBuildPhase", buildActionMask="2147483647", files=sources, runOnlyForDeploymentPostprocessing="0")
app_resources = add("AppResources", "PBXResourcesBuildPhase", buildActionMask="2147483647", files=resources, runOnlyForDeploymentPostprocessing="0")
app_frameworks = add("AppFrameworks", "PBXFrameworksBuildPhase", buildActionMask="2147483647", files=[app_framework], runOnlyForDeploymentPostprocessing="0")
assemble = add("AssembleWASM", "PBXShellScriptBuildPhase", buildActionMask="2147483647", files=[],
               inputPaths=["$(SRCROOT)/scripts/assemble_runtime.py", "$(SRCROOT)/vendor/SAPRuntime"],
               outputPaths=["$(SRCROOT)/iPadn/Resources/SAPRuntime/" + name for name in ["sap.wasm", "index.html", "sap-signer.js", "wasm_exec.js", "unicorn_x86.js"]],
               name="Verify local signing runtime", runOnlyForDeploymentPostprocessing="0", shellPath="/bin/bash",
               shellScript='set -euo pipefail\npython3 "$SRCROOT/scripts/assemble_runtime.py"\n', alwaysOutOfDate="1")
tests_sources = add("TestsSources", "PBXSourcesBuildPhase", buildActionMask="2147483647", files=test_sources, runOnlyForDeploymentPostprocessing="0")
tests_frameworks = add("TestsFrameworks", "PBXFrameworksBuildPhase", buildActionMask="2147483647", files=[test_framework], runOnlyForDeploymentPostprocessing="0")
test_resources = []
for path in sorted((ROOT / "iPadnTests/Fixtures").glob("*.p12")):
    relative = path.relative_to(ROOT / "iPadnTests").as_posix()
    reference = add("TestFile/" + relative, "PBXFileReference", lastKnownFileType="file", path=relative, sourceTree="<group>")
    objects[test_group]["children"].append(reference)
    test_resources.append(add("TestBuild/" + relative, "PBXBuildFile", fileRef=reference))
tests_resources = add("TestsResources", "PBXResourcesBuildPhase", buildActionMask="2147483647", files=test_resources, runOnlyForDeploymentPostprocessing="0")
base = {"IPHONEOS_DEPLOYMENT_TARGET": "17.0", "SDKROOT": "iphoneos", "SWIFT_VERSION": "5.0",
        "CLANG_ENABLE_MODULES": "YES", "CLANG_ENABLE_OBJC_ARC": "YES", "ENABLE_STRICT_OBJC_MSGSEND": "YES",
        "GCC_C_LANGUAGE_STANDARD": "gnu17", "CLANG_CXX_LANGUAGE_STANDARD": "gnu++20",
        "SWIFT_STRICT_CONCURRENCY": "targeted", "ENABLE_USER_SCRIPT_SANDBOXING": "YES"}
project_configs = configs("Project", base, {"SWIFT_COMPILATION_MODE": "wholemodule", "VALIDATE_PRODUCT": "YES"})
app_settings = {"PRODUCT_BUNDLE_IDENTIFIER": "app.local.iPadn", "PRODUCT_NAME": "$(TARGET_NAME)", "CODE_SIGN_STYLE": "Automatic",
                "DEVELOPMENT_TEAM": "", "TARGETED_DEVICE_FAMILY": "1,2", "INFOPLIST_FILE": "iPadn/Info.plist",
                "GENERATE_INFOPLIST_FILE": "NO", "MARKETING_VERSION": "1.6.0", "CURRENT_PROJECT_VERSION": "15",
                "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
                "ASSETCATALOG_COMPILER_INCLUDE_ALL_APPICON_ASSETS": "YES", "ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME": "AccentColor",
                "LD_RUNPATH_SEARCH_PATHS": ["$(inherited)", "@executable_path/Frameworks"],
                "ENABLE_PREVIEWS": "YES", "SUPPORTS_MACCATALYST": "NO", "SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD": "NO",
                "ENABLE_USER_SCRIPT_SANDBOXING": "NO",
                # Empty unless scripts/build_unsigned_ipa.sh built the Mac PKG bridge.
                "IPADN_MACPKG_LDFLAGS": "", "OTHER_LDFLAGS": ["$(inherited)", "$(IPADN_MACPKG_LDFLAGS)"]}
test_settings = {"PRODUCT_BUNDLE_IDENTIFIER": "app.local.iPadnTests", "PRODUCT_NAME": "$(TARGET_NAME)", "CODE_SIGN_STYLE": "Automatic",
                 "DEVELOPMENT_TEAM": "", "TARGETED_DEVICE_FAMILY": "1,2", "GENERATE_INFOPLIST_FILE": "YES",
                 "TEST_HOST": "$(BUILT_PRODUCTS_DIR)/iPadn.app/iPadn", "BUNDLE_LOADER": "$(TEST_HOST)",
                 "LD_RUNPATH_SEARCH_PATHS": ["$(inherited)", "@executable_path/Frameworks", "@loader_path/Frameworks"]}
app_configs = configs("App", app_settings)
test_configs = configs("Tests", test_settings)
proxy = add("TestProxy", "PBXContainerItemProxy", containerPortal=uid("Project"), proxyType="1", remoteGlobalIDString=app_id, remoteInfo="iPadn")
dependency = add("TestDependency", "PBXTargetDependency", target=app_id, targetProxy=proxy)
add("AppTarget", "PBXNativeTarget", buildConfigurationList=app_configs, buildPhases=[assemble, app_sources, app_frameworks, app_resources],
    buildRules=[], dependencies=[], name="iPadn", packageProductDependencies=[app_package], productName="iPadn",
    productReference=app_product, productType="com.apple.product-type.application")
add("TestTarget", "PBXNativeTarget", buildConfigurationList=test_configs, buildPhases=[tests_sources, tests_frameworks, tests_resources],
    buildRules=[], dependencies=[dependency], name="iPadnTests", packageProductDependencies=[test_package], productName="iPadnTests",
    productReference=test_product, productType="com.apple.product-type.bundle.unit-test")
ui_id = uid("UITestTarget")
ui_product = add("UITestProduct", "PBXFileReference", explicitFileType="wrapper.cfbundle", includeInIndex="0", path="iPadnUITests.xctest", sourceTree="BUILT_PRODUCTS_DIR")
ui_file = add("UITestFile", "PBXFileReference", lastKnownFileType="sourcecode.swift", path="InteractionTests.swift", sourceTree="<group>")
ui_group = add("UITestGroup", "PBXGroup", children=[ui_file], path="iPadnUITests", sourceTree="<group>")
objects[root_group]["children"].append(ui_group)
objects[products]["children"].append(ui_product)
ui_build = add("UITestBuild", "PBXBuildFile", fileRef=ui_file)
ui_sources = add("UITestSources", "PBXSourcesBuildPhase", buildActionMask="2147483647", files=[ui_build], runOnlyForDeploymentPostprocessing="0")
ui_settings = {k: v for k, v in test_settings.items() if k not in ["TEST_HOST", "BUNDLE_LOADER"]}
ui_settings.update({"PRODUCT_BUNDLE_IDENTIFIER": "app.local.iPadnUITests", "TEST_TARGET_NAME": "iPadn"})
ui_configs = configs("UITests", ui_settings)
add("UITestTarget", "PBXNativeTarget", buildConfigurationList=ui_configs, buildPhases=[ui_sources], buildRules=[], dependencies=[dependency], name="iPadnUITests", productName="iPadnUITests", productReference=ui_product, productType="com.apple.product-type.bundle.ui-testing")
project_id = add("Project", "PBXProject", attributes={"BuildIndependentTargetsInParallel": "1", "LastUpgradeCheck": "1600",
    "TargetAttributes": {app_id: {"CreatedOnToolsVersion": "16.0"}, test_id: {"CreatedOnToolsVersion": "16.0", "TestTargetID": app_id}}},
    buildConfigurationList=project_configs, compatibilityVersion="Xcode 14.0", developmentRegion="zh-Hans",
    hasScannedForEncodings="0", knownRegions=["zh-Hans", "en", "Base"], mainGroup=root_group, productRefGroup=products,
    projectDirPath="", projectRoot="", targets=[app_id, test_id, ui_id], packageReferences=[package])

def render(value, indent=0):
    tab = "\t" * indent
    if isinstance(value, dict):
        return "{\n" + "".join("\t" * (indent + 1) + render(str(k)) + " = " + render(v, indent + 1) + ";\n" for k, v in value.items()) + tab + "}"
    if isinstance(value, list):
        return "(\n" + "".join("\t" * (indent + 1) + render(v, indent + 1) + ",\n" for v in value) + tab + ")"
    text = str(value)
    return text if re.fullmatch(r"[A-Za-z0-9_.]+", text) else json.dumps(text, ensure_ascii=False)

project = {"archiveVersion": "1", "classes": {}, "objectVersion": "56", "objects": objects, "rootObject": project_id}
directory = ROOT / "iPadn.xcodeproj"
directory.mkdir(exist_ok=True)
(directory / "project.pbxproj").write_text("// !$*UTF8*$!\n" + render(project) + "\n")

scheme = ET.Element("Scheme", LastUpgradeVersion="1600", version="1.3")
build_action = ET.SubElement(scheme, "BuildAction", parallelizeBuildables="YES", buildImplicitDependencies="YES")
entries = ET.SubElement(build_action, "BuildActionEntries")
def buildable(parent, ident, name, product):
    return ET.SubElement(parent, "BuildableReference", BuildableIdentifier="primary", BlueprintIdentifier=ident,
                         BuildableName=product, BlueprintName=name, ReferencedContainer="container:iPadn.xcodeproj")
entry = ET.SubElement(entries, "BuildActionEntry", buildForTesting="YES", buildForRunning="YES", buildForProfiling="YES", buildForArchiving="YES", buildForAnalyzing="YES")
buildable(entry, app_id, "iPadn", "iPadn.app")
tests = ET.SubElement(scheme, "TestAction", buildConfiguration="Debug", selectedDebuggerIdentifier="", selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.PosixSpawn", shouldUseLaunchSchemeArgsEnv="YES")
testable = ET.SubElement(ET.SubElement(tests, "Testables"), "TestableReference", skipped="NO")
buildable(testable, test_id, "iPadnTests", "iPadnTests.xctest")
ui_testable = ET.SubElement(tests.find("Testables"), "TestableReference", skipped="NO")
buildable(ui_testable, ui_id, "iPadnUITests", "iPadnUITests.xctest")
launch = ET.SubElement(scheme, "LaunchAction", buildConfiguration="Debug", selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB", selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB", launchStyle="0", useCustomWorkingDirectory="NO", ignoresPersistentStateOnLaunch="NO", debugDocumentVersioning="YES", debugServiceExtension="internal", allowLocationSimulation="YES")
buildable(ET.SubElement(launch, "BuildableProductRunnable", runnableDebuggingMode="0"), app_id, "iPadn", "iPadn.app")
profile = ET.SubElement(scheme, "ProfileAction", buildConfiguration="Release", shouldUseLaunchSchemeArgsEnv="YES", savedToolIdentifier="", useCustomWorkingDirectory="NO", debugDocumentVersioning="YES")
buildable(ET.SubElement(profile, "BuildableProductRunnable", runnableDebuggingMode="0"), app_id, "iPadn", "iPadn.app")
ET.SubElement(scheme, "AnalyzeAction", buildConfiguration="Debug")
ET.SubElement(scheme, "ArchiveAction", buildConfiguration="Release", revealArchiveInOrganizer="YES")
ET.indent(scheme)
scheme_dir = directory / "xcshareddata/xcschemes"
scheme_dir.mkdir(parents=True, exist_ok=True)
(scheme_dir / "iPadn.xcscheme").write_bytes(ET.tostring(scheme, encoding="utf-8", xml_declaration=True))
workspace = directory / "project.xcworkspace"
workspace.mkdir(exist_ok=True)
(workspace / "contents.xcworkspacedata").write_text('<?xml version="1.0" encoding="UTF-8"?><Workspace version="1.0"><FileRef location="self:"></FileRef></Workspace>\n')

info = {"CFBundleDevelopmentRegion": "$(DEVELOPMENT_LANGUAGE)", "CFBundleExecutable": "$(EXECUTABLE_NAME)",
        "CFBundleIdentifier": "$(PRODUCT_BUNDLE_IDENTIFIER)", "CFBundleInfoDictionaryVersion": "6.0",
        "CFBundleName": "$(PRODUCT_NAME)", "CFBundleDisplayName": "iPadn", "CFBundlePackageType": "APPL",
        "CFBundleShortVersionString": "$(MARKETING_VERSION)", "CFBundleVersion": "$(CURRENT_PROJECT_VERSION)",
        "LSRequiresIPhoneOS": True, "UILaunchScreen": {}, "UIFileSharingEnabled": True, "LSSupportsOpeningDocumentsInPlace": True,
        "UIApplicationSceneManifest": {"UIApplicationSupportsMultipleScenes": False},
        "UISupportedInterfaceOrientations": ["UIInterfaceOrientationPortrait", "UIInterfaceOrientationLandscapeLeft", "UIInterfaceOrientationLandscapeRight"],
        "UISupportedInterfaceOrientations~ipad": ["UIInterfaceOrientationPortrait", "UIInterfaceOrientationPortraitUpsideDown", "UIInterfaceOrientationLandscapeLeft", "UIInterfaceOrientationLandscapeRight"],
        "CFBundleURLTypes": [{"CFBundleURLName": "app.local.iPadn", "CFBundleURLSchemes": ["ipadn"]}],
        "LSApplicationQueriesSchemes": ["itms-services"],
        "UIBackgroundModes": ["fetch"], "BGTaskSchedulerPermittedIdentifiers": ["app.local.iPadn.update-check"],
        "CFBundleIcons": {"CFBundleAlternateIcons": {"AppIconFlat": {"CFBundleIconFiles": ["AppIconFlat60x60"], "UIPrerenderedIcon": False}}},
        "CFBundleIcons~ipad": {"CFBundleAlternateIcons": {"AppIconFlat": {"CFBundleIconFiles": ["AppIconFlat60x60", "AppIconFlat76x76", "AppIconFlat83x83"], "UIPrerenderedIcon": False}}},
        "CFBundleDocumentTypes": [{"CFBundleTypeName": "IPA 安装包", "CFBundleTypeRole": "Viewer", "LSHandlerRank": "Alternate",
                                   "LSItemContentTypes": ["com.apple.itunes.ipa", "public.zip-archive"]}],
        "UTImportedTypeDeclarations": [{"UTTypeIdentifier": "com.apple.itunes.ipa", "UTTypeDescription": "iOS App Archive",
                                        "UTTypeConformsTo": ["public.zip-archive"], "UTTypeTagSpecification": {"public.filename-extension": ["ipa"]}}],
        "NSAppTransportSecurity": {"NSAllowsLocalNetworking": True,
                                    "NSExceptionDomains": {"127.0.0.1": {"NSExceptionAllowsInsecureHTTPLoads": True}}},
        "NSLocalNetworkUsageDescription": "通过本机回环地址加载签名资源和提供安装包文件。"}
(ROOT / "iPadn/Info.plist").write_bytes(plistlib.dumps(info, sort_keys=False))
privacy = {"NSPrivacyTracking": False, "NSPrivacyTrackingDomains": [], "NSPrivacyCollectedDataTypes": [],
           "NSPrivacyAccessedAPITypes": [
               {"NSPrivacyAccessedAPIType": "NSPrivacyAccessedAPICategoryUserDefaults", "NSPrivacyAccessedAPITypeReasons": ["CA92.1"]},
               {"NSPrivacyAccessedAPIType": "NSPrivacyAccessedAPICategoryFileTimestamp", "NSPrivacyAccessedAPITypeReasons": ["C617.1"]}
           ]}
(ROOT / "iPadn/Resources/PrivacyInfo.xcprivacy").write_bytes(plistlib.dumps(privacy, sort_keys=False))
print(f"Generated {directory.name}: {len(sources)} app sources, {len(test_sources)} test source, {len(objects)} project objects")
