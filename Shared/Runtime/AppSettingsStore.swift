//
//  AppSettingsStore.swift
//  DecoderSec (Shared/Runtime)
//
//  Typed UserDefaults wrapper — single source of truth for persisted settings.
//  Split from EVCore.swift — Phase 2 rewrite.
//

import Foundation

/// Low-level key/value settings persisted in `UserDefaults.standard`.
/// `AppState` (the observable SwiftUI layer) wraps this.
enum AppSettingsStore {
    private static var defaults: UserDefaults { .standard }

    private enum Key {
        static let activeByCoreType              = "decoder.activeByCoreType"
        static let alwaysOnEnabled               = "decoder.alwaysOnEnabled"
        static let dnsServers                    = "decoder.dnsServers"
        static let selectedCore                  = "decoder.selectedCore"
        static let tunnelIncludeAPNs             = "decoder.tunnelIncludeAPNs"
        static let tunnelIncludeAllNetworks      = "decoder.tunnelIncludeAllNetworks"
        static let tunnelIncludeCellularServices = "decoder.tunnelIncludeCellularServices"
        static let tunnelIncludeLocalNetworks    = "decoder.tunnelIncludeLocalNetworks"
        static let useZashboard                  = "decoder.useZashboard"
    }

    // MARK: - Active config per core

    static func getActiveByCoreType() -> [String: String] {
        defaults.dictionary(forKey: Key.activeByCoreType) as? [String: String] ?? [:]
    }
    static func setActiveByCoreType(_ map: [String: String]) {
        defaults.set(map, forKey: Key.activeByCoreType)
    }

    // MARK: - VPN

    static func getAlwaysOnEnabled() -> Bool { defaults.bool(forKey: Key.alwaysOnEnabled) }
    static func setAlwaysOnEnabled(_ v: Bool) { defaults.set(v, forKey: Key.alwaysOnEnabled) }

    static func getDNSServers() -> [String] {
        let s = defaults.stringArray(forKey: Key.dnsServers) ?? []
        return s.isEmpty ? ContainerPaths.defaultDNSServers : s
    }
    static func setDNSServers(_ v: [String]) { defaults.set(v, forKey: Key.dnsServers) }

    static func getSelectedCore() -> CoreType {
        CoreType(rawValue: defaults.string(forKey: Key.selectedCore) ?? "") ?? .xray
    }
    static func setSelectedCore(_ v: CoreType) { defaults.set(v.rawValue, forKey: Key.selectedCore) }

    static func getTunnelIncludeAllNetworks() -> Bool {
        defaults.bool(forKey: Key.tunnelIncludeAllNetworks)
    }
    static func setTunnelIncludeAllNetworks(_ v: Bool) {
        defaults.set(v, forKey: Key.tunnelIncludeAllNetworks)
    }

    static func getTunnelIncludeLocalNetworks() -> Bool {
        defaults.object(forKey: Key.tunnelIncludeLocalNetworks) as? Bool ?? true
    }
    static func setTunnelIncludeLocalNetworks(_ v: Bool) {
        defaults.set(v, forKey: Key.tunnelIncludeLocalNetworks)
    }

    static func getTunnelIncludeAPNs() -> Bool { defaults.bool(forKey: Key.tunnelIncludeAPNs) }
    static func setTunnelIncludeAPNs(_ v: Bool) { defaults.set(v, forKey: Key.tunnelIncludeAPNs) }

    static func getTunnelIncludeCellularServices() -> Bool {
        defaults.bool(forKey: Key.tunnelIncludeCellularServices)
    }
    static func setTunnelIncludeCellularServices(_ v: Bool) {
        defaults.set(v, forKey: Key.tunnelIncludeCellularServices)
    }

    static func getUseZashboard() -> Bool {
        defaults.object(forKey: Key.useZashboard) as? Bool ?? true
    }
    static func setUseZashboard(_ v: Bool) { defaults.set(v, forKey: Key.useZashboard) }
}
