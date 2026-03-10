import LoomKit
import SwiftUI

struct RemoteAccessView: View {
    @Environment(\.loomContext) private var loomContext
    @LoomQuery(.peers(filter: .remoteAccessEnabled, sort: .name))
    private var remotePeers: [LoomPeerSnapshot]

    var body: some View {
        List {
            Section("Hosting") {
                Button("Start Remote Hosting") {
                    Task {
                        try? await loomContext.startRemoteHosting(
                            sessionID: "studio-mac",
                            publicHostForTCP: "studio.example.com"
                        )
                    }
                }

                Button("Stop Remote Hosting") {
                    Task {
                        await loomContext.stopRemoteHosting()
                    }
                }

                Text(loomContext.isRemoteHosting ? "Hosting remotely" : "Not hosting")
                    .foregroundStyle(.secondary)
            }

            Section("Remote Peers") {
                ForEach(remotePeers) { peer in
                    Text(peer.name)
                }
            }
        }
        .navigationTitle("Remote Access")
    }
}
