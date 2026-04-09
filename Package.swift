// swift-tools-version: 5.9
import PackageDescription

let sharedSwiftSettings: [SwiftSetting] = [
    .enableExperimentalFeature("StrictConcurrency"),
    .unsafeFlags(["-enable-testing"]),
]

let sharedLinkerSettings: [LinkerSetting] = [
    .linkedFramework("CoreWLAN"),
    .linkedFramework("PDFKit"),
    .linkedFramework("UserNotifications"),
    .linkedFramework("ServiceManagement"),
    .linkedFramework("SystemConfiguration"),
    .linkedLibrary("sqlite3"),
]

let package = Package(
    name: "MeOrThem",
    platforms: [.macOS(.v14)],
    targets: [

        // ── Core library: all testable logic, no entry point ──────────────
        .target(
            name: "MeOrThemCore",
            path: "Sources/MeOrThemCore",
            swiftSettings: sharedSwiftSettings,
            linkerSettings: sharedLinkerSettings
        ),

        // ── Main app executable ───────────────────────────────────────────
        .executableTarget(
            name: "MeOrThem",
            dependencies: ["MeOrThemCore"],
            path: "Sources/MeOrThem",
            exclude: [
                "Resources/Info.plist",
                "Resources/MeOrThem.entitlements",
                "Resources/speedtest",
            ],
            resources: [
                .copy("Resources/author.jpg"),
                .copy("Resources/AppIcon.icns"),
            ],
            swiftSettings: sharedSwiftSettings,
            linkerSettings: sharedLinkerSettings
        ),

        // ── Test runner (plain executable — no XCTest / no Xcode needed) ──
        .executableTarget(
            name: "MeOrThemTests",
            dependencies: ["MeOrThemCore"],
            path: "Tests/MeOrThemTests",
            swiftSettings: sharedSwiftSettings,
            linkerSettings: sharedLinkerSettings
        ),
    ]
)
