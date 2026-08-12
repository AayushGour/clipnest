// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ClipnestCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ClipnestCore", targets: ["ClipnestCore"])
    ],
    targets: [
        .target(name: "ClipnestCore"),
        .testTarget(name: "ClipnestCoreTests", dependencies: ["ClipnestCore"])
    ]
)
