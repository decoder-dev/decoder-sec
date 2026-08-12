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

struct TunnelConfigPayload {
    static let configContentKey = "configContent"
    static let configIDKey = "configID"
    static let coreTypeKey = "coreType"
    static let dnsServersKey = "dnsServers"
    static let useZashboardKey = "useZashboard"

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

    /// For `NEVPNConnection.startVPNTunnel(options:)` — values must be
    /// `NSObject`.
    var asStartOptions: [String: NSObject] {
        [
            Self.configContentKey: configContent as NSString,
            Self.configIDKey: configID as NSString,
            Self.coreTypeKey: coreType.rawValue as NSString,
            Self.dnsServersKey: dnsServers as NSArray,
            Self.useZashboardKey: NSNumber(value: useZashboard),
        ]
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
