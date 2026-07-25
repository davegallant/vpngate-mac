// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "VpngateShared",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "VpngateShared", targets: ["VpngateShared"])
    ],
    targets: [
        .target(name: "VpngateShared"),
        .testTarget(name: "VpngateSharedTests", dependencies: ["VpngateShared"]),
    ]
)
