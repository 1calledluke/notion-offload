// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DITIngest",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "DITIngest",
            path: "Sources/DITIngest",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
