//
//  AppEnvironment.swift
//  DecoderSec/App
//
//  Single assembly point: builds every singleton once, exposes them
//  via .environmentObject / @EnvironmentObject so no View ever reaches
//  for .shared directly. Phase 2 rewrite.
//

import SwiftUI

/// Owns the app's singletons and injects them into the SwiftUI tree.
/// Add it to the root scene modifier chain once:
///
///     WindowGroup { ContentView() }
///         .modifier(AppEnvironment.modifier)
///
@MainActor
final class AppEnvironment: ObservableObject {

    // MARK: - Singletons (assembled once here, injected everywhere else)

    let tunnel     = TunnelManager.shared
    let store      = ConfigurationStore.shared
    let appState   = AppState.shared
    let deepLinks  = DeepLinkCenter.shared
    let routing    = RoutingProfileStore.shared

    // MARK: - Singleton (environment modifier)

    static let shared = AppEnvironment()

    private init() {}

    /// Apply to the root `WindowGroup` scene.
    struct Modifier: ViewModifier {
        @ObservedObject private var env = AppEnvironment.shared

        func body(content: Content) -> some View {
            content
                .environmentObject(env.tunnel)
                .environmentObject(env.store)
                .environmentObject(env.appState)
                .environmentObject(env.deepLinks)
                .environmentObject(env.routing)
        }
    }

    static var modifier: Modifier { Modifier() }
}
