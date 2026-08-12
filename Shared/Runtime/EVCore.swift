//
//  EVCore.swift
//  DecoderSec (Shared/Runtime)
//
//  Thin compatibility shim — forwards to the new split modules so callers
//  compiled before Phase 2 keep working without a massive rename diff.
//  Phase 3 will redirect each call site directly and delete this file.
//

import Foundation

/// @deprecated Use `BundleIdentifiers`, `ContainerPaths`, and `AppSettingsStore` directly.
enum EVCore {
    enum Identifier {
        static var bundle: String { BundleIdentifiers.app }
        static var networkExtension: String { BundleIdentifiers.networkExtension }
        static let tunnelDescription: String = BundleIdentifiers.tunnelDescription
    }

    static let defaultDNSServers = ContainerPaths.defaultDNSServers
    static var containerURL: URL { ContainerPaths.containerURL }
    static func resourcesURL(for core: CoreType) -> URL { ContainerPaths.resourcesURL(for: core) }

    // Settings — forwarded to AppSettingsStore
    static func getActiveByCoreType() -> [String: String] { AppSettingsStore.getActiveByCoreType() }
    static func setActiveByCoreType(_ map: [String: String]) { AppSettingsStore.setActiveByCoreType(map) }
    static func getAlwaysOnEnabled() -> Bool { AppSettingsStore.getAlwaysOnEnabled() }
    static func setAlwaysOnEnabled(_ v: Bool) { AppSettingsStore.setAlwaysOnEnabled(v) }
    static func getDNSServers() -> [String] { AppSettingsStore.getDNSServers() }
    static func setDNSServers(_ v: [String]) { AppSettingsStore.setDNSServers(v) }
    static func getSelectedCore() -> CoreType { AppSettingsStore.getSelectedCore() }
    static func setSelectedCore(_ v: CoreType) { AppSettingsStore.setSelectedCore(v) }
    static func getTunnelIncludeAllNetworks() -> Bool { AppSettingsStore.getTunnelIncludeAllNetworks() }
    static func setTunnelIncludeAllNetworks(_ v: Bool) { AppSettingsStore.setTunnelIncludeAllNetworks(v) }
    static func getTunnelIncludeLocalNetworks() -> Bool { AppSettingsStore.getTunnelIncludeLocalNetworks() }
    static func setTunnelIncludeLocalNetworks(_ v: Bool) { AppSettingsStore.setTunnelIncludeLocalNetworks(v) }
    static func getTunnelIncludeAPNs() -> Bool { AppSettingsStore.getTunnelIncludeAPNs() }
    static func setTunnelIncludeAPNs(_ v: Bool) { AppSettingsStore.setTunnelIncludeAPNs(v) }
    static func getTunnelIncludeCellularServices() -> Bool { AppSettingsStore.getTunnelIncludeCellularServices() }
    static func setTunnelIncludeCellularServices(_ v: Bool) { AppSettingsStore.setTunnelIncludeCellularServices(v) }
    static func getUseZashboard() -> Bool { AppSettingsStore.getUseZashboard() }
    static func setUseZashboard(_ v: Bool) { AppSettingsStore.setUseZashboard(v) }
}
