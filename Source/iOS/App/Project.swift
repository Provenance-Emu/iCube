import ProjectDescription

// The Live Activity appex is described as a faithful target (GameActivity.swift EXCLUDED,
// mirroring the original pbxproj membershipException) and gets its own scheme, BUT it is
// NOT embedded into / depended on by the app — the original pbxproj had no iCube->appex
// PBXTargetDependency or embed phase either (plan risk #9). Keeping the embed OFF means the
// `iCube (AppStore)` app scheme builds without touching the appex, so the app gate stays green.
//
// Known latent issue (pre-existing, surfaced not fixed): the appex's Live_ActivityLiveActivity.swift
// references GameActivityAttributes, defined ONLY in GameActivity.swift — which the original
// EXCLUDES from the appex. So the appex is not standalone-buildable as configured upstream.
// Set APP_EMBEDS_APPEX = true only after deciding how the appex should resolve GameActivityAttributes.
let APP_EMBEDS_APPEX = false

// MARK: - Project-level base settings
//
// These flags live in the COMMON XCBuildConfiguration block of the original
// hand-maintained pbxproj — NOT in any xcconfig. They MUST be carried explicitly
// or the C++/ObjC++ bridge files (which #include Dolphin core headers) won't
// compile. Verified against `xcodebuild -showBuildSettings` of the original
// "Release (AppStore)" config: c++20 + libc++.
let projectBase: SettingsDictionary = [
    "CLANG_CXX_LANGUAGE_STANDARD": "c++20",
    "CLANG_CXX_LIBRARY": "libc++",
    "ENABLE_BITCODE": "NO",
    "EXCLUDED_ARCHS": "i386 armv7 x86_64",
    "GCC_C_LANGUAGE_STANDARD": "gnu11",
    "CLANG_ENABLE_MODULES": "YES",
    "CLANG_ENABLE_OBJC_ARC": "YES",
    "CLANG_ENABLE_OBJC_WEAK": "YES",
    "MTL_FAST_MATH": "YES",
]

// MARK: - Configurations
//
// Per the plan: PRODUCT_BUNDLE_IDENTIFIER and CODE_SIGN_ENTITLEMENTS must be set
// per-Configuration here (target-config level), not via Target.bundleId/entitlements,
// because Tuist's single-valued target params emit a target-level setting that
// outranks the [config=...] conditionals in BundleIdentifier.xcconfig.
let dfEnt = "DolphiniOS/DolphiniOS.entitlements"
let appStoreEnt = "DolphiniOS/iCube AppStore.entitlements"

func appCfg(_ name: String, debug: Bool, bundleId: String, entitlements: String) -> Configuration {
    let xc: Path = "Project/Config/Presets/\(name).xcconfig"
    let settings: SettingsDictionary = [
        "PRODUCT_BUNDLE_IDENTIFIER": .string(bundleId),
        "CODE_SIGN_ENTITLEMENTS": .string(entitlements),
    ]
    return debug
        ? .debug(name: .configuration(name), settings: settings, xcconfig: xc)
        : .release(name: .configuration(name), settings: settings, xcconfig: xc)
}

let appConfigs: [Configuration] = [
    appCfg("Debug (Non-Jailbroken)",         debug: true,  bundleId: "com.joemattiello.iCube-debug",             entitlements: dfEnt),
    appCfg("Debug (Jailbroken)",             debug: true,  bundleId: "com.joemattiello.iCube-debug-jb",          entitlements: dfEnt),
    appCfg("Debug (AppStore)",               debug: true,  bundleId: "com.joemattiello.iCube",                   entitlements: appStoreEnt),
    appCfg("Release (Non-Jailbroken)",       debug: false, bundleId: "com.joemattiello.iCube",                   entitlements: dfEnt),
    appCfg("Release (Beta, Non-Jailbroken)", debug: false, bundleId: "com.joemattiello.iCube-njb-patreon-beta",  entitlements: dfEnt),
    appCfg("Release (Jailbroken)",           debug: false, bundleId: "com.joemattiello.iCube-jb",                entitlements: dfEnt),
    appCfg("Release (TrollStore)",           debug: false, bundleId: "com.joemattiello.iCube-ts",                entitlements: dfEnt),
    appCfg("Release (AppStore)",             debug: false, bundleId: "com.joemattiello.iCube",                   entitlements: appStoreEnt),
    appCfg("Release (Beta, Jailbroken)",     debug: false, bundleId: "com.joemattiello.iCube-patreon-beta-jb",   entitlements: dfEnt),
    appCfg("Release (Beta, TrollStore)",     debug: false, bundleId: "com.joemattiello.iCube-ts-patreon-beta",   entitlements: dfEnt),
]

// Project-level configs: reuse the same preset xcconfigs (no per-target settings).
// The project needs the full custom config list or Tuist defaults to Debug/Release
// and the target configs won't have a matching project config to inherit from.
func projCfg(_ name: String, debug: Bool) -> Configuration {
    let xc: Path = "Project/Config/Presets/\(name).xcconfig"
    return debug
        ? .debug(name: .configuration(name), settings: [:], xcconfig: xc)
        : .release(name: .configuration(name), settings: [:], xcconfig: xc)
}

let projectConfigs: [Configuration] = [
    projCfg("Debug (Non-Jailbroken)",         debug: true),
    projCfg("Debug (Jailbroken)",             debug: true),
    projCfg("Debug (AppStore)",               debug: true),
    projCfg("Release (Non-Jailbroken)",       debug: false),
    projCfg("Release (Beta, Non-Jailbroken)", debug: false),
    projCfg("Release (Jailbroken)",           debug: false),
    projCfg("Release (TrollStore)",           debug: false),
    projCfg("Release (AppStore)",             debug: false),
    projCfg("Release (Beta, Jailbroken)",     debug: false),
    projCfg("Release (Beta, TrollStore)",     debug: false),
]

// Appex / tests: don't reuse the app's preset xcconfigs (they carry the app's
// bundle-id logic). Plain named configs so scheme config names line up.
func plainCfg(_ name: String, debug: Bool, settings: SettingsDictionary = [:]) -> Configuration {
    debug ? .debug(name: .configuration(name), settings: settings)
          : .release(name: .configuration(name), settings: settings)
}

// Same 10 config names/debug-ness as the project, no preset xcconfig.
let secondaryConfigs: [Configuration] = [
    plainCfg("Debug (Non-Jailbroken)",         debug: true),
    plainCfg("Debug (Jailbroken)",             debug: true),
    plainCfg("Debug (AppStore)",               debug: true),
    plainCfg("Release (Non-Jailbroken)",       debug: false),
    plainCfg("Release (Beta, Non-Jailbroken)", debug: false),
    plainCfg("Release (Jailbroken)",           debug: false),
    plainCfg("Release (TrollStore)",           debug: false),
    plainCfg("Release (AppStore)",             debug: false),
    plainCfg("Release (Beta, Jailbroken)",     debug: false),
    plainCfg("Release (Beta, TrollStore)",     debug: false),
]

// MARK: - Scripts (pre-compile; core build MUST precede Sources)

let preScripts: [TargetScript] = [
    .pre(
        path: "Project/Scripts/SetUpPython.sh",
        name: "Setup Python",
        basedOnDependencyAnalysis: false
    ),
    .pre(
        script: """
        set -euo pipefail
        SCRIPT="$PROJECT_DIR/../../../BuildiOSXCFramework.py"
        case "${PLATFORM_NAME}" in
          iphoneos)          platform="OS64" ;;
          iphonesimulator)   platform="SIMULATORARM64" ;;
          appletvos)         platform="TVOS" ;;
          appletvsimulator)  platform="SIMULATOR_TVOS" ;;
          macosx)
            if [[ "${SUPPORTS_MACCATALYST:-}" == "YES" || "${EFFECTIVE_PLATFORM_NAME:-}" == "-maccatalyst" ]]; then
              platform="MAC_CATALYST"
            else
              echo "Error: macOS (non-Catalyst) is not supported by this script."; exit 1
            fi ;;
          *) echo "Error: Unsupported PLATFORM_NAME: ${PLATFORM_NAME}"; exit 1 ;;
        esac
        echo "Building PVlibDolphin for platform: ${platform} (CONFIGURATION=${CONFIGURATION})"
        exec /usr/bin/python3 "${SCRIPT}" -p "${platform}" -v
        """,
        name: "Build Dolphin Core",
        outputPaths: [
            "$(SRCROOT)/../../../build/xcframework/PVlibDolphin-ios-sim.framework",
            "$(SRCROOT)/../../../build/xcframework/PVlibDolphin-ios.framework",
            "$(SRCROOT)/../../../build/xcframework/PVlibDolphin-tvos.framework",
            "$(SRCROOT)/../../../build/xcframework/PVlibDolphin-tvos-sim.framework",
        ],
        basedOnDependencyAnalysis: false
    ),
    .pre(
        path: "Project/Scripts/UpdateStoryboardStrings.sh",
        name: "Update Storyboard Strings",
        basedOnDependencyAnalysis: false
    ),
    .pre(
        script: #""$PROJECT_DIR/venv/bin/python3" "$PROJECT_DIR/Project/Scripts/UpdateCoreStrings.py" "$PROJECT_DIR/../../../Languages/po/" "$PROJECT_DIR/Common/UI/Localization""#,
        name: "Update Core Strings",
        inputPaths: ["$(PROJECT_DIR)/../../../Languages/po/en.po"],
        outputPaths: ["$(DERIVED_FILE_DIR)/UpdateCoreStrings_dummy.txt"]
    ),
    .pre(
        script: #""$PROJECT_DIR/venv/bin/python3" "$PROJECT_DIR/Project/Scripts/TransferCoreStringsToStoryboard.py" "$PROJECT_DIR/DolphiniOS" "$PROJECT_DIR/Common/UI/Localization/""#,
        name: "Transfer Core Strings to Storyboard Strings",
        basedOnDependencyAnalysis: false
    ),
]

// MARK: - iCube app target

let iCube = Target.target(
    name: "iCube",
    destinations: [.iPhone, .iPad, .appleTv, .macWithiPadDesign, .macCatalyst],
    product: .app,
    bundleId: "com.joemattiello.iCube", // placeholder; real per-config ids set in appConfigs
    deploymentTargets: .multiplatform(iOS: "17.0", tvOS: "17.0"),
    infoPlist: .file(path: "DolphiniOS/Info.plist"),
    sources: [
        .glob("DolphiniOS/**/*.{swift,m,mm,h}"),
        // NOTE: GameActivity.swift (Common/Swift/Activity) defines GameActivityManager, used by
        // the app (ControllerExtensions, EmulationScreen, PauseMenuView, PauseGestureTracker).
        // In the original pbxproj it is a membershipEXCEPTION on the appex's "Activity" synchronized
        // folder — i.e. EXCLUDED from the appex, kept in the app. So it stays in the app glob.
        .glob("Common/**/*.{swift,m,mm,h}"),
    ],
    resources: [
        "DolphiniOS/Assets.xcassets",
        "Common/Assets.xcassets",
        "Common/DolphinAssets.xcassets",
        "DolphiniOS/**/*.storyboard",
        "DolphiniOS/**/*.xib",
        "DolphiniOS/**/*.strings",
        "DolphiniOS/Base.lproj/**",
        "DolphiniOS/en.lproj/**",
        "DolphiniOS/ja.lproj/**",
        "Project/Assets/DefaultPreferences.plist",
        "Project/Assets/GoogleService-Info.plist",
        "Project/Assets/Logger.ini",
        "Project/Assets/cacert.pem",
        .folderReference(path: "../../../Data/Sys"),
        .folderReference(path: "Project/Assets/compiled_shaders"),
    ],
    entitlements: nil, // per-config via CODE_SIGN_ENTITLEMENTS in appConfigs
    scripts: preScripts,
    dependencies: [
        .xcframework(path: "../../../build/xcframework/PVlibDolphin.xcframework"),
        // MoltenVK (Vulkan-on-Metal ICD) is iOS-only: the prebuilt xcframework has only
        // ios device/simulator slices (no tvOS slice), and the core never builds/links it
        // (CMake gates MoltenVK to APPLE AND NOT IOS, and tvOS is IOS=TRUE in the toolchain).
        // The Vulkan backend dlopen's MoltenVK.framework at runtime — no direct link — so
        // excluding it from tvOS just makes the (unused) Vulkan backend unavailable there;
        // tvOS renders via native Metal. Linking it on tvOS makes Xcode look for a nonexistent
        // tvOS slice and fail. Condition keeps iOS linking byte-for-byte unchanged.
        .xcframework(path: "../../../Externals/MoltenVK-iOS/MoltenVK.xcframework", condition: .when([.ios])),
        .package(product: "PVWebServer"),
        .package(product: "Zip"),
        .package(product: "NavigationStackBackport"),
        .package(product: "UICollectionViewLeftAlignedLayout"),
        .package(product: "AltKit"),
        .package(product: "FirebaseAnalytics"),
        .package(product: "FirebaseCrashlytics"),
        .sdk(name: "ReplayKit", type: .framework),
        .sdk(name: "AVFoundation", type: .framework),
        .sdk(name: "UniformTypeIdentifiers", type: .framework),
        .sdk(name: "MetalKit", type: .framework),
        .sdk(name: "GameController", type: .framework),
        .sdk(name: "CoreMotion", type: .framework),
        // appex embed intentionally OFF (faithful to original; see APP_EMBEDS_APPEX note above).
    ] + (APP_EMBEDS_APPEX ? [.target(name: "LiveActivityExtension")] : []),
    settings: .settings(
        base: projectBase.merging([
            "CODE_SIGN_STYLE": "Automatic",
            "ENABLE_HARDENED_RUNTIME": "YES",
            "ENABLE_STRICT_OBJC_MSGSEND": "NO",
            "ENABLE_USER_SCRIPT_SANDBOXING": "NO",
            "GENERATE_INFOPLIST_FILE": "YES",
            "INFOPLIST_FILE": "DolphiniOS/Info.plist",
            "INFOPLIST_FILE[sdk=appletv*]": "DolphiniOS/Info-TV.plist",
            "INFOPLIST_KEY_GCSupportsControllerUserInteraction": "YES",
            "INFOPLIST_KEY_GCSupportsGameMode": "YES",
            "INFOPLIST_KEY_LSApplicationCategoryType": "public.app-category.games",
            "INFOPLIST_KEY_LSSupportsOpeningDocumentsInPlace": "YES",
            "INFOPLIST_KEY_NSLocalNetworkUsageDescription": "iCube uses your local network to discover and connect to DSU controllers and devices.",
            "INFOPLIST_KEY_NSPhotoLibraryAddUsageDescription": "Used to save gameplay clips you record with Instant Replay.",
            "INFOPLIST_KEY_NSSupportsLiveActivities": "YES",
            "INFOPLIST_KEY_NSSupportsLiveActivitiesFrequentUpdates": "YES",
            "INFOPLIST_KEY_UIApplicationSupportsIndirectInputEvents": "YES",
            "INFOPLIST_KEY_UILaunchStoryboardName": "LaunchScreen",
            "INFOPLIST_KEY_UIMainStoryboardFile": "Main",
            "INFOPLIST_KEY_UIMainStoryboardFile[sdk=appletv*]": "",
            "INFOPLIST_KEY_UISupportedInterfaceOrientations_iPad": "UIInterfaceOrientationPortrait UIInterfaceOrientationPortraitUpsideDown UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight",
            "INFOPLIST_KEY_UISupportedInterfaceOrientations_iPhone": "UIInterfaceOrientationPortrait UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight",
            "LD_RUNPATH_SEARCH_PATHS": ["$(inherited)", "@executable_path/Frameworks"],
            // The bridging header imports basename-only headers (AudioSessionManager.h etc.)
            // scattered across Common/ and DolphiniOS/ subdirs. The original pbxproj resolved
            // these via the target header map built from synchronized-folder .h membership;
            // Tuist's source globs don't populate that map identically, so add the subtrees to
            // the quote-include search path. $(inherited) is load-bearing: it keeps
            // Common.xcconfig's Core/** + Library paths (target base outranks the xcconfig).
            "USER_HEADER_SEARCH_PATHS": ["$(inherited)", "$(SRCROOT)/Common/**", "$(SRCROOT)/DolphiniOS/**"],
            "MARKETING_VERSION": "1.0.0",
            "CURRENT_PROJECT_VERSION": "13",
            "PRODUCT_NAME": "$(TARGET_NAME)",
            "SUPPORTS_MACCATALYST": "YES",
            "SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD": "YES",
            "SWIFT_VERSION": "5.0",
            "SWIFT_OBJC_INTEROP_MODE": "objc",
            "SWIFT_EMIT_LOC_STRINGS": "YES",
            "TARGETED_DEVICE_FAMILY": "1,2,3,6",
            "ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME": "AccentColor",
            "ASSETCATALOG_COMPILER_INCLUDE_ALL_APPICON_ASSETS": "YES",
            "ASSETCATALOG_COMPILER_APPICON_NAME": "$(DOL_APP_ICON_ASSET_NAME)",
            "ASSETCATALOG_COMPILER_APPICON_NAME[sdk=appletv*]": "$(DOL_APP_ICON_ASSET_NAME_TV)",
            // Tuist's .recommended defaults inject ASSETCATALOG_COMPILER_LAUNCHIMAGE_NAME=LaunchImage,
            // but the app uses a LaunchScreen storyboard (no LaunchImage set) — clear it or actool fails.
            "ASSETCATALOG_COMPILER_LAUNCHIMAGE_NAME": "",
        ]),
        configurations: appConfigs,
        defaultSettings: .recommended
    )
)

// MARK: - Live Activity appex

let liveActivity = Target.target(
    name: "LiveActivityExtension",
    destinations: [.iPhone, .iPad, .macCatalyst],
    product: .appExtension,
    bundleId: "com.joemattiello.iCube.Live-Activity",
    deploymentTargets: .multiplatform(iOS: "18.2"),
    infoPlist: .file(path: "Live Activity/Info.plist"),
    sources: [
        .glob("Live Activity/**/*.swift"),
        // NOTE: the original pbxproj EXCLUDES GameActivity.swift from the appex (it's a
        // membershipException), yet Live_ActivityLiveActivity.swift references
        // GameActivityAttributes which is defined there. TODO when re-enabling the appex:
        // confirm how the appex resolves GameActivityAttributes (shared file vs. duplicate) —
        // it may need GameActivity.swift here after all, with the app+appex both compiling it.
    ],
    resources: ["Live Activity/LiveActivityAssets.xcassets"],
    entitlements: .file(path: "Live ActivityExtension.entitlements"),
    dependencies: [
        .sdk(name: "SwiftUI", type: .framework),
        .sdk(name: "WidgetKit", type: .framework),
    ],
    settings: .settings(
        base: [
            "SKIP_INSTALL": "YES",
            "CLANG_CXX_LANGUAGE_STANDARD": "gnu++20",
            "ENABLE_USER_SCRIPT_SANDBOXING": "YES",
            "TARGETED_DEVICE_FAMILY": "1,2",
            "SWIFT_VERSION": "5.0",
            "DEVELOPMENT_TEAM": "S32Z3HMYVQ",
            "ASSETCATALOG_COMPILER_WIDGET_BACKGROUND_COLOR_NAME": "WidgetBackground",
            "ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME": "AccentColor",
            "INFOPLIST_FILE": "Live Activity/Info.plist",
            // The appex must NOT inherit the app's ObjC bridging header (it pulls in
            // AudioSessionManager.h and the whole Dolphin core header tree). GameActivity.swift
            // only needs Foundation + ActivityKit.
            "SWIFT_OBJC_BRIDGING_HEADER": "",
        ],
        configurations: secondaryConfigs
    )
)

// MARK: - Unit tests

let iCubeTests = Target.target(
    name: "iCubeTests",
    destinations: [.iPhone, .iPad],
    product: .unitTests,
    bundleId: "com.joemattiello.iCubeTests",
    deploymentTargets: .multiplatform(iOS: "17.0"),
    infoPlist: .default,
    sources: ["DolphiniOSTests/**/*.swift"],
    dependencies: [.target(name: "iCube")],
    settings: .settings(
        base: ["CLANG_CXX_LANGUAGE_STANDARD": "gnu++17", "SWIFT_VERSION": "5.0"],
        configurations: secondaryConfigs
    )
)

// MARK: - Schemes

let appStoreEnvVars: [String: EnvironmentVariable] = [
    "DOLPHIN_CI_HOT": .environmentVariable(value: "1", isEnabled: true),
    "DOLPHIN_CI_HOT_SAMPLE": .environmentVariable(value: "64", isEnabled: true),
    "DOLPHIN_CI_FP_FAST": .environmentVariable(value: "1", isEnabled: true),
    "CI_ENABLE_INLINE_59": .environmentVariable(value: "1", isEnabled: true),
    "CI_VERIFY_FP": .environmentVariable(value: "1", isEnabled: true),
    "CI_VERIFY_SAMPLE": .environmentVariable(value: "1", isEnabled: true),
    "CI_VERIFY_LOG": .environmentVariable(value: "1", isEnabled: true),
    "DOLPHIN_CI_USE_ID_DISPATCH": .environmentVariable(value: "1", isEnabled: true),
    "DOLPHIN_FORCE_CI": .environmentVariable(value: "1", isEnabled: false),
    "DOLPHIN_CI_LINK_LOG": .environmentVariable(value: "1", isEnabled: false),
    "DOL_JIT_FORCE_RWX": .environmentVariable(value: "1", isEnabled: false),
    "CI_DISABLE_JUMP_CACHE": .environmentVariable(value: "1", isEnabled: false),
    "CI_DISABLE_MICRO_OPS": .environmentVariable(value: "1", isEnabled: false),
    "CI_DISABLE_PIC_LS": .environmentVariable(value: "1", isEnabled: false),
    "DOLPHIN_CI_LINK_ENABLE": .environmentVariable(value: "0", isEnabled: false),
    "DOLPHIN_CI_LINK_SAMPLE": .environmentVariable(value: "1", isEnabled: false),
    "DOLPHIN_CI_LINK_LOG_VERBOSE": .environmentVariable(value: "1", isEnabled: false),
    "DOLPHIN_CI_LINK_SKIP_RANGE": .environmentVariable(value: "0x80160000:0x20000", isEnabled: false),
]

let schemes: [Scheme] = [
    .scheme(
        name: "iCube (AppStore)",
        shared: true,
        buildAction: .buildAction(targets: ["iCube"]),
        testAction: .targets(["iCubeTests"], configuration: .configuration("Debug (AppStore)")),
        runAction: .runAction(
            configuration: .configuration("Release (AppStore)"),
            arguments: .arguments(environmentVariables: appStoreEnvVars)
        ),
        archiveAction: .archiveAction(configuration: .configuration("Release (AppStore)")),
        profileAction: .profileAction(configuration: .configuration("Release (AppStore)")),
        analyzeAction: .analyzeAction(configuration: .configuration("Debug (AppStore)"))
    ),
    .scheme(
        name: "iCube (NJB)",
        shared: true,
        buildAction: .buildAction(targets: ["iCube"]),
        testAction: .targets(["iCubeTests"], configuration: .configuration("Debug (Non-Jailbroken)")),
        runAction: .runAction(configuration: .configuration("Release (Non-Jailbroken)")),
        archiveAction: .archiveAction(configuration: .configuration("Release (Non-Jailbroken)")),
        profileAction: .profileAction(configuration: .configuration("Release (Non-Jailbroken)")),
        analyzeAction: .analyzeAction(configuration: .configuration("Debug (Non-Jailbroken)"))
    ),
    .scheme(
        name: "iCube (JB)",
        shared: true,
        buildAction: .buildAction(targets: ["iCube"]),
        testAction: .targets(["iCubeTests"], configuration: .configuration("Debug (Jailbroken)")),
        runAction: .runAction(configuration: .configuration("Release (Jailbroken)")),
        archiveAction: .archiveAction(configuration: .configuration("Release (Jailbroken)")),
        profileAction: .profileAction(configuration: .configuration("Release (Jailbroken)")),
        analyzeAction: .analyzeAction(configuration: .configuration("Debug (Jailbroken)"))
    ),
    .scheme(
        name: "Live ActivityExtension",
        shared: true,
        buildAction: .buildAction(targets: ["LiveActivityExtension"]),
        runAction: .runAction(configuration: .configuration("Release (Non-Jailbroken)")),
        archiveAction: .archiveAction(configuration: .configuration("Release (Non-Jailbroken)"))
    ),
]

// MARK: - Project

let project = Project(
    name: "iCube",
    options: .options(
        defaultKnownRegions: ["en", "Base", "ja"],
        developmentRegion: "en",
        // The original project does not use Tuist's synthesized resource/string accessors;
        // its .strings files produced invalid Swift (TuistStrings+ICube.swift syntax error).
        disableBundleAccessors: true,
        disableSynthesizedResourceAccessors: true
    ),
    packages: [
        .local(path: "../PVWebServer"),
        .remote(url: "https://github.com/firebase/firebase-ios-sdk", requirement: .upToNextMajor(from: "12.0.0")),
        .remote(url: "https://github.com/marmelroy/Zip.git", requirement: .upToNextMajor(from: "2.1.2")),
        .remote(url: "https://github.com/lm/navigation-stack-backport", requirement: .upToNextMajor(from: "1.1.0")),
        .remote(url: "https://github.com/OatmealDome/UICollectionViewLeftAlignedLayout", requirement: .upToNextMajor(from: "1.0.0")),
        .remote(url: "https://github.com/rileytestut/AltKit.git", requirement: .upToNextMajor(from: "0.0.2")),
    ],
    settings: .settings(
        base: projectBase,
        configurations: projectConfigs,
        defaultSettings: .recommended
    ),
    targets: [iCube, liveActivity, iCubeTests],
    schemes: schemes
)
