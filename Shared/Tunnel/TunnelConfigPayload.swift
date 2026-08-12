//
//  TunnelConfigPayload.swift
//  Shared
//
//  Single typed contract for the config blob handed from the host app to
//  the Packet Tunnel extension — both as the persisted
//  `NETunnelProviderProtocol.providerConfiguration` and as the ephemeral
//  `NEVPNConnection.startVPNTunnel(options:)` payload. Previously each side
//  hand-rolled a matching `[String: Any]` dictionary with stringly typed
//  keys in `TunnelManager` and `PacketTunnelProvider` independently; this
//  type is now the single place that owns the wire format.
//
//  The wire format (keys, value types, fallback order, defaults) is
//  unchanged from the dictionaries this replaces, so `NETunnelProviderManager`
//  entries persisted on-disk by older app versions keep decoding correctly —
//  no migration needed.
//

import Foundation

enum TunnelConfigPayloadError: LocalizedError {
    case configTooLarge(bytes: Int, limit: Int)

    var errorDescription: String? {
        switch self {
        case let .configTooLarge(bytes, limit):
            let formatter = ByteCountFormatter()
            formatter.countStyle = .file
            let have = formatter.string(fromByteCount: Int64(bytes))
            let max = formatter.string(fromByteCount: Int64(limit))
            return String(localized: "Configuration is too large for the VPN profile (\(have); limit \(max)). Remove unused outbounds or split the subscription.")
        }
    }
}

struct TunnelConfigPayload {
    /// Conservative limit for persisted providerConfiguration.
    static let maxConfigContentBytes = 512 * 1024
    /// Practical limit for ephemeral startVPNTunnel(options:) — large options
    /// dictionaries can kill the appex before startTunnel runs (empty Log console).
    static let maxStartOptionsConfigBytes = 96 * 1024
    static let configContentKey = "configContent"
    static let configIDKey = "configID"
    static let coreTypeKey = "coreType"
    static let dnsServersKey = "dnsServers"
    static let useZashboardKey = "useZashboard"
    /// Lean start flag — extension must read config from providerConfiguration.
    static let usePersistedConfigKey = "usePersistedConfig"

    static let defaultDNSServers = ["1.1.1.1", "8.8.8.8"]

    var configContent: String
    /// Not currently read by `PacketTunnelProvider` — reserved for future
    /// diagnostics/log correlation. Kept for wire-format parity.
    var configID: String
    var coreType: CoreType
    var dnsServers: [String]
    var useZashboard: Bool

    /// For `NETunnelProviderProtocol.providerConfiguration` (persisted to
    /// disk by the NetworkExtension framework as part of the VPN profile).
    var asProviderConfiguration: [String: Any] {
        [
            Self.configContentKey: configContent,
            Self.configIDKey: configID,
            Self.coreTypeKey: coreType.rawValue,
            Self.dnsServersKey: dnsServers,
            Self.useZashboardKey: useZashboard,
        ]
    }

    func validateSize() throws {
        let bytes = configContent.utf8.count
        guard bytes <= Self.maxConfigContentBytes else {
            throw TunnelConfigPayloadError.configTooLarge(bytes: bytes, limit: Self.maxConfigContentBytes)
        }
    }

    /// For `NEVPNConnection.startVPNTunnel(options:)` — values must be
    /// `NSObject`. Prefer `asLeanStartOptions` for large Happ configs.
    var asStartOptions: [String: NSObject] {
        [
            Self.configContentKey: configContent as NSString,
            Self.configIDKey: configID as NSString,
            Self.coreTypeKey: coreType.rawValue as NSString,
            Self.dnsServersKey: dnsServers as NSArray,
            Self.useZashboardKey: NSNumber(value: useZashboard),
        ]
    }

    /// Tiny options blob: config already saved in providerConfiguration.
    /// Avoids iOS killing the Packet Tunnel before `startTunnel` when JSON is large.
    var asLeanStartOptions: [String: NSObject] {
        [
            Self.usePersistedConfigKey: NSNumber(value: true),
            Self.configIDKey: configID as NSString,
            Self.coreTypeKey: coreType.rawValue as NSString,
        ]
    }

    /// Use full options only when the config is small enough for the XPC launch path.
    var preferredStartOptions: [String: NSObject] {
        if configContent.utf8.count <= Self.maxStartOptionsConfigBytes {
            return asStartOptions
        }
        return asLeanStartOptions
    }

    /// Decodes the extension side of the contract: prefers the fresh
    /// `options` passed to `startTunnel`, falls back to the persisted
    /// `providerConfiguration` (used on on-demand / system-triggered
    /// restarts that pass no explicit `options`). Returns `nil` when no
    /// usable `configContent` is present on either side — the caller is
    /// expected to surface its own "start the tunnel from the app once"
    /// error, matching prior behavior.
    static func decode(
        options: [String: NSObject]?,
        providerConfiguration: [String: Any]?
    ) -> TunnelConfigPayload? {
        let providerConfig = providerConfiguration ?? [:]

        guard let configContent = (options?[configContentKey] as? String)
            ?? (providerConfig[configContentKey] as? String),
            !configContent.isEmpty else {
            return nil
        }

        let configID = (options?[configIDKey] as? String)
            ?? (providerConfig[configIDKey] as? String)
            ?? ""

        let coreTypeRaw = (options?[coreTypeKey] as? String)
            ?? (providerConfig[coreTypeKey] as? String)
            ?? CoreType.xray.rawValue
        let coreType = CoreType(rawValue: coreTypeRaw) ?? .xray

        let rawDNS = (options?[dnsServersKey] as? [String])
            ?? (providerConfig[dnsServersKey] as? [String])
        let dnsServers = cleanDNS(rawDNS)

        let useZashboard = (options?[useZashboardKey] as? NSNumber)?.boolValue
            ?? (providerConfig[useZashboardKey] as? Bool)
            ?? true

        return TunnelConfigPayload(
            configContent: configContent,
            configID: configID,
            coreType: coreType,
            dnsServers: dnsServers,
            useZashboard: useZashboard
        )
    }

    private static func cleanDNS(_ raw: [String]?) -> [String] {
        let trimmed = (raw ?? []).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return trimmed.isEmpty ? defaultDNSServers : trimmed
    }
}
