//
//  EverywhereApp.swift
//  Everywhere
//
//  Created by NodePassProject on 5/2/26.
//

import SwiftUI

@main
struct EverywhereApp: App {
    @StateObject private var deepLinks = DeepLinkCenter.shared

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
