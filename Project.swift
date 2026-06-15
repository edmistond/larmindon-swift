import ProjectDescription

let appSettings: SettingsDictionary = [
    "MARKETING_VERSION": "0.1.0",
    "CURRENT_PROJECT_VERSION": "1",
    "SWIFT_VERSION": "6.0",
    "PRODUCT_NAME": "Larmindon",
    "ASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS": "YES",
]

let privacyPlist: [String: Plist.Value] = [
    "CFBundleDisplayName": "Larmindon",
    "NSMicrophoneUsageDescription": "Larmindon uses the microphone to generate on-device live captions.",
    "NSSpeechRecognitionUsageDescription": "Larmindon uses Apple Speech APIs to transcribe live microphone audio on device.",
    "UILaunchScreen": .dictionary([:]),
]

let iOSAppTargetSettings: Settings = .settings(
    base: [
        "CODE_SIGN_ENTITLEMENTS": "Entitlements/Larmindon.entitlements",
    ]
)

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
                "Sources/AudioRouting/**",
                "Sources/UI/**",
                "Sources/Debug/**",
            ],
            dependencies: [
                .sdk(name: "AVFAudio", type: .framework),
                .sdk(name: "AVKit", type: .framework),
                .sdk(name: "Speech", type: .framework),
            ]
        ),
        .target(
            name: "Larmindon",
            destinations: [.iPhone, .iPad],
            product: .app,
            bundleId: "com.davidedmiston.larmindon",
            deploymentTargets: .iOS("26.0"),
            infoPlist: .extendingDefault(with: privacyPlist),
            sources: ["Sources/App/**"],
            dependencies: [.target(name: "LarmindonKit")],
            settings: iOSAppTargetSettings
        ),
        .target(
            name: "Larmindon-macOS",
            destinations: [.mac],
            product: .app,
            bundleId: "com.davidedmiston.larmindon",
            deploymentTargets: .macOS("26.0"),
            infoPlist: .extendingDefault(with: privacyPlist),
            sources: ["Sources/App/**"],
            dependencies: [.target(name: "LarmindonKit")]
        ),
        .target(
            name: "CoreTests",
            destinations: [.iPhone, .iPad, .mac],
            product: .unitTests,
            bundleId: "com.davidedmiston.larmindon.coretests",
            deploymentTargets: .multiplatform(iOS: "26.0", macOS: "26.0"),
            infoPlist: .default,
            sources: ["Tests/CoreTests/**"],
            dependencies: [.target(name: "LarmindonKit")]
        ),
    ]
)
