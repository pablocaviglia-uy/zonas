// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Zonas",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Zonas",
            path: "Sources/Zonas",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // A test target can link against an executable target since Swift 5.5,
        // main.swift and all, so the app does not have to be cut in two to get
        // it under test.
        .testTarget(
            name: "ZonasTests",
            dependencies: ["Zonas"],
            path: "Tests/ZonasTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
