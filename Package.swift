// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "solarman-swift",
    platforms: [
        .macOS(.v26),
        .iOS(.v26),
        .macCatalyst(.v26),
        .tvOS(.v26),
        .watchOS(.v26),
        .visionOS(.v26),
    ],
    products: [
        .library(name: "SolarmanV5", targets: ["SolarmanV5"]),
    ],
    dependencies: [
        .package(url: "https://github.com/3a4oT/modbus-swift.git", from: "1.0.1"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.91.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.7.1"),
        .package(url: "https://github.com/apple/swift-metrics.git", from: "2.7.1"),
        .package(url: "https://github.com/swift-server/swift-service-lifecycle.git", from: "2.9.1"),
    ],
    targets: [
        // MARK: - SolarmanV5 (V5 Protocol Client)

        // Async/await client for Solarman V5 WiFi data loggers
        .target(
            name: "SolarmanV5",
            dependencies: [
                .product(name: "ModbusCore", package: "modbus-swift"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "Metrics", package: "swift-metrics"),
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
            ]
        ),

        // MARK: - Tests

        .testTarget(
            name: "SolarmanV5Tests",
            dependencies: [
                "SolarmanV5",
                .product(name: "NIOEmbedded", package: "swift-nio"),
            ]
        ),
    ]
)
