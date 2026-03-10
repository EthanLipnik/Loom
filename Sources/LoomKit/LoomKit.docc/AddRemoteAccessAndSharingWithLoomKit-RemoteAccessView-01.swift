import LoomKit
import SwiftUI

struct RemoteAccessView: View {
    @LoomQuery(.peers(filter: .remoteAccessEnabled, sort: .name))
    private var remotePeers: [LoomPeerSnapshot]

    var body: some View {
        List(remotePeers) { peer in
            VStack(alignment: .leading) {
                Text(peer.name)
                Text(peer.relaySessionID ?? "No relay session")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Remote Peers")
    }
}
