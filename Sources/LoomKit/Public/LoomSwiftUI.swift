//
//  LoomSwiftUI.swift
//  LoomKit
//
//  Created by Codex on 3/10/26.
//

#if canImport(SwiftUI)
import SwiftUI

private struct LoomContainerEnvironmentKey: EnvironmentKey {
    static var defaultValue: LoomContainer {
        MainActor.assumeIsolated {
            LoomContainer.environmentFallback
        }
    }
}

private struct LoomContextEnvironmentKey: EnvironmentKey {
    static var defaultValue: LoomContext {
        MainActor.assumeIsolated {
            LoomContainer.environmentFallback.mainContext
        }
    }
}

public extension EnvironmentValues {
    /// Shared LoomKit container for the current SwiftUI environment subtree.
    var loomContainer: LoomContainer {
        get { self[LoomContainerEnvironmentKey.self] }
        set { self[LoomContainerEnvironmentKey.self] = newValue }
    }

    /// Main-actor LoomKit context for the current SwiftUI environment subtree.
    var loomContext: LoomContext {
        get { self[LoomContextEnvironmentKey.self] }
        set { self[LoomContextEnvironmentKey.self] = newValue }
    }
}

private struct LoomContainerViewModifier: ViewModifier {
    let container: LoomContainer
    let autostart: Bool

    func body(content: Content) -> some View {
        content
            .environment(\.loomContainer, container)
            .environment(\.loomContext, container.mainContext)
            .task(id: autostart) {
                guard autostart else {
                    return
                }
                try? await container.mainContext.start()
            }
            .onDisappear {
                guard autostart else {
                    return
                }
                Task {
                    await container.mainContext.stop()
                }
            }
    }
}

@MainActor
private final class LoomSceneLifecycleController {
    private let container: LoomContainer
    private let autostart: Bool

    init(container: LoomContainer, autostart: Bool) {
        self.container = container
        self.autostart = autostart
        guard autostart else {
            return
        }
        Task {
            try? await container.mainContext.start()
        }
    }

    deinit {
        guard autostart else {
            return
        }
        let ownedContainer = container
        Task {
            await ownedContainer.mainContext.stop()
        }
    }
}

private struct LoomContainerScene<Content: Scene>: Scene {
    private let content: Content
    private let container: LoomContainer
    @MainActor private let lifecycleController: LoomSceneLifecycleController

    init(content: Content, container: LoomContainer, autostart: Bool) {
        self.content = content
        self.container = container
        lifecycleController = LoomSceneLifecycleController(
            container: container,
            autostart: autostart
        )
    }

    var body: some Scene {
        content
            .environment(\.loomContainer, container)
            .environment(\.loomContext, container.mainContext)
    }
}

public extension View {
    /// Injects a shared LoomKit container into the current SwiftUI view hierarchy.
    func loomContainer(
        _ container: LoomContainer,
        autostart: Bool = true
    ) -> some View {
        modifier(
            LoomContainerViewModifier(
                container: container,
                autostart: autostart
            )
        )
    }
}

public extension Scene {
    /// Injects a shared LoomKit container into the current SwiftUI scene hierarchy.
    func loomContainer(
        _ container: LoomContainer,
        autostart: Bool = true
    ) -> some Scene {
        LoomContainerScene(
            content: self,
            container: container,
            autostart: autostart
        )
    }
}
#endif
