// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacZipper",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(
            name: "MacZipper",
            targets: ["MacZipper"]
        )
    ],
    targets: [
        .executableTarget(
            name: "MacZipper",
            path: "Sources/MacZipper"
        ),
        .testTarget(
            name: "MacZipperTests",
            dependencies: ["MacZipper"],
            path: "Tests/MacZipperTests"
        )
    ]
)
