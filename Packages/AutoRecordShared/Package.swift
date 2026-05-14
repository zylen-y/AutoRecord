// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AutoRecordShared",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AutoRecordShared", targets: ["AutoRecordShared"]),
    ],
    targets: [
        .target(name: "AutoRecordShared"),
        .testTarget(
            name: "AutoRecordSharedTests",
            dependencies: ["AutoRecordShared"]
        ),
    ]
)
