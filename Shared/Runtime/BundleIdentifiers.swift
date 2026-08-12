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

    /// All embedded `.appex` bundle IDs (empty = IPA missing Packet Tunnel / bad resign).
    static func embeddedAppexBundleIDs() -> [String] {
        guard let plugins = Bundle.main.builtInPlugInsURL else { return [] }
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: plugins,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return urls.compactMap { url -> String? in
            guard url.pathExtension == "appex" else { return nil }
            return Bundle(url: url)?.bundleIdentifier
        }.filter { !$0.isEmpty }
    }

    /// One-line preflight for Log console before startVPNTunnel.
    static func extensionPreflightReport() -> String {
        let ids = embeddedAppexBundleIDs()
        let ne = networkExtension
        let matched = ids.contains(ne)
        return "appex preflight app=\(app) ne=\(ne) plugins=[\(ids.joined(separator: ","))] matched=\(matched)"
    }

    /// True when the IPA actually embeds a Packet Tunnel appex we can address.
    static var hasEmbeddedTunnelExtension: Bool {
        !embeddedAppexBundleIDs().isEmpty
    }

    private static func embeddedTunnelBundleID() -> String? {
        let ids = embeddedAppexBundleIDs()
        // Prefer an appex whose id looks like a tunnel / matches Brand defaults.
        if let preferred = ids.first(where: {
            $0.hasSuffix(".PacketTunnel")
                || $0.lowercased().contains("tunnel")
                || $0.lowercased().hasSuffix(".ne")
        }) {
            return preferred
        }
        return ids.first
    }
}
