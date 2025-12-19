// swift-tools-version: 5.9
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
        .package(url: "https://github.com/apple/swift-testing.git", from: "0.4.0"),
    ],
    targets: [
        .target(
            name: "RsyncProcessStreaming"
        ),
        .testTarget(
            name: "RsyncProcessStreamingTests",
            dependencies: [
                "RsyncProcessStreaming",
                .product(name: "Testing", package: "swift-testing"),
            ]
        ),
    ]
)
// swiftlint:enable trailing_comma
