import LoomKit
import SwiftUI

struct ContentView: View {
    @LoomQuery(.peers(sort: .name))
    private var peers: [LoomPeerSnapshot]

    var body: some View {
        List(peers) { peer in
            Text(peer.name)
        }
        .navigationTitle("Peers")
    }
}
