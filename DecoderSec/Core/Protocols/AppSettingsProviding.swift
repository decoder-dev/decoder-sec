//
//  AppSettingsProviding.swift
//  DecoderSec/Core/Protocols
//
//  Protocol seam for observable app settings — separates the SwiftUI binding
//  layer from the raw UserDefaults storage. Phase 2 rewrite.
//

import Foundation

@MainActor
protocol AppSettingsProviding: AnyObject, ObservableObject {
    var alwaysOnEnabled: Bool { get set }
    var dnsServers: [String] { get set }
    var tunnelIncludeAllNetworks: Bool { get set }
    var tunnelIncludeLocalNetworks: Bool { get set }
    var tunnelIncludeAPNs: Bool { get set }
    var tunnelIncludeCellularServices: Bool { get set }
    var useZashboardEnabled: Bool { get set }
}
