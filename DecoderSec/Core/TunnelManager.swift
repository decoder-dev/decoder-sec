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
    var startupStage: String?
    var lastErrorFile: String?
    var resourcesPath: String?
    var resourcesPathError: String?
    var geoNeedsGeoip: Bool
    var geoNeedsGeosite: Bool
    var geoHasGeoip: Bool
    var geoHasGeosite: Bool
    var geoStripped: Bool
    var minimalBoot: Bool
    var sessionSeconds: Int?
    var hazards: [String]

    static let empty = TunnelDiagnosticsSnapshot(
        coreRunning: false,
        coreError: nil,
        startupStage: nil,
        lastErrorFile: nil,
        resourcesPath: nil,
        resourcesPathError: nil,
        geoNeedsGeoip: false,
        geoNeedsGeosite: false,
        geoHasGeoip: false,
        geoHasGeosite: false,
        geoStripped: false,
        minimalBoot: false,
        sessionSeconds: nil,
        hazards: []
    )
}

struct TunnelTrafficSnapshot: Equatable {
    var available: Bool
    var up: Int64
    var down: Int64
    var reason: String?

    static let unavailable = TunnelTrafficSnapshot(available: false, up: 0, down: 0, reason: nil)
}

final class TunnelManager: ObservableObject {
    static let shared = TunnelManager()

    @Published private(set) var status: NEVPNStatus = .disconnected
    @Published private(set) var lifecyclePhase: TunnelLifecyclePhase = .idle
    @Published private(set) var isReady: Bool = false
    @Published private(set) var coreRunning: Bool = false
    @Published private(set) var lastError: String?
    @Published private(set) var tunnelDiagnostics: TunnelDiagnosticsSnapshot = .empty
    @Published private(set) var tunnelLogs: [String] = []
    @Published private(set) var tunnelTraffic: TunnelTrafficSnapshot = .unavailable
    @Published private(set) var pendingReconnect: Bool = false
    @Published private(set) var connectedAt: Date?
    private var manager: NETunnelProviderManager?
    private var statusObserver: AnyCancellable?

    private var didConnect: Bool = false
    private var didAutoReconnectForGeo = false
    private var coreStartupWatchdogTask: Task<Void, Never>?

    private var transitionTimeoutTask: Task<Void, Never>?
    private static let transitionTimeoutNanos: UInt64 = 35 * 1_000_000_000

    /// Fires ~15s into `.connecting` with no extension log lines yet — long
    /// before the 35s hard `transitionTimeoutTask` reset — so the user gets
    /// an actionable ESign-entitlement diagnosis instead of silently waiting.
    private var connectWatchdogTask: Task<Void, Never>?
    private static let connectWatchdogNanos: UInt64 = 15 * 1_000_000_000

    /// Retained across a connect attempt so the silent-extension fallback
    /// (§ dual start) can retry with the full (non-lean) `startVPNTunnel`
    /// options without the caller having to rebuild the payload.
    private var pendingFallbackPayload: TunnelConfigPayload?
    private var didAttemptFullOptionsFallback = false

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
            self.updateLifecyclePhase()
            if m.connection.status == .connected {
                self.didConnect = true
                if self.connectedAt == nil { self.connectedAt = Date() }
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
            ClientLogBuffer.shared.append("setEnabled ignored — no active configuration")
            return
        }
        do {
            if on {
                didConnect = false
                coreRunning = false
                lastError = nil
                pendingFallbackPayload = nil
                didAttemptFullOptionsFallback = false
                lifecyclePhase = .preparingProfile
                let content = effectiveContent(for: configuration)
                let bytes = content.utf8.count
                ClientLogBuffer.shared.append(
                    "connect begin id=\(configuration.id.uuidString.prefix(8)) core=\(configuration.coreType.rawValue) bytes=\(bytes)"
                )
                ClientLogBuffer.shared.append(BundleIdentifiers.extensionPreflightReport())
                guard BundleIdentifiers.hasEmbeddedTunnelExtension else {
                    lastError = String(localized: "This IPA has no Packet Tunnel extension. Install the full DecoderSec.ipa (not lite) and resign in ESign with Network Extension enabled for app + extension.")
                    ClientLogBuffer.shared.append("FATAL: no PlugIns/*.appex — lite IPA or broken resign")
                    lifecyclePhase = .failed(lastError ?? "missing appex")
                    mergeClientLogsIntoConsole()
                    return
                }
                let m = try await ensureManager(configuration: configuration)
                let payload = TunnelConfigPayload(
                    configContent: content,
                    configID: configuration.id.uuidString,
                    coreType: configuration.coreType,
                    dnsServers: AppState.shared.dnsServers,
                    useZashboard: AppState.shared.useZashboardEnabled
                )
                try payload.validateSize()
                // Always lean: config lives in providerConfiguration only.
                // Putting JSON in startVPNTunnel(options:) can kill the appex
                // before startTunnel on some ESign/resign installs. Keep the
                // payload around so `attemptFullOptionsFallback` can retry
                // with `asStartOptions` if the lean path never reaches the
                // extension (see § dual start fallback).
                pendingFallbackPayload = payload
                let options = payload.asLeanStartOptions
                ClientLogBuffer.shared.append(
                    "startVPNTunnel lean options (config in VPN profile only, \(bytes) bytes)"
                )
                lifecyclePhase = .connecting
                try m.connection.startVPNTunnel(options: options)
                ClientLogBuffer.shared.append("startVPNTunnel accepted by system — waiting for Packet Tunnel")
                mergeClientLogsIntoConsole()
                scheduleConnectWatchdog()
            } else {
                pendingReconnect = false
                coreRunning = false
                cancelConnectWatchdog()
                ClientLogBuffer.shared.append("disconnect requested")
                try await disableTunnel()
                mergeClientLogsIntoConsole()
            }
        } catch {
            lastError = Self.userFacingError(error)
            coreRunning = false
            lifecyclePhase = .failed(lastError ?? error.localizedDescription)
            ClientLogBuffer.shared.append("connect/disconnect error: \(lastError ?? error.localizedDescription)")
            mergeClientLogsIntoConsole()
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

    func waitForTerminalStatus(timeoutSeconds: Double = 30) async {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while status.isTransitioning, Date() < deadline {
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    func effectiveContent(for configuration: Configuration) -> String {
        if configuration.coreType == .xray {
            return XrayNodeSelection.applySelection(to: configuration.content, configID: configuration.id)
        }
        return configuration.content
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
            }
            self.tunnelDiagnostics = TunnelDiagnosticsSnapshot(
                coreRunning: running,
                coreError: error,
                startupStage: json["startupStage"] as? String,
                lastErrorFile: json["lastErrorFile"] as? String,
                resourcesPath: json["resourcesPath"] as? String,
                resourcesPathError: json["resourcesPathError"] as? String,
                geoNeedsGeoip: json["geoNeedsGeoip"] as? Bool ?? false,
                geoNeedsGeosite: json["geoNeedsGeosite"] as? Bool ?? false,
                geoHasGeoip: json["geoHasGeoip"] as? Bool ?? false,
                geoHasGeosite: json["geoHasGeosite"] as? Bool ?? false,
                geoStripped: json["geoStripped"] as? Bool ?? false,
                minimalBoot: json["minimalBoot"] as? Bool ?? false,
                sessionSeconds: json["sessionSeconds"] as? Int,
                hazards: json["hazards"] as? [String] ?? []
            )
            self.reconcileCoreErrorFromLogs(fallback: error, running: running)
            self.maybeAutoReconnectAfterGeoDownload()
            self.updateLifecyclePhase()
        }
    }

    /// When IPC only returns the generic placeholder, prefer the last EvcoreStartCore line from NE logs.
    private func reconcileCoreErrorFromLogs(fallback: String?, running: Bool) {
        guard !running else { return }
        let generic = fallback == nil
            || fallback == "Core is not running."
            || fallback?.isEmpty == true
        guard generic else { return }
        refreshLogs()
        var diag = tunnelDiagnostics
        if let line = tunnelLogs.last(where: { $0.contains("EvcoreStartCore") && $0.lowercased().contains("failed") }) {
            let detail = line.replacingOccurrences(of: "EvcoreStartCore minimal failed: ", with: "")
                .replacingOccurrences(of: "EvcoreStartCore hardened failed: ", with: "")
                .replacingOccurrences(of: "EvcoreStartCore failed: ", with: "")
            lastError = detail
            diag.coreError = detail
        } else if let line = tunnelLogs.last(where: { logLineLooksLikeFailure($0) }) {
            lastError = line
            diag.coreError = line
        }
        tunnelDiagnostics = diag
    }

    /// After geo was stripped on first connect, reconnect once when extension finishes downloading .dat files.
    private func maybeAutoReconnectAfterGeoDownload() {
        guard status == .connected,
              tunnelDiagnostics.geoStripped,
              !didAutoReconnectForGeo else { return }
        let geo = tunnelDiagnostics
        let ready = (!geo.geoNeedsGeoip || geo.geoHasGeoip) && (!geo.geoNeedsGeosite || geo.geoHasGeosite)
        guard ready else { return }
        didAutoReconnectForGeo = true
        Task { await reconnect() }
    }

    private func scheduleCoreStartupWatchdog() {
        coreStartupWatchdogTask?.cancel()
        coreStartupWatchdogTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled, let self else { return }
            await MainActor.run {
                guard self.status == .connected, !self.coreRunning else { return }
                self.refreshCoreStatus(retries: 5)
                self.refreshLogs()
                self.reconcileCoreErrorFromLogs(fallback: self.tunnelDiagnostics.coreError, running: false)
                self.updateLifecyclePhase()
            }
        }
    }

    private func updateLifecyclePhase() {
        if let err = lastError, !err.isEmpty,
           status == .disconnected || status == .invalid {
            lifecyclePhase = .failed(err)
            return
        }

        switch status {
        case .invalid, .disconnected:
            lifecyclePhase = .idle
        case .connecting, .reasserting:
            lifecyclePhase = .connecting
        case .disconnecting:
            lifecyclePhase = .disconnecting
        case .connected:
            if coreRunning {
                lifecyclePhase = .ready
            } else if let err = tunnelDiagnostics.coreError, !err.isEmpty, err != "Core is not running." {
                lifecyclePhase = .coreFailed
            } else if lastError != nil {
                lifecyclePhase = .coreFailed
            } else {
                lifecyclePhase = .tunnelUpCorePending
            }
        @unknown default:
            lifecyclePhase = .idle
        }
    }

    private func ensureManager(configuration: Configuration) async throws -> NETunnelProviderManager {
        let neID = EVCore.Identifier.networkExtension
        // Drop stale VPN profiles that point at a different/old PacketTunnel id
        // (common after ESign remap or reinstall).
        let existing = try await NETunnelProviderManager.loadAllFromPreferences()
        for stale in existing {
            let proto = stale.protocolConfiguration as? NETunnelProviderProtocol
            let id = proto?.providerBundleIdentifier
            if id != neID {
                ClientLogBuffer.shared.append("removing stale VPN profile ne=\(id ?? "nil") (want \(neID))")
                try await stale.removeFromPreferences()
            }
        }

        let managers = try await NETunnelProviderManager.loadAllFromPreferences()
        let m = managers.first(where: {
            ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == neID
        }) ?? NETunnelProviderManager()
        manager = m

        let proto = (m.protocolConfiguration as? NETunnelProviderProtocol) ?? NETunnelProviderProtocol()
        proto.providerBundleIdentifier = neID
        proto.serverAddress = BrandIdentity.displayName
        let payload = TunnelConfigPayload(
            configContent: effectiveContent(for: configuration),
            configID: configuration.id.uuidString,
            coreType: configuration.coreType,
            dnsServers: AppState.shared.dnsServers,
            useZashboard: AppState.shared.useZashboardEnabled
        )
        try payload.validateSize()
        proto.providerConfiguration = payload.asProviderConfiguration
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

        // Apple/ESign gotcha: the `NETunnelProviderManager` instance you just
        // saved is not always the instance the system hands back for
        // `startVPNTunnel` — re-fetch the full list and match by NE bundle id
        // so we start against the on-disk profile, not a stale in-memory
        // object. `m.loadFromPreferences()` above refreshes `m`'s own
        // properties but has been observed (post-ESign-resign) to leave a
        // manager that `startVPNTunnel` silently no-ops on.
        let refetched = try await NETunnelProviderManager.loadAllFromPreferences()
        let fresh = refetched.first(where: {
            ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == neID
        }) ?? m
        ClientLogBuffer.shared.append(
            "manager refresh after save: candidates=\(refetched.count) usingFreshInstance=\(fresh !== m)"
        )

        if let saved = (fresh.protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration,
           let savedContent = saved[TunnelConfigPayload.configContentKey] as? String,
           !savedContent.isEmpty {
            ClientLogBuffer.shared.append("VPN profile saved OK (\(savedContent.utf8.count) bytes, ne=\(proto.providerBundleIdentifier ?? "?"))")
        } else {
            ClientLogBuffer.shared.append("WARNING: VPN profile missing configContent after save/load")
            throw NSError(
                domain: "DecoderSec",
                code: -40,
                userInfo: [NSLocalizedDescriptionKey: String(localized: "VPN profile did not keep the configuration. Try a smaller config or reinstall the IPA.")]
            )
        }
        manager = fresh
        return fresh
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
                if connection.status != .connecting && connection.status != .reasserting {
                    self.cancelConnectWatchdog()
                }
                self.updateLifecyclePhase()
                self.scheduleTransitionTimeout(for: connection.status)
                self.trackConnectFailures(previous: previous, current: connection.status)
                if connection.status == .connected {
                    self.didConnect = true
                    self.pendingFallbackPayload = nil
                    if self.connectedAt == nil { self.connectedAt = Date() }
                    self.refreshCoreStatus(retries: 5)
                    self.refreshTraffic()
                    self.scheduleCoreStartupWatchdog()
                } else {
                    self.coreStartupWatchdogTask?.cancel()
                    self.coreStartupWatchdogTask = nil
                    self.coreRunning = false
                    if connection.status == .disconnected || connection.status == .invalid {
                        self.connectedAt = nil
                        self.tunnelTraffic = .unavailable
                        self.didAutoReconnectForGeo = false
                    }
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

        fetchLastDisconnectError { [weak self] disconnectError in
            guard let self, let disconnectError else { return }
            ClientLogBuffer.shared.append("NEVPNConnection.lastDisconnectError: \(disconnectError)")
            self.mergeClientLogsIntoConsole()
        }

        if let m = manager, m.isOnDemandEnabled {
            Task { try? await self.disableTunnel() }
            if lastError == nil {
                lastError = "Connection failed. On-demand was disabled — re-enable the tunnel to retry."
            }
            return
        }

        captureStartupFailureReason()
        updateLifecyclePhase()
    }

    /// `NEVPNConnection.fetchLastDisconnectError` (iOS 16+) carries the
    /// system's own reason for the most recent disconnect — often the only
    /// concrete signal we get when the appex is refused launch entirely
    /// (e.g. a missing Network Extension entitlement after an ESign resign).
    /// Completion-handler based Apple API; always resolves on the main queue.
    private func fetchLastDisconnectError(_ completion: @escaping (String?) -> Void) {
        guard let connection = manager?.connection else {
            completion(nil)
            return
        }
        guard #available(iOS 16.0, *) else {
            completion(nil)
            return
        }
        connection.fetchLastDisconnectError { error in
            DispatchQueue.main.async {
                guard let error else {
                    completion(nil)
                    return
                }
                let nsError = error as NSError
                let text = nsError.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
                completion(text.isEmpty ? "\(nsError.domain) code=\(nsError.code)" : text)
            }
        }
    }

    /// startVPNTunnel returns before the extension finishes startTunnel — surface NE logs/errors here.
    private func captureStartupFailureReason() {
        ClientLogBuffer.shared.append("status connecting→disconnected without connected — probing extension")
        mergeClientLogsIntoConsole()
        refreshLogs()
        refreshCoreStatus(retries: 3)

        func resolve(from attempt: Int) {
            guard lastError == nil else { return }
            if let coreError = tunnelDiagnostics.coreError, !coreError.isEmpty {
                lastError = coreError
                ClientLogBuffer.shared.append("startup failure from diagnostics: \(coreError)")
                mergeClientLogsIntoConsole()
                updateLifecyclePhase()
                return
            }
            if let line = tunnelLogs.last(where: { logLineLooksLikeFailure($0) && !$0.contains("[app]") }) {
                lastError = line
                updateLifecyclePhase()
                return
            }
            if attempt >= 4 {
                let extensionSilent = !tunnelLogs.contains(where: { !$0.contains("[app]") })
                fetchLastDisconnectError { [weak self] disconnectError in
                    guard let self else { return }
                    if extensionSilent {
                        // Dual start fallback: some ESign resigns drop
                        // `providerConfiguration` off the persisted profile,
                        // so the lean options (no inline config) leave the
                        // extension with nothing to decode and it never
                        // logs. Retry once with the full inline options
                        // before giving up, for configs small enough for
                        // the XPC launch path.
                        if self.attemptFullOptionsFallback() { return }
                        var message = String(localized: "Packet Tunnel did not start. In ESign: sign the FULL IPA with a paid certificate that has Network Extension / packet-tunnel for BOTH the app and the .appex (free Apple ID cannot run VPN). Then delete the old app, install again, allow the VPN profile.")
                        if let disconnectError {
                            message += " " + String(localized: "System reported: \(disconnectError)")
                        }
                        self.lastError = message
                        ClientLogBuffer.shared.append(
                            "FATAL: extension never logged — \(BundleIdentifiers.extensionPreflightReport()) — check ESign Network Extension entitlement / wrong PacketTunnel bundle id"
                            + (disconnectError.map { " — lastDisconnectError=\($0)" } ?? "")
                        )
                    } else {
                        var message = String(localized: "Connection failed before the tunnel came up. Open Log console in Settings for details.")
                        if let disconnectError {
                            message += " (\(disconnectError))"
                        }
                        self.lastError = message
                    }
                    self.mergeClientLogsIntoConsole()
                    self.updateLifecyclePhase()
                }
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                guard let self else { return }
                self.refreshLogs()
                self.refreshCoreStatus(retries: 2)
                resolve(from: attempt + 1)
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            resolve(from: 0)
        }
    }

    /// One automatic retry of `startVPNTunnel` with `asStartOptions` (full
    /// inline config, not just the lean flag) when the lean start produced
    /// zero extension logs. Only for configs under
    /// `TunnelConfigPayload.maxStartOptionsConfigBytes` — large configs are
    /// exactly what lean options exist to avoid killing the appex for.
    private func attemptFullOptionsFallback() -> Bool {
        guard !didAttemptFullOptionsFallback,
              let payload = pendingFallbackPayload,
              payload.configContent.utf8.count <= TunnelConfigPayload.maxStartOptionsConfigBytes,
              let m = manager else { return false }
        didAttemptFullOptionsFallback = true

        ClientLogBuffer.shared.append(
            "lean start produced no extension logs — retrying once with full startVPNTunnel options (\(payload.configContent.utf8.count) bytes) in case ESign dropped providerConfiguration"
        )
        mergeClientLogsIntoConsole()

        do {
            lifecyclePhase = .connecting
            try m.connection.startVPNTunnel(options: payload.asStartOptions)
            ClientLogBuffer.shared.append("startVPNTunnel (full options) accepted by system — waiting for Packet Tunnel")
            mergeClientLogsIntoConsole()
            scheduleConnectWatchdog()
            return true
        } catch {
            ClientLogBuffer.shared.append("full-options retry failed to start: \(error.localizedDescription)")
            mergeClientLogsIntoConsole()
            return false
        }
    }

    /// Fires ~15s after `startVPNTunnel` is accepted if still `.connecting`
    /// with no extension log lines at all — well before the 35s hard
    /// transition-timeout reset — so the user sees an actionable diagnosis
    /// instead of a silent spinner.
    private func scheduleConnectWatchdog() {
        connectWatchdogTask?.cancel()
        connectWatchdogTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.connectWatchdogNanos)
            guard !Task.isCancelled, let self else { return }
            await MainActor.run { self.handleConnectWatchdog() }
        }
    }

    private func cancelConnectWatchdog() {
        connectWatchdogTask?.cancel()
        connectWatchdogTask = nil
    }

    private func handleConnectWatchdog() {
        guard status == .connecting || status == .reasserting else { return }
        refreshLogs()
        refreshCoreStatus(retries: 1)
        let extensionSilent = !tunnelLogs.contains(where: { !$0.contains("[app]") })
        fetchLastDisconnectError { [weak self] disconnectError in
            guard let self else { return }
            var probe = "connect watchdog 15s: status=\(self.status.rawValue) extensionSilent=\(extensionSilent)"
            if let disconnectError { probe += " lastDisconnectError=\(disconnectError)" }
            ClientLogBuffer.shared.append(probe)
            self.mergeClientLogsIntoConsole()

            guard extensionSilent, self.lastError == nil else { return }
            var message = String(localized: "Packet Tunnel has not started after 15s and produced no logs — likely a missing Network Extension / packet-tunnel entitlement on the .appex in this ESign resign. You can keep waiting or disconnect and re-sign with a certificate that includes Network Extension for BOTH the app and the .appex.")
            if let disconnectError {
                message += " " + String(localized: "System reported: \(disconnectError)")
            }
            self.lastError = message
            self.updateLifecyclePhase()
        }
    }

    /// Merge app-side connect logs into the console so empty extension logs are still useful.
    func mergeClientLogsIntoConsole() {
        let appLines = ClientLogBuffer.shared.snapshot()
        let neLines = tunnelLogs.filter { !$0.contains("[app]") }
        tunnelLogs = appLines + neLines
    }

    private func logLineLooksLikeFailure(_ line: String) -> Bool {
        let lower = line.lowercased()
        return lower.contains("failed")
            || lower.contains("missing")
            || lower.contains("error")
            || lower.contains("could not")
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

    func refreshLogs() {
        queryTunnelMessage(type: "logs", retries: 3) { [weak self] json in
            guard let self else { return }
            let neLines = (json["lines"] as? [String]) ?? []
            let appLines = ClientLogBuffer.shared.snapshot()
            self.tunnelLogs = appLines + neLines
        }
        // Always show app-side lines even when extension is dead.
        if tunnelLogs.isEmpty || !tunnelLogs.contains(where: { $0.contains("[app]") }) {
            mergeClientLogsIntoConsole()
        }
    }

    func clearLogs() {
        ClientLogBuffer.shared.clear()
        queryTunnelMessage(type: "clear-logs", retries: 1) { [weak self] _ in
            self?.tunnelLogs = ClientLogBuffer.shared.snapshot()
            self?.refreshLogs()
        }
        tunnelLogs = ClientLogBuffer.shared.snapshot()
    }

    func refreshTraffic() {
        queryTunnelMessage(type: "traffic", retries: 1) { [weak self] json in
            guard let self else { return }
            let available = json["available"] as? Bool ?? false
            let up = (json["up"] as? NSNumber)?.int64Value
                ?? (json["up"] as? Int).map(Int64.init)
                ?? 0
            let down = (json["down"] as? NSNumber)?.int64Value
                ?? (json["down"] as? Int).map(Int64.init)
                ?? 0
            self.tunnelTraffic = TunnelTrafficSnapshot(
                available: available,
                up: up,
                down: down,
                reason: json["reason"] as? String
            )
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
