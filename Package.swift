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
            // The hand-written config the syntax layer is measured against. It
            // is a file rather than a string literal on purpose: it has to stay
            // something a person can open and edit, because that is exactly what
            // it is claiming to prove.
            resources: [.copy("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
