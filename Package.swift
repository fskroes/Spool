// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Spool",
    platforms: [.macOS(.v13)],
    products: [
        // The app binary is "SpoolApp" because "Spool" and "spool" collide on case-insensitive APFS.
        .executable(name: "SpoolApp", targets: ["SpoolApp"]),
        .executable(name: "spool", targets: ["spool-cli"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.0"),
    ],
    targets: [
        .target(name: "SpoolCore"),
        .target(
            name: "SpoolEngine",
            dependencies: ["SpoolCore"],
            linkerSettings: [
                .linkedFramework("ApplicationServices"),
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("QuartzCore"),
            ]
        ),
        .executableTarget(
            name: "SpoolApp",
            dependencies: [
                "SpoolCore",
                "SpoolEngine",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            linkerSettings: [.linkedFramework("ServiceManagement")]
        ),
        .executableTarget(name: "spool-cli", dependencies: ["SpoolCore"]),
        // Live E2E test (`make e2e`, docs/E2E.md). Not part of `swift test`: it moves real windows.
        .target(name: "SpoolE2EKit"),
        .executableTarget(name: "spool-e2e", dependencies: ["SpoolE2EKit", "SpoolCore"]),
        .executableTarget(name: "spool-e2e-windows", dependencies: ["SpoolE2EKit"]),
        .testTarget(name: "SpoolCoreTests", dependencies: ["SpoolCore"]),
        .testTarget(name: "SpoolEngineTests", dependencies: ["SpoolEngine", "SpoolCore"]),
        // Tests the pure rules inside the app (recorder, URL routes, login, single instance).
        .testTarget(name: "SpoolAppTests", dependencies: ["SpoolApp", "SpoolEngine", "SpoolCore"]),
        .testTarget(name: "SpoolE2EKitTests", dependencies: ["SpoolE2EKit"]),
    ],
    swiftLanguageModes: [.v5]
)
