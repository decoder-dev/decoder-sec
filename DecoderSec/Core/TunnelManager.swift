//
//  TunnelManager.swift
//  DecoderSec
//
//  Starts the Network Extension with the full config body.
//  No App Groups — NE never reads Core Data.
//

import Combine
import Foundation
import NetworkExtension

struct TunnelDiagnosticsSnapshot: Equatable {
    var coreRunning: Bool
    var coreError: String?
    var resourcesPath: String?
    var resourcesPathError: String?
    var geoNeedsGeoip: Bool
    var geoNeedsGeosite: Bool
    var geoHasGeoip: Bool
    var geoHasGeosite: Bool
    var geoStripped: Bool

    static let empty = TunnelDiagnosticsSnapshot(
        coreRunning: false,
        coreError: nil,
        resourcesPath: nil,
        resourcesPathError: nil,
        geoNeedsGeoip: false,
        geoNeedsGeosite: false,
        geoHasGeoip: false,
        geoHasGeosite: false,
        geoStripped: false
    )
}

final class TunnelManager: ObservableObject {
    static let shared = TunnelManager()

    @Published private(set) var status: NEVPNStatus = .disconnected
    @Published private(set) var isReady: Bool = false
    @Published private(set) var coreRunning: Bool = false
    @Published private(set) var lastError: String?
    @Published private(set) var tunnelDiagnostics: TunnelDiagnosticsSnapshot = .empty
    @Published private(set) var pendingReconnect: Bool = false
    private var manager: NETunnelProviderManager?
    private var statusObserver: AnyCancellable?

    private var didConnect: Bool = false

    private var transitionTimeoutTask: Task<Void, Never>?
    private static let transitionTimeoutNanos: UInt64 = 35 * 1_000_000_000

    private init() {
        setupStatusObserver()
        Task { await reload() }
    }

    func reload() async {
        do {
            let managers = try await NETunnelProviderManager.loadAllFromPreferences()
            let m = managers.first(where: {
                ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == EVCore.Identifier.networkExtension
            }) ?? managers.first ?? NETunnelProviderManager()
            self.manager = m
            self.status = m.connection.status
            self.isReady = true
            if m.connection.status == .connected {
                self.didConnect = true
                refreshCoreStatus(retries: 3)
            }
        } catch {
            self.lastError = Self.userFacingError(error)
            self.isReady = true
        }
    }

    func setEnabled(_ on: Bool, configuration: Configuration?) async {
        guard let configuration else {
            lastError = "No configuration is active."
            return
        }
        do {
            if on {
                didConnect = false
                coreRunning = false
                lastError = nil
                // Keep previous diagnostics until the new session reports.
                let m = try await ensureManager(configuration: configuration)
                let payload = TunnelConfigPayload(
                    configContent: configuration.content,
                    configID: configuration.id.uuidString,
                    coreType: configuration.coreType,
                    dnsServers: AppState.shared.dnsServers,
                    useZashboard: AppState.shared.useZashboardEnabled
                )
                try m.connection.startVPNTunnel(options: payload.asStartOptions)
            } else {
                pendingReconnect = false
                coreRunning = false
                try await disableTunnel()
            }
        } catch {
            lastError = Self.userFacingError(error)
            coreRunning = false
        }
    }

    func reconnect() async {
        guard manager != nil, status.isActive else { return }
        do {
            pendingReconnect = true
            try await disableTunnel()
        } catch {
            pendingReconnect = false
            lastError = Self.userFacingError(error)
        }
    }

    func applyAlwaysOn(_ enabled: Bool) async {
        if status.isActive {
            await reconnect()
            return
        }

        guard !enabled else { return }

        do {
            let managers = try await NETunnelProviderManager.loadAllFromPreferences()
            guard let m = managers.first(where: {
                ($0.protocolConfiguration as? NETunnelProviderProtocol)?
                    .providerBundleIdentifier == EVCore.Identifier.networkExtension
            }), m.isOnDemandEnabled else { return }
            m.isOnDemandEnabled = false
            m.onDemandRules = nil
            try await m.saveToPreferences()
            manager = m
        } catch {
            lastError = Self.userFacingError(error)
        }
    }

    func clearLastError() {
        lastError = nil
    }

    func refreshCoreStatus(retries: Int = 1) {
        queryTunnelMessage(type: "diagnostics", retries: retries) { [weak self] json in
            guard let self else { return }
            let running = json["running"] as? Bool ?? false
            let error = (json["error"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            self.coreRunning = running
            if let error, !error.isEmpty {
                self.lastError = error
            } else if running {
                self.lastError = nil
            } else if self.lastError == nil {
                self.lastError = "Core is not running."
            }
            self.tunnelDiagnostics = TunnelDiagnosticsSnapshot(
                coreRunning: running,
                coreError: error,
                resourcesPath: json["resourcesPath"] as? String,
                resourcesPathError: json["resourcesPathError"] as? String,
                geoNeedsGeoip: json["geoNeedsGeoip"] as? Bool ?? false,
                geoNeedsGeosite: json["geoNeedsGeosite"] as? Bool ?? false,
                geoHasGeoip: json["geoHasGeoip"] as? Bool ?? false,
                geoHasGeosite: json["geoHasGeosite"] as? Bool ?? false,
                geoStripped: json["geoStripped"] as? Bool ?? false
            )
            // Keep the tunnel up briefly when core failed so Diagnostics can show the error.
            // User can disconnect manually; we only auto-stop after a short delay.
            if self.status == .connected, !running {
                Task {
                    try? await Task.sleep(nanoseconds: 8_000_000_000)
                    guard self.status == .connected, !self.coreRunning else { return }
                    try? await self.disableTunnel()
                }
            }
        }
    }

    private func ensureManager(configuration: Configuration) async throws -> NETunnelProviderManager {
        let m = manager ?? NETunnelProviderManager()
        let proto = (m.protocolConfiguration as? NETunnelProviderProtocol) ?? NETunnelProviderProtocol()
        proto.providerBundleIdentifier = EVCore.Identifier.networkExtension
        proto.serverAddress = BrandIdentity.displayName
        proto.providerConfiguration = TunnelConfigPayload(
            configContent: configuration.content,
            configID: configuration.id.uuidString,
            coreType: configuration.coreType,
            dnsServers: AppState.shared.dnsServers,
            useZashboard: AppState.shared.useZashboardEnabled
        ).asProviderConfiguration
        proto.includeAllNetworks = AppState.shared.tunnelIncludeAllNetworks
        proto.excludeLocalNetworks = !AppState.shared.tunnelIncludeLocalNetworks
        if #available(iOS 16.4, *) {
            proto.excludeCellularServices = !AppState.shared.tunnelIncludeCellularServices
        }
        if #available(iOS 17.0, *) {
            proto.excludeAPNs = !AppState.shared.tunnelIncludeAPNs
        }
        m.protocolConfiguration = proto
        m.localizedDescription = EVCore.Identifier.tunnelDescription
        m.isEnabled = true

        if AppState.shared.alwaysOnEnabled {
            let rule = NEOnDemandRuleConnect()
            rule.interfaceTypeMatch = .any
            m.onDemandRules = [rule]
            m.isOnDemandEnabled = true
        } else {
            m.onDemandRules = nil
            m.isOnDemandEnabled = false
        }

        try await m.saveToPreferences()
        try await m.loadFromPreferences()
        manager = m
        return m
    }

    private func disableTunnel() async throws {
        guard let m = manager else { return }
        if m.isOnDemandEnabled {
            m.isOnDemandEnabled = false
            try await m.saveToPreferences()
        }
        m.connection.stopVPNTunnel()
    }

    private func setupStatusObserver() {
        statusObserver = NotificationCenter.default
            .publisher(for: .NEVPNStatusDidChange)
            .compactMap { $0.object as? NEVPNConnection }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] connection in
                guard let self else { return }
                guard connection === self.manager?.connection else { return }
                let previous = self.status
                self.status = connection.status
                self.scheduleTransitionTimeout(for: connection.status)
                self.trackConnectFailures(previous: previous, current: connection.status)
                if connection.status == .connected {
                    self.didConnect = true
                    self.refreshCoreStatus(retries: 5)
                } else {
                    self.coreRunning = false
                    // Do not wipe tunnelDiagnostics / lastError on disconnect — user needs them.
                    if (connection.status == .disconnected || connection.status == .invalid)
                        && self.pendingReconnect {
                        self.pendingReconnect = false
                        if let active = ConfigurationStore.shared.active {
                            Task { await self.setEnabled(true, configuration: active) }
                        }
                    }
                }
            }
    }

    private func trackConnectFailures(previous: NEVPNStatus, current: NEVPNStatus) {
        guard !didConnect,
              previous == .connecting,
              current == .disconnected || current == .disconnecting else { return }

        if let m = manager, m.isOnDemandEnabled {
            Task { try? await self.disableTunnel() }
            if lastError == nil {
                lastError = "Connection failed. On-demand was disabled — re-enable the tunnel to retry."
            }
            return
        }

        if lastError == nil {
            lastError = String(localized: "Connection failed before the tunnel came up. Open Diagnostics for details.")
        }
    }

    private func scheduleTransitionTimeout(for status: NEVPNStatus) {
        transitionTimeoutTask?.cancel()
        transitionTimeoutTask = nil
        guard status.isTransitioning else { return }
        transitionTimeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.transitionTimeoutNanos)
            guard !Task.isCancelled, let self else { return }
            await MainActor.run {
                guard self.status.isTransitioning else { return }
                Task { await self.forceReset() }
            }
        }
    }

    private func forceReset() async {
        pendingReconnect = false
        do {
            try await disableTunnel()
            if lastError == nil {
                lastError = "Tunnel reset after timing out. Open Diagnostics and tap Refresh core status for details."
            }
        } catch {
            lastError = Self.userFacingError(error)
        }
    }

    private func queryTunnelMessage(type: String, retries: Int, handler: @escaping ([String: Any]) -> Void) {
        guard let session = manager?.connection as? NETunnelProviderSession else { return }
        let message: [String: Any] = ["type": type]
        guard let data = try? JSONSerialization.data(withJSONObject: message) else { return }

        func attempt(remaining: Int, delaySeconds: Double) {
            DispatchQueue.main.asyncAfter(deadline: .now() + delaySeconds) {
                try? session.sendProviderMessage(data) { response in
                    if let response,
                       let json = try? JSONSerialization.jsonObject(with: response) as? [String: Any] {
                        DispatchQueue.main.async { handler(json) }
                        return
                    }
                    if remaining > 1 {
                        attempt(remaining: remaining - 1, delaySeconds: 0.6)
                    }
                }
            }
        }

        attempt(remaining: max(1, retries), delaySeconds: 0.35)
    }

    private static func userFacingError(_ error: Error) -> String {
        let nsError = error as NSError
        let text = nsError.localizedDescription
        let haystack = "\(nsError.domain) \(text)".lowercased()
        if haystack.contains("neconfiguration")
            || haystack.contains("nevpn")
            || haystack.contains("entitlement")
            || haystack.contains("permission")
            || haystack.contains("not authorized") {
            return "VPN is not available for this install. Resign the full IPA with a provisioning profile that includes Network Extension packet-tunnel, or use a Lite IPA for config browsing."
        }
        return text
    }
}

extension NEVPNStatus {
    var isTransitioning: Bool {
        self == .connecting || self == .disconnecting || self == .reasserting
    }

    var isActive: Bool {
        self == .connected || isTransitioning
    }
}
