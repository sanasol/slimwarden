// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Slimwarden",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "CArgon2",
            path: "Sources/CArgon2",
            exclude: ["LICENSE"],
            cSettings: [
                .headerSearchPath("."),
                .define("ARGON2_NO_THREADS"),
            ]
        ),
        .target(
            name: "SlimwardenCore",
            dependencies: ["CArgon2"],
            path: "Sources/SlimwardenCore"
        ),
        .executableTarget(
            name: "Slimwarden",
            dependencies: ["SlimwardenCore"],
            path: "Sources/Slimwarden"
        ),
        .executableTarget(
            name: "slimtool",
            dependencies: ["SlimwardenCore"],
            path: "Sources/slimtool"
        ),
        .testTarget(
            name: "SlimwardenTests",
            dependencies: ["SlimwardenCore"],
            path: "Tests/SlimwardenTests"
        ),
    ]
)
