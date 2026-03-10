import LoomCloudKit
import LoomKit
import SwiftUI

@main
struct RemoteStudioApp: App {
    let loomContainer = try! LoomContainer(
        for: .init(
            serviceType: "_studiolink._tcp",
            serviceName: "Studio Mac",
            deviceIDSuiteName: "group.com.example.studiolink",
            cloudKit: .init(
                containerIdentifier: "iCloud.com.example.studiolink"
            )
        )
    )

    var body: some Scene {
        WindowGroup {
            RemoteAccessView()
        }
    }
}
