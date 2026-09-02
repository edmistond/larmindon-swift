import ProjectDescription

let appSettings: SettingsDictionary = [
    "MARKETING_VERSION": "0.1.0",
    "CURRENT_PROJECT_VERSION": "1",
    "SWIFT_VERSION": "6.0",
    "PRODUCT_NAME": "Larmindon",
    "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
    "ASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS": "YES",
    // Sign every build with the personal-team Apple Development certificate, including
    // Debug runs from Xcode. Ad-hoc signatures make TCC treat each rebuild as a new app
    // and re-prompt for the microphone; a certificate-backed signature is stable.
    "CODE_SIGN_STYLE": "Automatic",
    "DEVELOPMENT_TEAM": "ZKRZM9RTLN",
]

/// Tuist's per-target defaults set `CODE_SIGN_IDENTITY = "-"` (ad hoc) for macOS, which
/// outranks the project-level team above, so the identity has to be set on the targets.
let certificateSigning: SettingsDictionary = [
    "CODE_SIGN_IDENTITY": "Apple Development",
]

let sharedPrivacyPlist: [String: Plist.Value] = [
    "CFBundleDisplayName": "Larmindon",
    "NSMicrophoneUsageDescription": "Larmindon captures microphone audio for live captions. Audio stays on device in On-device mode and is sent to the selected provider only in Server mode.",
    "NSSpeechRecognitionUsageDescription": "Larmindon uses Apple Speech APIs to transcribe live microphone audio on device.",
]

let iOSInfoPlist: [String: Plist.Value] = sharedPrivacyPlist.merging([
    // Captions have to survive switching to another app — the whole point is glancing at
    // something else mid-conversation. Without this the process is suspended a second or
    // two after backgrounding and transcription dies silently. Recording continues under
    // either category `IOSAudioSessionCapturePolicy` selects.
    "UIBackgroundModes": .array([.string("audio")]),
    "UISupportedInterfaceOrientations": .array([
        .string("UIInterfaceOrientationPortrait"),
        .string("UIInterfaceOrientationLandscapeLeft"),
        .string("UIInterfaceOrientationLandscapeRight"),
    ]),
    "UISupportedInterfaceOrientations~ipad": .array([
        .string("UIInterfaceOrientationPortrait"),
        .string("UIInterfaceOrientationPortraitUpsideDown"),
        .string("UIInterfaceOrientationLandscapeLeft"),
        .string("UIInterfaceOrientationLandscapeRight"),
    ]),
    "UILaunchScreen": .dictionary([:]),
]) { _, newValue in newValue }

let macOSInfoPlist: [String: Plist.Value] = sharedPrivacyPlist.merging([
    // Only the App Store needs a category, but xcodebuild warns on every build without one.
    "LSApplicationCategoryType": "public.app-category.utilities",
]) { _, newValue in newValue }

let project = Project(
    name: "Larmindon",
    organizationName: "David Edmiston",
    options: .options(automaticSchemesOptions: .enabled()),
    settings: .settings(base: appSettings),
    targets: [
        .target(
            name: "LarmindonKit",
            destinations: [.iPhone, .iPad, .mac],
            product: .framework,
            bundleId: "com.davidedmiston.larmindon.kit",
            deploymentTargets: .multiplatform(iOS: "26.0", macOS: "26.0"),
            infoPlist: .default,
            sources: [
                "Sources/Core/**",
                "Sources/SpeechPipeline/**",
                "Sources/Networking/**",
                "Sources/AudioRouting/**",
                "Sources/UI/**",
                "Sources/Debug/**",
            ],
            dependencies: [
                .sdk(name: "AVFAudio", type: .framework),
                .sdk(name: "AVKit", type: .framework),
                .sdk(name: "Network", type: .framework),
                .sdk(name: "Security", type: .framework),
                .sdk(name: "Speech", type: .framework),
            ],
            settings: .settings(base: certificateSigning)
        ),
        .target(
            name: "Larmindon",
            destinations: [.iPhone, .iPad],
            product: .app,
            bundleId: "com.davidedmiston.larmindon",
            deploymentTargets: .iOS("26.0"),
            infoPlist: .extendingDefault(with: iOSInfoPlist),
            sources: ["Sources/App/**"],
            resources: ["Resources/**"],
            dependencies: [.target(name: "LarmindonKit")]
        ),
        .target(
            name: "Larmindon-macOS",
            destinations: [.mac],
            product: .app,
            bundleId: "com.davidedmiston.larmindon",
            deploymentTargets: .macOS("26.0"),
            infoPlist: .extendingDefault(with: macOSInfoPlist),
            sources: ["Sources/App/**"],
            resources: ["Resources/**"],
            dependencies: [.target(name: "LarmindonKit")],
            settings: .settings(base: certificateSigning)
        ),
        .target(
            name: "CoreTests",
            destinations: [.iPhone, .iPad, .mac],
            product: .unitTests,
            bundleId: "com.davidedmiston.larmindon.coretests",
            deploymentTargets: .multiplatform(iOS: "26.0", macOS: "26.0"),
            infoPlist: .default,
            sources: ["Tests/CoreTests/**/*.swift"],
            resources: ["Tests/CoreTests/Fixtures/**"],
            dependencies: [.target(name: "LarmindonKit")]
        ),
    ]
)
