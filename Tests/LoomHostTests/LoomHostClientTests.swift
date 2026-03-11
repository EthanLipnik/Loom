@testable import Loom
@testable import LoomHost
import Foundation
import Testing

@Suite("LoomHost Client", .serialized)
struct LoomHostClientTests {
    @Test("Client registers against a running broker over a shared Unix socket")
    func clientRegistersAgainstRunningBroker() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "lh-\(UUID().uuidString.prefix(8))",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        defer {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }

        let sharedConfiguration = LoomSharedHostConfiguration(
            appGroupIdentifier: "group.loom.tests",
            app: LoomHostAppDescriptor(
                appID: "com.example.alpha",
                displayName: "Alpha"
            ),
            socketName: "lh",
            directoryURLOverride: temporaryDirectory
        )
        let socketPath = temporaryDirectory
            .appendingPathComponent("\(sharedConfiguration.socketName).sock")
            .path
        let lockURL = temporaryDirectory
            .appendingPathComponent("\(sharedConfiguration.socketName).lock")

        let lockFD = open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        #expect(lockFD >= 0)
        #expect(flock(lockFD, LOCK_EX | LOCK_NB) == 0)

        let serviceType = "_lh\(UUID().uuidString.prefix(6).lowercased())._tcp"
        let deviceID = UUID()
        let broker = LoomHostBroker(
            configuration: sharedConfiguration,
            socketPath: socketPath,
            lockFileDescriptor: lockFD,
            runtimeFactory: {
                let node = await MainActor.run {
                    LoomNode(
                        configuration: LoomNetworkConfiguration(
                            serviceType: serviceType,
                            enablePeerToPeer: false,
                            enabledDirectTransports: [.tcp]
                        ),
                        identityManager: LoomIdentityManager.shared
                    )
                }
                let connectionCoordinator = await MainActor.run {
                    LoomConnectionCoordinator(node: node)
                }
                return LoomHostRuntimeDependencies(
                    serviceName: "Shared Host",
                    deviceID: deviceID,
                    node: node,
                    cloudKitManager: nil,
                    peerProvider: nil,
                    shareManager: nil,
                    relayClient: nil,
                    overlayDirectoryConfiguration: nil,
                    connectionCoordinator: connectionCoordinator,
                    bootstrapMetadataProvider: nil,
                    hostAdvertisementMetadata: [:],
                    hostSupportedFeatures: [],
                    startupMode: .simulated
                )
            }
        )
        try await broker.start()

        let client = LoomHostClient(configuration: sharedConfiguration)
        do {
            try await withTimeout(.seconds(5), operation: "client.start()") {
                try await client.start()
            }

            let snapshots = await client.makeStateStream()
            let snapshot = try #require(
                await firstValue(
                    from: snapshots,
                    timeout: .seconds(5)
                )
            )
            #expect(snapshot.isRunning == true)

            try await withTimeout(.seconds(5), operation: "client.stop()") {
                await client.stop()
            }
            try await withTimeout(.seconds(5), operation: "broker.stop()") {
                await broker.stop()
            }
        } catch {
            await client.stop()
            await broker.stop()
            throw error
        }
    }
}

private func firstValue<Element: Sendable>(
    from stream: AsyncStream<Element>,
    timeout: Duration
) async -> Element? {
    await withTaskGroup(of: Element?.self) { group in
        group.addTask {
            for await value in stream {
                return value
            }
            return nil
        }
        group.addTask {
            try? await Task.sleep(for: timeout)
            return nil
        }

        let value = await group.next() ?? nil
        group.cancelAll()
        return value
    }
}

private func withTimeout<T: Sendable>(
    _ timeout: Duration,
    operation: String,
    _ body: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await body()
        }
        group.addTask {
            try await Task.sleep(for: timeout)
            throw TimeoutError(operation: operation)
        }

        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}

private struct TimeoutError: Error, CustomStringConvertible {
    let operation: String

    var description: String {
        "Timed out waiting for \(operation)"
    }
}
