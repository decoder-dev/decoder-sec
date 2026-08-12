//
//  BundleIdentifiers.swift
//  DecoderSec (Shared/Runtime)
//
//  Bundle-ID resolution for the host app and the embedded Packet Tunnel appex.
//  Split from EVCore.swift — Phase 2 rewrite.
//

import Foundation

/// Stable bundle-ID strings for the two targets.
/// Discovers the embedded `.appex` at runtime so ESign can remap both IDs
/// and the app still finds its extension without a code change.
enum BundleIdentifiers {
    /// Host-app bundle id (survives ESign remap).
    static var app: String {
        Bundle.main.bundleIdentifier ?? BrandIdentity.bundleID
    }

    /// Packet Tunnel extension bundle id — prefers the embedded `.appex`.
    static var networkExtension: String {
        if let embedded = embeddedTunnelBundleID() { return embedded }
        let base = app
        if base.contains("PacketTunnel") || base.lowercased().hasSuffix(".tunnel") || base.lowercased().hasSuffix(".ne") {
            return base
        }
        return base + ".PacketTunnel"
    }

    /// Human-readable VPN profile name shown in Settings → VPN.
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
