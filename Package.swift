// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "PhotoChronicle",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(
            name: "PhotoChronicle",
            targets: ["PhotoChronicle"])
    ],
    targets: [
        .executableTarget(
            name: "PhotoChronicle",
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        )
    ]
)
