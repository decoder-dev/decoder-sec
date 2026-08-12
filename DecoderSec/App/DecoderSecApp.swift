//
//  DecoderSecApp.swift
//  DecoderSec
//

import SwiftUI

@main
struct DecoderSecApp: App {

    init() {
        _ = PersistenceController.shared
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .modifier(AppEnvironment.modifier)
                .onOpenURL { url in
                    AppEnvironment.shared.deepLinks.handle(url: url)
                }
                .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
                    if let url = activity.webpageURL {
                        AppEnvironment.shared.deepLinks.handle(url: url)
                    }
                }
        }
    }
}
