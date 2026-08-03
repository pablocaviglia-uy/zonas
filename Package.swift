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
        )
    ]
)
