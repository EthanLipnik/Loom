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
        .iOS("17.4"),
        .visionOS("26.0"),
    ],
    products: [
        .library(
            name: "LoomNetworking",
            targets: ["LoomNetworking"]
        ),
        .library(
            name: "LoomNetworkingNIO",
            targets: ["LoomNetworkingNIO"]
        ),
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
        .package(url: "https://github.com/apple/swift-crypto.git", exact: "4.5.1"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.81.0"),
        .package(url: "https://github.com/apple/swift-nio-ssh.git", from: "0.12.0"),
    ],
    targets: [
        .target(
            name: "LoomNetworking"
        ),
        .target(
            name: "LoomNetworkingNIO",
            dependencies: [
                "LoomNetworking",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
            ]
        ),
        .target(
            name: "CLoomPlatformSupport",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedLibrary("advapi32", .when(platforms: [.windows])),
                .linkedLibrary("crypt32", .when(platforms: [.windows])),
                .linkedLibrary("dnsapi", .when(platforms: [.windows])),
                .linkedLibrary("ws2_32", .when(platforms: [.windows])),
            ]
        ),
        .target(
            name: "LoomPlatformAdapters",
            dependencies: [
                "CLoomPlatformSupport",
                "LoomNetworking",
            ]
        ),
        .target(
            name: "CLoomShellSupport",
            publicHeadersPath: "include"
        ),
        .target(
            name: "Loom",
            dependencies: [
                "LoomNetworking",
                "LoomNetworkingNIO",
                "LoomPlatformAdapters",
                .product(name: "Crypto", package: "swift-crypto"),
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
            name: "LoomNetworkingTests",
            dependencies: ["LoomNetworking"]
        ),
        .testTarget(
            name: "LoomNetworkingNIOTests",
            dependencies: [
                "LoomNetworking",
                "LoomNetworkingNIO",
            ]
        ),
        .testTarget(
            name: "LoomPlatformAdaptersTests",
            dependencies: [
                "LoomNetworking",
                "LoomPlatformAdapters",
            ]
        ),
        .testTarget(
            name: "LoomTests",
            dependencies: [
                "Loom",
                "LoomNetworkingNIO",
            ]
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
