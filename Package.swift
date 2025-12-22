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
    dependencies: [
        .package(url: "https://github.com/apple/swift-atomics.git", .upToNextMajor(from: "1.3.0")),
    ],
    targets: [
        .target(
            name: "RsyncProcessStreaming",
            dependencies: [.product(name: "Atomics", package: "swift-atomics")]
        ),
        .testTarget(
            name: "RsyncProcessStreamingTests",
            dependencies: ["RsyncProcessStreaming"]
        ),
    ]
)
// swiftlint:enable trailing_comma
