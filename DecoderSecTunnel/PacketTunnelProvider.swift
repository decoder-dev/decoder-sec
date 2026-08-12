//
//  PacketTunnelProvider.swift
//  DecoderSec
//
//  Startup follows NodePassProject/Everywhere: synchronous EvcoreStartCore,
//  completionHandler(nil) even when the core fails so IPC can report coreError.
//
//  Threading note (beta.32): `EvcoreStartCore` is a synchronous cgo call into
//  Xray/sing-box/mihomo. iOS delivers every NEProvider callback — startTunnel,
//  handleAppMessage, stopTunnel, sleep/wake — serialized on one internal
//  queue (same pattern documented by WireGuardKit/Mullvad's PacketTunnelProvider:
//  they dispatch tunnel bring-up onto their own queue for the same reason).
//  Running EvcoreStartCore inline on that queue means a slow or hung core
//  start (Happ balancer configs probing an unreachable outbound, DNS lookups
//  with no timeout, etc.) also starves `handleAppMessage` — the app's
//  `sendProviderMessage` calls queue up behind it and never get a reply.
//  That is what "Tunnel up — starting core..." stuck forever with no error
//  looks like: the extension is alive, but Diagnostics can't ask it anything.
//  `coreQueue` below keeps all Evcore calls off that shared queue so IPC
//  always answers, even mid-hang; `stateLock` protects the state the two
//  queues both touch.
//

import EverywhereCore
import Network
import NetworkExtension

@objc(PacketTunnelProvider)
final class PacketTunnelProvider: NEPacketTunnelProvider {
    private static let tunnelMTU = 1500
    private static let startWatchdogSeconds: Double = 12
    private static let retryWatchdogSeconds: Double = 8

    private let coreQueue = DispatchQueue(label: "com.decodersec.app.tunnel.core", qos: .userInitiated)
    private let stateLock = NSLock()

    private var coreStarted = false
    private var coreError: String?
    private var resourcesPathError: String?
    private var lastConfigContent: String?
    private var lastCoreType: CoreType = .xray
    private var lastUseZashboard = false
    private var geoStripped = false
    private var sessionStartedAt: Date?
    private var startWatchdog: DispatchWorkItem?

    private var pathMonitor: NWPathMonitor?
    private let pathMonitorQueue = DispatchQueue(label: "com.decodersec.app.pathMonitor", qos: .utility)
    private var pendingPathUpdate: DispatchWorkItem?
    private var latestPath: Network.NWPath?
    private static let pathDebounceInterval: DispatchTimeInterval = .milliseconds(1000)

    /// All reads/writes of the `private var`s above go through this so the
    /// NEProvider callback queue and `coreQueue` never race on them.
    private func withState<T>(_ body: () -> T) -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return body()
    }

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        withState {
            coreStarted = false
            coreError = nil
            resourcesPathError = nil
            lastConfigContent = nil
            geoStripped = false
            sessionStartedAt = Date()
        }
        withState { startWatchdog?.cancel(); startWatchdog = nil }
        TunnelLogBuffer.shared.append("startTunnel begin")

        let providerConfig = (protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration

        guard let payload = TunnelConfigPayload.decode(options: options, providerConfiguration: providerConfig) else {
            let msg = "missing configContent — start the tunnel from the app once"
            TunnelLogBuffer.shared.append(msg)
            completionHandler(NSError(domain: "DecoderSec", code: -2, userInfo: [
                NSLocalizedDescriptionKey: msg
            ]))
            return
        }

        withState {
            lastCoreType = payload.coreType
            lastUseZashboard = payload.useZashboard
            lastConfigContent = payload.configContent
        }
        TunnelLogBuffer.shared.append("payload core=\(payload.coreType.rawValue) zashboard=\(payload.useZashboard)")

        let configContent: String
        do {
            configContent = try prepareConfig(payload)
        } catch {
            withState { coreError = error.localizedDescription }
            TunnelLogBuffer.shared.append("prepareConfig failed: \(error.localizedDescription)")
            completionHandler(error)
            return
        }

        let settings = Self.makeTunnelSettings(mtu: Self.tunnelMTU, dnsServers: payload.dnsServers)
        setTunnelNetworkSettings(settings) { [weak self] error in
            guard let self else {
                completionHandler(NSError(domain: "DecoderSec", code: -5, userInfo: [
                    NSLocalizedDescriptionKey: "Tunnel provider deallocated during startup."
                ]))
                return
            }
            if let error {
                self.withState { self.coreError = error.localizedDescription }
                TunnelLogBuffer.shared.append("setTunnelNetworkSettings failed: \(error.localizedDescription)")
                completionHandler(error)
                return
            }

            // Hand off to coreQueue immediately — see threading note above.
            self.coreQueue.async {
                self.bootCore(payload: payload, configContent: configContent, completionHandler: completionHandler)
            }
        }
    }

    private func prepareConfig(_ payload: TunnelConfigPayload) throws -> String {
        // Node selection is already applied by the app via TunnelManager.effectiveContent.
        let raw = payload.configContent
        if payload.coreType == .xray {
            let dir = EVCore.resourcesURL(for: .xray)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            if GeoResourceBootstrap.seedBundledGeoIfNeeded(into: dir) {
                TunnelLogBuffer.shared.append("seeded bundled geo from appex")
            }
            let status = GeoResourceBootstrap.status(forConfig: raw, in: dir)
            let stripGeo = !status.isReady
            withState { geoStripped = stripGeo }
            if stripGeo, let missing = status.missingSummary {
                TunnelLogBuffer.shared.append("missing geo (\(missing)) — stripping geosite/geoip rules")
                DispatchQueue.global(qos: .utility).async {
                    GeoResourceBootstrap.tryEnsurePresent(forConfig: raw, in: dir) { ok in
                        if ok {
                            TunnelLogBuffer.shared.append("geo download complete — reconnect for full routing")
                        } else {
                            TunnelLogBuffer.shared.append("geo download failed — traffic uses stripped rules")
                        }
                    }
                }
            } else if status.needsGeoip || status.needsGeosite {
                TunnelLogBuffer.shared.append("geo resources ready")
            } else {
                let hazards = XrayNormalizer.iosHazards(in: raw)
                TunnelLogBuffer.shared.append("prepare xray hazards=\(hazards.isEmpty ? "none" : hazards.joined(separator: ","))")
            }
            // Always ios-safe (flatten balancer, strip DNS localhost) — Android keeps
            // observatory with balancers; we cannot run probes reliably inside NE.
            return try XrayNormalizer.normalize(raw, useZashboard: payload.useZashboard, stripGeoRules: stripGeo)
        }
        return try ConfigNormalizer.normalize(raw, for: payload.coreType, useZashboard: payload.useZashboard)
    }

    // MARK: - Core boot (coreQueue only)

    /// Runs entirely on `coreQueue`. Looks up the TUN fd, points the core at
    /// the extension's Resources dir, then calls `EvcoreStartCore`. If that
    /// fails with an error that looks like a missing geosite/geoip category
    /// (Xray-core refuses to start at all in that case — see
    /// `looksLikeGeoCategoryFailure`) and we did NOT already strip geo rules,
    /// retries once with `stripGeoRules` forced — Happ's bundled category
    /// names don't always exist in whatever geoip/geosite.dat we shipped.
    private func bootCore(
        payload: TunnelConfigPayload,
        configContent: String,
        completionHandler: @escaping (Error?) -> Void
    ) {
        let fd = TunnelFD.lookup(for: self.packetFlow)
        if fd < 0 {
            let msg = "could not obtain TUN file descriptor"
            withState { coreError = msg }
            TunnelLogBuffer.shared.append(msg)
            completionHandler(NSError(domain: "DecoderSec", code: -1, userInfo: [NSLocalizedDescriptionKey: msg]))
            return
        }
        TunnelLogBuffer.shared.append("TUN fd=\(fd)")

        let resPath = EVCore.resourcesURL(for: payload.coreType).path
        var resErr: NSError?
        if !EvcoreSetResourcesPath(resPath, &resErr), let resErr {
            withState { resourcesPathError = resErr.localizedDescription }
            TunnelLogBuffer.shared.append("SetResourcesPath failed: \(resErr.localizedDescription)")
        }

        var stopErr: NSError?
        _ = EvcoreStopAll(&stopErr)

        let hazards = payload.coreType == .xray
            ? XrayNormalizer.iosHazards(in: payload.configContent)
            : []
        if !hazards.isEmpty {
            TunnelLogBuffer.shared.append("ios-safe normalize for: \(hazards.joined(separator: ","))")
        }

        let outcome = attemptStart(
            coreTypeRaw: payload.coreType.rawValue,
            content: configContent,
            fd: fd,
            timeoutSeconds: Self.startWatchdogSeconds,
            completionHandler: completionHandler
        )

        switch outcome {
        case .started:
            finishSuccess(completionHandler: completionHandler)

        case .timedOut:
            // Watchdog already reported failure and called completionHandler.
            return

        case .failed(let coreErr):
            let message = Self.describeCoreError(coreErr)
            let alreadyStripped = withState { geoStripped }
            guard !alreadyStripped,
                  payload.coreType == .xray,
                  Self.looksLikeGeoCategoryFailure(message),
                  let retryContent = try? XrayNormalizer.normalize(
                      payload.configContent, useZashboard: payload.useZashboard, stripGeoRules: true
                  ) else {
                finishFailure(message: message, hazards: hazards, completionHandler: completionHandler)
                return
            }

            TunnelLogBuffer.shared.append("EvcoreStartCore failed (\(message)) — retrying with geo rules stripped")
            withState { geoStripped = true }
            var retryStopErr: NSError?
            _ = EvcoreStopAll(&retryStopErr)

            let retryOutcome = attemptStart(
                coreTypeRaw: payload.coreType.rawValue,
                content: retryContent,
                fd: fd,
                timeoutSeconds: Self.retryWatchdogSeconds,
                completionHandler: completionHandler
            )
            switch retryOutcome {
            case .started:
                TunnelLogBuffer.shared.append("EvcoreStartCore OK after geo-strip retry")
                finishSuccess(completionHandler: completionHandler)
            case .timedOut:
                return
            case .failed(let retryErr):
                finishFailure(message: Self.describeCoreError(retryErr), hazards: hazards, completionHandler: completionHandler)
            }
        }
    }

    private enum CoreAttemptOutcome {
        case started
        case timedOut
        case failed(NSError?)
    }

    /// Single `EvcoreStartCore` attempt with its own watchdog. On timeout the
    /// watchdog itself finalizes state and calls `completionHandler` — the
    /// caller must return immediately on `.timedOut` without calling it again.
    private func attemptStart(
        coreTypeRaw: String,
        content: String,
        fd: Int32,
        timeoutSeconds: Double,
        completionHandler: @escaping (Error?) -> Void
    ) -> CoreAttemptOutcome {
        let finishState = StartFinishState()
        let watchdog = DispatchWorkItem { [weak self] in
            guard finishState.markFinished() else { return }
            guard let self else { return }
            TunnelLogBuffer.shared.append("EvcoreStartCore watchdog \(Int(timeoutSeconds))s — aborting hung start")
            self.withState {
                self.coreStarted = false
                self.coreError = "Core start timed out (\(Int(timeoutSeconds))s). Happ balancer/observatory/DNS localhost — reconnect after update."
            }
            var stopErr: NSError?
            _ = EvcoreStopAll(&stopErr)
            completionHandler(nil)
        }
        withState { startWatchdog = watchdog }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeoutSeconds, execute: watchdog)

        TunnelLogBuffer.shared.append("EvcoreStartCore (\(content.utf8.count) bytes)")
        var coreErr: NSError?
        let started = EvcoreStartCore(coreTypeRaw, content, Int(fd), Self.tunnelMTU, &coreErr)

        watchdog.cancel()
        withState { startWatchdog = nil }
        guard finishState.markFinished() else {
            TunnelLogBuffer.shared.append("EvcoreStartCore returned after watchdog — ignored")
            return .timedOut
        }
        return started ? .started : .failed(coreErr)
    }

    private func finishSuccess(completionHandler: @escaping (Error?) -> Void) {
        withState {
            coreStarted = true
            coreError = nil
        }
        TunnelLogBuffer.shared.append("EvcoreStartCore OK")
        startPathMonitor()
        completionHandler(nil)
    }

    private func finishFailure(message: String, hazards: [String], completionHandler: @escaping (Error?) -> Void) {
        var message = message
        if withState({ geoStripped }) {
            message += " (geo rules were stripped — missing/incompatible .dat in extension)"
        }
        if !hazards.isEmpty {
            message += " [hazards: \(hazards.joined(separator: ","))]"
        }
        withState {
            coreStarted = false
            coreError = message
        }
        TunnelLogBuffer.shared.append("EvcoreStartCore failed: \(message)")
        completionHandler(nil)
    }

    /// Xray-core (`infra/conf`) refuses to start at all — not a hang, an
    /// immediate hard error — when a routing/DNS rule references a
    /// geosite/geoip category the loaded .dat doesn't contain, e.g.
    /// `infra/conf: failed to load geosite: WHITELIST-LV2 > infra/conf: list
    /// not found in geosite.dat: WHITELIST-LV2`. Happ ships its own curated
    /// geo files; our bundled roscomvpn set won't always have every category
    /// a given Happ config expects, so this is the realistic failure mode —
    /// not the missing-file case `GeoResourceBootstrap` already covers.
    private static func looksLikeGeoCategoryFailure(_ message: String) -> Bool {
        let lower = message.lowercased()
        guard lower.contains("geosite") || lower.contains("geoip") else { return false }
        return lower.contains("not found")
            || lower.contains("failed to load")
            || lower.contains("failed to parse")
            || lower.contains("no such file")
            || lower.contains("category")
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        TunnelLogBuffer.shared.append("stopTunnel reason=\(reason.rawValue)")
        stopPathMonitor()
        withState {
            coreStarted = false
            startWatchdog?.cancel()
            startWatchdog = nil
        }

        let lock = NSLock()
        var didComplete = false
        let complete = {
            lock.lock(); defer { lock.unlock() }
            guard !didComplete else { return }
            didComplete = true
            completionHandler()
        }

        DispatchQueue.global(qos: .userInitiated).async {
            var err: NSError?
            if !EvcoreStopAll(&err), let err {
                TunnelLogBuffer.shared.append("StopAll failed: \(err.localizedDescription)")
            } else {
                TunnelLogBuffer.shared.append("StopAll OK")
            }
            complete()
        }

        DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
            complete()
        }
    }

    override func sleep(completionHandler: @escaping () -> Void) {
        var err: NSError?
        _ = EvcoreSuspend(&err)
        TunnelLogBuffer.shared.append("suspend")
        completionHandler()
    }

    override func wake() {
        var err: NSError?
        _ = EvcoreResume(&err)
        TunnelLogBuffer.shared.append("resume")
    }

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        guard let json = try? JSONSerialization.jsonObject(with: messageData) as? [String: Any],
              let type = json["type"] as? String else {
            completionHandler?(nil)
            return
        }
        switch type {
        case "core-status", "diagnostics":
            completionHandler?(Self.encodeJSON(diagnosticsPayload()))
        case "logs":
            completionHandler?(Self.encodeJSON([
                "lines": TunnelLogBuffer.shared.snapshot(),
            ]))
        case "clear-logs":
            TunnelLogBuffer.shared.clear()
            TunnelLogBuffer.shared.append("log buffer cleared by app")
            completionHandler?(Self.encodeJSON(["ok": true]))
        case "traffic":
            completionHandler?(Self.encodeJSON(trafficPayload()))
        default:
            completionHandler?(nil)
        }
    }

    private func diagnosticsPayload() -> [String: Any] {
        let snapshot = withState {
            (
                started: coreStarted,
                error: coreError,
                resourcesPathError: resourcesPathError,
                coreType: lastCoreType,
                sessionStartedAt: sessionStartedAt,
                configContent: lastConfigContent,
                geoStripped: geoStripped
            )
        }

        var payload: [String: Any] = [
            "running": snapshot.started,
            "geoStripped": snapshot.geoStripped,
        ]
        if let err = snapshot.error, !err.isEmpty {
            payload["error"] = err
        } else if !snapshot.started {
            payload["error"] = "Core is not running."
        }
        payload["resourcesPath"] = EVCore.resourcesURL(for: snapshot.coreType).path
        if let resourcesPathError = snapshot.resourcesPathError {
            payload["resourcesPathError"] = resourcesPathError
        }
        if let started = snapshot.sessionStartedAt {
            payload["sessionSeconds"] = Int(Date().timeIntervalSince(started))
        }

        if let config = snapshot.configContent {
            let geo = GeoResourceBootstrap.status(forConfig: config, in: EVCore.resourcesURL(for: .xray))
            payload["geoNeedsGeoip"] = geo.needsGeoip
            payload["geoNeedsGeosite"] = geo.needsGeosite
            payload["geoHasGeoip"] = geo.hasGeoip
            payload["geoHasGeosite"] = geo.hasGeosite
            if snapshot.coreType == .xray {
                let hazards = XrayNormalizer.iosHazards(in: config)
                if !hazards.isEmpty {
                    payload["hazards"] = hazards
                }
            }
        }
        return payload
    }

    /// Clash controller lives inside the NE when Dashboard is enabled for mihomo/sing-box.
    /// Xray has no Evcore traffic API — report unavailable.
    private func trafficPayload() -> [String: Any] {
        let snapshot = withState { (started: coreStarted, useZashboard: lastUseZashboard, coreType: lastCoreType) }
        guard snapshot.started else {
            return ["available": false, "reason": "core not running"]
        }
        guard snapshot.useZashboard, snapshot.coreType != .xray else {
            return [
                "available": false,
                "reason": snapshot.coreType == .xray
                    ? "Xray has no traffic API in EverywhereCore"
                    : "Enable Dashboard to expose Clash traffic",
            ]
        }

        guard let url = URL(string: "http://127.0.0.1:9090/connections"),
              let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ["available": false, "reason": "Clash API unreachable"]
        }

        let upload = (json["uploadTotal"] as? NSNumber)?.int64Value
            ?? (json["uploadTotal"] as? Int).map(Int64.init)
            ?? 0
        let download = (json["downloadTotal"] as? NSNumber)?.int64Value
            ?? (json["downloadTotal"] as? Int).map(Int64.init)
            ?? 0
        return [
            "available": true,
            "up": upload,
            "down": download,
        ]
    }

    private static func encodeJSON(_ object: [String: Any]) -> Data? {
        try? JSONSerialization.data(withJSONObject: object)
    }

    private static func describeCoreError(_ error: NSError?) -> String {
        guard let error else { return "Core failed to start." }
        let text = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { return text }
        return "Core failed to start (domain \(error.domain), code \(error.code))."
    }

    private static func makeTunnelSettings(mtu: Int, dnsServers: [String]) -> NEPacketTunnelNetworkSettings {
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")

        let ipv4 = NEIPv4Settings(addresses: ["198.18.0.1"], subnetMasks: ["255.255.0.0"])
        ipv4.includedRoutes = [NEIPv4Route.default()]
        ipv4.excludedRoutes = []
        settings.ipv4Settings = ipv4

        let ipv6 = NEIPv6Settings(addresses: ["fd00::1"], networkPrefixLengths: [126])
        ipv6.includedRoutes = [NEIPv6Route.default()]
        ipv6.excludedRoutes = []
        settings.ipv6Settings = ipv6

        settings.dnsSettings = NEDNSSettings(servers: dnsServers)
        settings.mtu = NSNumber(value: mtu)
        return settings
    }

    private func startPathMonitor() {
        stopPathMonitor()
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] (path: Network.NWPath) in
            self?.schedulePathUpdate(path)
        }
        monitor.start(queue: pathMonitorQueue)
        pathMonitor = monitor
    }

    private func stopPathMonitor() {
        pendingPathUpdate?.cancel()
        pendingPathUpdate = nil
        pathMonitor?.cancel()
        pathMonitor = nil
    }

    private func schedulePathUpdate(_ path: Network.NWPath) {
        latestPath = path
        pendingPathUpdate?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let latest = self.latestPath else { return }
            self.handlePathUpdate(latest)
        }
        pendingPathUpdate = work
        pathMonitorQueue.asyncAfter(deadline: .now() + Self.pathDebounceInterval, execute: work)
    }

    private func handlePathUpdate(_ path: Network.NWPath) {
        var err: NSError?
        guard path.status == .satisfied, let iface = path.availableInterfaces.first else {
            _ = EvcoreUpdateDefaultInterface("", -1, false, false, &err)
            return
        }
        _ = EvcoreUpdateDefaultInterface(
            iface.name,
            Int32(iface.index),
            path.isExpensive,
            path.isConstrained,
            &err
        )
    }
}

/// Ensures a single `EvcoreStartCore` attempt's completion is only acted on
/// once (watchdog vs the call itself returning).
private final class StartFinishState {
    private let lock = NSLock()
    private var finished = false

    /// Returns true the first time; false if already finished.
    func markFinished() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if finished { return false }
        finished = true
        return true
    }
}
