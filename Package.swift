// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "nd-sleeper",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "nd-sleeper", targets: ["nd-sleeper"]),
    ],
    targets: [
        .target(name: "Core"),
        .target(name: "Helper", dependencies: ["Core"]),
        .target(name: "Agent", dependencies: ["Core"]),
        .executableTarget(name: "nd-sleeper", dependencies: ["Core", "Helper", "Agent"], path: "Sources/CLI"),
    ],
    swiftLanguageModes: [.v6]
)
