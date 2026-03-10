import LoomKit
import SwiftUI

@main
struct StudioLinkApp: App {
    let loomContainer = try! LoomContainer(
        for: .init(
            serviceType: "_studiolink._tcp",
            serviceName: "Studio Mac",
            deviceIDSuiteName: "group.com.example.studiolink",
            advertisementMetadata: [
                "role": "editor"
            ],
            supportedFeatures: [
                "messages",
                "transfers"
            ]
        )
    )

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .loomContainer(loomContainer)
    }
}
