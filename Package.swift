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
        .macOS("14.0"),
        .iOS("17.0"),
        .visionOS("26.0"),
    ],
    products: [
        .library(
            name: "Loom",
            targets: ["Loom"]
        ),
        .library(
            name: "LoomShell",
            targets: ["LoomShell"]
        ),
        .library(
            name: "LoomCloudKit",
            targets: ["LoomCloudKit"]
        ),
        .library(
            name: "LoomKit",
            targets: ["LoomKit"]
        ),
        .library(
            name: "LoomSharedRuntime",
            targets: ["LoomSharedRuntime"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.81.0"),
        .package(url: "https://github.com/apple/swift-nio-ssh.git", from: "0.12.0"),
    ],
    targets: [
        .target(
            name: "CLoomShellSupport",
            publicHeadersPath: "include"
        ),
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
        .target(
            name: "LoomShell",
            dependencies: [
                "CLoomShellSupport",
                "Loom",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
                .product(name: "NIOSSH", package: "swift-nio-ssh"),
            ]
        ),
        .target(
            name: "LoomKit",
            dependencies: [
                "Loom",
                "LoomCloudKit",
                "LoomSharedRuntime",
            ]
        ),
        .target(
            name: "LoomSharedRuntime",
            dependencies: [
                "Loom",
                "LoomCloudKit",
            ],
            path: "Sources/LoomHost"
        ),
        .testTarget(
            name: "LoomTests",
            dependencies: ["Loom"]
        ),
        .testTarget(
            name: "LoomShellTests",
            dependencies: ["LoomShell"]
        ),
        .testTarget(
            name: "LoomCloudKitTests",
            dependencies: ["LoomCloudKit"]
        ),
        .testTarget(
            name: "LoomKitTests",
            dependencies: ["LoomKit"]
        ),
        .testTarget(
            name: "LoomSharedRuntimeTests",
            dependencies: ["LoomSharedRuntime"],
            path: "Tests/LoomHostTests"
        ),
    ]
)
