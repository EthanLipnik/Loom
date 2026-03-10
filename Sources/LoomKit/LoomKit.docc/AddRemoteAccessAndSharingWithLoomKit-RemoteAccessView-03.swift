import LoomKit
import SwiftUI

struct RemoteAccessView: View {
    @Environment(\.loomContext) private var loomContext
    @LoomQuery(.peers(filter: .remoteAccessEnabled, sort: .name))
    private var remotePeers: [LoomPeerSnapshot]

    @State private var statusLine = "Idle"

    var body: some View {
        List {
            Section("Hosting") {
                Button("Start Remote Hosting") {
                    Task {
                        do {
                            try await loomContext.startRemoteHosting(
                                sessionID: "studio-mac",
                                publicHostForTCP: "studio.example.com"
                            )
                            statusLine = "Publishing relay presence"
                        } catch {
                            statusLine = error.localizedDescription
                        }
                    }
                }

                Button("Stop Remote Hosting") {
                    Task {
                        await loomContext.stopRemoteHosting()
                        statusLine = "Stopped remote hosting"
                    }
                }
            }

            Section("Remote Peers") {
                ForEach(remotePeers) { peer in
                    Button(peer.name) {
                        Task {
                            await connect(to: peer)
                        }
                    }
                }
            }

            Section("Status") {
                Text(statusLine)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Remote Access")
    }

    private func connect(to peer: LoomPeerSnapshot) async {
        do {
            let connection = try await loomContext.connect(peer)
            try await connection.send("hello from relay")
            statusLine = "Connected to \(peer.name)"
        } catch {
            statusLine = error.localizedDescription
        }
    }
}
