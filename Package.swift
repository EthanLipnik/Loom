// swift-tools-version: 6.2

//
//  Package.swift
//  Loom
//
//  Created by Ethan Lipnik on 3/9/26.
//

import PackageDescription

let package = Package(
    name: "Loom",
    platforms: [
        .macOS(.v14),
        .iOS("17.4"),
        .visionOS(.v26),
    ],
    products: [
        .library(
            name: "Loom",
            targets: ["Loom"]
        ),
        .library(
            name: "LoomCloudKit",
            targets: ["LoomCloudKit"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.81.0"),
        .package(url: "https://github.com/apple/swift-nio-ssh.git", from: "0.12.0"),
    ],
    targets: [
        .target(
            name: "Loom",
            dependencies: [
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
                .product(name: "NIOSSH", package: "swift-nio-ssh"),
            ]
        ),
        .target(
            name: "LoomCloudKit",
            dependencies: ["Loom"]
        ),
        .testTarget(
            name: "LoomTests",
            dependencies: ["Loom"]
        ),
        .testTarget(
            name: "LoomCloudKitTests",
            dependencies: ["LoomCloudKit"]
        ),
    ]
)
