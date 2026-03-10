import LoomKit
import SwiftUI

struct ContentView: View {
    @Environment(\.loomContext) private var loomContext
    @LoomQuery(.peers(sort: .name))
    private var peers: [LoomPeerSnapshot]
    @LoomQuery(.connections(filter: .connected, sort: .peerName))
    private var connections: [LoomConnectionSnapshot]

    @State private var statusLine = "Idle"

    var body: some View {
        List {
            Section("Peers") {
                ForEach(peers) { peer in
                    Button(peer.name) {
                        Task {
                            await connect(to: peer)
                        }
                    }
                }
            }

            Section("Connected") {
                ForEach(connections) { connection in
                    Text(connection.peerName)
                }
            }

            Section("Status") {
                Text(statusLine)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Studio Link")
        .task {
            try? await loomContext.start()
        }
    }

    private func connect(to peer: LoomPeerSnapshot) async {
        do {
            let connection = try await loomContext.connect(peer)
            try await connection.send("hello")
            statusLine = "Connected to \(peer.name)"
        } catch {
            statusLine = error.localizedDescription
        }
    }
}
