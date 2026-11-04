// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MenuBarMijia",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "MijiaCore", targets: ["MijiaCore"]),
        .executable(name: "MenuBarMijiaApp", targets: ["MenuBarMijiaApp"])
    ],
    dependencies: [
        // UI snapshot tests (#46); baselines are recorded once on CI with SNAPSHOT_RECORD=1.
        .package(url: "https://github.com/pointfreeco/swift-snapshot-testing", from: "1.19.7")
    ],
    targets: [
        .target(
            name: "MijiaCore",
            // Translation tables (#52): `Resources/Localizations/<language>.json`, copied into
            // `MenuBarMijia_MijiaCore.bundle/Contents/Resources/Localizations`. A new language is a
            // new file here — no Swift change, and `L10n.availableLanguages` picks it up.
            resources: [
                .copy("Resources/Localizations"),
                .copy("Resources/fallbackSpecs.json"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .executableTarget(
            name: "MenuBarMijiaApp",
            dependencies: ["MijiaCore"],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "MijiaCoreTests",
            dependencies: ["MijiaCore"],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        // SwiftPM 6 lets a test target import the executable target, so the app's views can be
        // rendered without moving 7,700 lines of SwiftUI into a library (#46).
        .testTarget(
            name: "MenuBarMijiaAppTests",
            dependencies: [
                "MenuBarMijiaApp",
                "MijiaCore",
                .product(name: "SnapshotTesting", package: "swift-snapshot-testing")
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        )
    ]
)
