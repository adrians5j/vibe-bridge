// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "VibeBridge",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "VibeBridgeKit", targets: ["VibeBridgeKit"]),
        .executable(name: "VibeBridge", targets: ["VibeBridge"]),
    ],
    targets: [
        .target(name: "VibeBridgeKit", path: "Sources/VibeBridgeKit"),
        .executableTarget(
            name: "VibeBridge",
            dependencies: ["VibeBridgeKit"],
            path: "Sources/VibeBridge",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
    ]
)
