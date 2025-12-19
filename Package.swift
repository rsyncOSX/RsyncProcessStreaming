// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.
// swiftlint:disable trailing_comma
import PackageDescription

let package = Package(
    name: "RsyncProcessStreaming",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "RsyncProcessStreaming",
            targets: ["RsyncProcessStreaming"]
        ),
    ],
    targets: [
        .target(
            name: "RsyncProcessStreaming",
            dependencies: []
        ),
        .testTarget(
            name: "RsyncProcessStreamingTests",
            dependencies: ["RsyncProcessStreaming"]
        ),
    ]
)
// swiftlint:enable trailing_comma

