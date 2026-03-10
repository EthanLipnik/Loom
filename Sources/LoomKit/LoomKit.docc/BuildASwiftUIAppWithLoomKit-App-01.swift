import LoomKit
import SwiftUI

@main
struct StudioLinkApp: App {
    let loomContainer = try! LoomContainer(
        for: .init(
            serviceName: "Studio Mac"
        )
    )

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
