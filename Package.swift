// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Striple",
    platforms: [.macOS(.v13)],
    products: [
        // The app binary is "StripleApp" because "Striple" and "striple" collide on case-insensitive APFS.
        .executable(name: "StripleApp", targets: ["StripleApp"]),
        .executable(name: "striple", targets: ["striple-cli"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.0"),
    ],
    targets: [
        .target(name: "StripleCore"),
        .target(
            name: "StripleEngine",
            dependencies: ["StripleCore"],
            linkerSettings: [
                .linkedFramework("ApplicationServices"),
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("QuartzCore"),
            ]
        ),
        .executableTarget(
            name: "StripleApp",
            dependencies: [
                "StripleCore",
                "StripleEngine",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            linkerSettings: [.linkedFramework("ServiceManagement")]
        ),
        .executableTarget(name: "striple-cli", dependencies: ["StripleCore"]),
        // Live E2E test (`make e2e`, docs/E2E.md). Not part of `swift test`: it moves real windows.
        .target(name: "StripleE2EKit"),
        .executableTarget(name: "striple-e2e", dependencies: ["StripleE2EKit", "StripleCore"]),
        .executableTarget(name: "striple-e2e-windows", dependencies: ["StripleE2EKit"]),
        .testTarget(name: "StripleCoreTests", dependencies: ["StripleCore"]),
        .testTarget(name: "StripleEngineTests", dependencies: ["StripleEngine", "StripleCore"]),
        // Tests the pure rules inside the app (recorder, URL routes, login, single instance).
        .testTarget(name: "StripleAppTests", dependencies: ["StripleApp", "StripleEngine", "StripleCore"]),
        .testTarget(name: "StripleE2EKitTests", dependencies: ["StripleE2EKit"]),
    ],
    swiftLanguageModes: [.v5]
)
