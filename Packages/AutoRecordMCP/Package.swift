// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AutoRecordMCP",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "autorecord-mcp", targets: ["autorecord-mcp"]),
        .library(name: "AutoRecordMCPCore", targets: ["AutoRecordMCPCore"]),
    ],
    dependencies: [
        .package(path: "../AutoRecordShared"),
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk", from: "0.11.0"),
    ],
    targets: [
        .target(
            name: "AutoRecordMCPCore",
            dependencies: [
                .product(name: "AutoRecordShared", package: "AutoRecordShared"),
                .product(name: "MCP", package: "swift-sdk"),
            ]
        ),
        .executableTarget(
            name: "autorecord-mcp",
            dependencies: [
                "AutoRecordMCPCore",
                .product(name: "MCP", package: "swift-sdk"),
            ]
        ),
        .testTarget(
            name: "AutoRecordMCPCoreTests",
            dependencies: ["AutoRecordMCPCore"]
        ),
    ]
)
