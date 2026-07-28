// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ImageHub",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "ImageHub",
            path: "Sources/ImageHub"
        )
    ]
)
