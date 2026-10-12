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
            dependencies: ["StripleCore", "StripleEngine"],
            linkerSettings: [.linkedFramework("ServiceManagement")]
        ),
        .executableTarget(name: "striple-cli", dependencies: ["StripleCore"]),
        .testTarget(name: "StripleCoreTests", dependencies: ["StripleCore"]),
        .testTarget(name: "StripleEngineTests", dependencies: ["StripleEngine", "StripleCore"]),
    ],
    swiftLanguageModes: [.v5]
)
