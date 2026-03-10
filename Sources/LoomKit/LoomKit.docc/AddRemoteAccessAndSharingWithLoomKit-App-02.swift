import LoomCloudKit
import LoomKit
import SwiftUI

private func makeRelayConfiguration() -> LoomRelayConfiguration {
    LoomRelayConfiguration(
        baseURL: URL(string: "https://relay.example.com")!,
        appAuthentication: .init(
            appID: "studio-link",
            sharedSecret: "relay-shared-secret"
        )
    )
}

@main
struct RemoteStudioApp: App {
    let loomContainer = try! LoomContainer(
        for: .init(
            serviceType: "_studiolink._tcp",
            serviceName: "Studio Mac",
            deviceIDSuiteName: "group.com.example.studiolink",
            cloudKit: .init(
                containerIdentifier: "iCloud.com.example.studiolink"
            ),
            relay: makeRelayConfiguration(),
            trust: .shareAwareAutoTrust
        )
    )

    var body: some Scene {
        WindowGroup {
            RemoteAccessView()
        }
    }
}
