// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Brightness",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Brightness",
            path: "Sources/Brightness",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
