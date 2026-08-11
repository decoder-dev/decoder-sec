//
//  DecoderSecApp.swift
//  DecoderSec
//
//  Created by NodePassProject on 5/2/26.
//

import SwiftUI

@main
struct DecoderSecApp: App {
    @ObservedObject private var deepLinks = DeepLinkCenter.shared

    init() {
        // Touch storage early so fallback flags are set before first view.
        _ = EVCore.containerURL
        _ = PersistenceController.shared
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(deepLinks)
                .onOpenURL { url in
                    deepLinks.handle(url: url)
                }
                .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
                    if let url = activity.webpageURL {
                        deepLinks.handle(url: url)
                    }
                }
        }
    }
}
