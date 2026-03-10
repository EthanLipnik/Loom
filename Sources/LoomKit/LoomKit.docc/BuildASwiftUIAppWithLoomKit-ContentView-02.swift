import LoomKit
import SwiftUI

struct ContentView: View {
    @Environment(\.loomContext) private var loomContext
    @LoomQuery(.peers(sort: .name))
    private var peers: [LoomPeerSnapshot]
    @LoomQuery(.connections(filter: .connected, sort: .peerName))
    private var connections: [LoomConnectionSnapshot]

    var body: some View {
        List {
            Section("Peers") {
                ForEach(peers) { peer in
                    Text(peer.name)
                }
            }

            Section("Connected") {
                ForEach(connections) { connection in
                    Text(connection.peerName)
                }
            }
        }
        .navigationTitle("Studio Link")
        .task {
            try? await loomContext.start()
        }
    }
}
