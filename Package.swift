// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "RsyncProcessStreaming",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "RsyncProcessStreaming",
            targets: ["RsyncProcessStreaming"]
        )
    ],
    targets: [
        .target(
            name: "RsyncProcessStreaming"
        ),
        .testTarget(
            name: "RsyncProcessStreamingTests",
            dependencies: ["RsyncProcessStreaming"]
        )
    ]
)
