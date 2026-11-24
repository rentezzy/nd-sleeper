// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "nd-sleeper",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(name: "nd-sleeper")
    ],
    swiftLanguageModes: [.v6]
)
