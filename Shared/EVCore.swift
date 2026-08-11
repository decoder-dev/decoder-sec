//
//  EVCore.swift
//  DecoderSec
//
//  App settings + local storage. No App Groups.
//

import Foundation

enum EVCore {
    enum Identifier {
        /// Host app bundle id (survives ESign remap).
        static var bundle: String {
            Bundle.main.bundleIdentifier ?? BrandIdentity.bundleID
        }

        /// Packet Tunnel provider id. Discovers the embedded `.appex` so ESign
        /// can change both IDs in one sign and the app still finds the extension.
        static var networkExtension: String {
            if let embedded = embeddedTunnelBundleID() {
                return embedded
            }
            let base = bundle
            if base.contains("PacketTunnel") || base.lowercased().hasSuffix(".tunnel") || base.lowercased().hasSuffix(".ne") {
                return base
            }
            return base + ".PacketTunnel"
        }

        static let tunnelDescription = BrandIdentity.displayName

        private static func embeddedTunnelBundleID() -> String? {
            guard let plugins = Bundle.main.builtInPlugInsURL else { return nil }
            guard let urls = try? FileManager.default.contentsOfDirectory(
                at: plugins,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { return nil }
            for url in urls where url.pathExtension == "appex" {
                if let id = Bundle(url: url)?.bundleIdentifier, !id.isEmpty {
                    return id
                }
            }
            return nil
        }
    }

    static let defaultDNSServers = ["1.1.1.1", "8.8.8.8"]

    /// Local app / extension container (Application Support).
    static var containerURL: URL {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.temporaryDirectory
        let url = base.appendingPathComponent("DecoderSec", isDirectory: true)
        try? fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func resourcesURL(for core: CoreType) -> URL {
        let url = containerURL
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent(core.rawValue, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - Settings (UserDefaults.standard)

    private static var defaults: UserDefaults { .standard }

    private enum Key {
        static let activeByCoreType = "decoder.activeByCoreType"
        static let alwaysOnEnabled = "decoder.alwaysOnEnabled"
        static let dnsServers = "decoder.dnsServers"
        static let selectedCore = "decoder.selectedCore"
        static let tunnelIncludeAPNs = "decoder.tunnelIncludeAPNs"
        static let tunnelIncludeAllNetworks = "decoder.tunnelIncludeAllNetworks"
        static let tunnelIncludeCellularServices = "decoder.tunnelIncludeCellularServices"
        static let tunnelIncludeLocalNetworks = "decoder.tunnelIncludeLocalNetworks"
        static let useZashboard = "decoder.useZashboard"
    }

    static func getActiveByCoreType() -> [String: String] {
        defaults.dictionary(forKey: Key.activeByCoreType) as? [String: String] ?? [:]
    }

    static func setActiveByCoreType(_ map: [String: String]) {
        defaults.set(map, forKey: Key.activeByCoreType)
    }

    static func getAlwaysOnEnabled() -> Bool {
        defaults.bool(forKey: Key.alwaysOnEnabled)
    }

    static func setAlwaysOnEnabled(_ value: Bool) {
        defaults.set(value, forKey: Key.alwaysOnEnabled)
    }

    static func getDNSServers() -> [String] {
        let stored = defaults.stringArray(forKey: Key.dnsServers) ?? []
        return stored.isEmpty ? defaultDNSServers : stored
    }

    static func setDNSServers(_ servers: [String]) {
        defaults.set(servers, forKey: Key.dnsServers)
    }

    static func getSelectedCore() -> CoreType {
        CoreType(rawValue: defaults.string(forKey: Key.selectedCore) ?? "") ?? .xray
    }

    static func setSelectedCore(_ core: CoreType) {
        defaults.set(core.rawValue, forKey: Key.selectedCore)
    }

    static func getTunnelIncludeAllNetworks() -> Bool {
        defaults.bool(forKey: Key.tunnelIncludeAllNetworks)
    }

    static func setTunnelIncludeAllNetworks(_ value: Bool) {
        defaults.set(value, forKey: Key.tunnelIncludeAllNetworks)
    }

    static func getTunnelIncludeLocalNetworks() -> Bool {
        defaults.object(forKey: Key.tunnelIncludeLocalNetworks) as? Bool ?? true
    }

    static func setTunnelIncludeLocalNetworks(_ value: Bool) {
        defaults.set(value, forKey: Key.tunnelIncludeLocalNetworks)
    }

    static func getTunnelIncludeAPNs() -> Bool {
        defaults.bool(forKey: Key.tunnelIncludeAPNs)
    }

    static func setTunnelIncludeAPNs(_ value: Bool) {
        defaults.set(value, forKey: Key.tunnelIncludeAPNs)
    }

    static func getTunnelIncludeCellularServices() -> Bool {
        defaults.bool(forKey: Key.tunnelIncludeCellularServices)
    }

    static func setTunnelIncludeCellularServices(_ value: Bool) {
        defaults.set(value, forKey: Key.tunnelIncludeCellularServices)
    }

    static func getUseZashboard() -> Bool {
        defaults.object(forKey: Key.useZashboard) as? Bool ?? true
    }

    static func setUseZashboard(_ value: Bool) {
        defaults.set(value, forKey: Key.useZashboard)
    }
}
