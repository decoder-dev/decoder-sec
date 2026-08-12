//
//  PacketTunnelProvider.swift
//  DecoderSec
//
//  Startup follows NodePassProject/Everywhere: synchronous EvcoreStartCore,
//  completionHandler(nil) even when the core fails so IPC can report coreError.
//

import EverywhereCore
import Network
import NetworkExtension

@objc(PacketTunnelProvider)
final class PacketTunnelProvider: NEPacketTunnelProvider {
    private static let tunnelMTU = 1500

    private var coreStarted = false
    private var coreError: String?
    private var resourcesPathError: String?
    private var lastConfigContent: String?
    private var lastPreparedXray: XrayNormalizer.TunnelPreparedConfig?
    private var lastCoreType: CoreType = .xray
    private var lastUseZashboard = false
    private var geoStripped = false
    private var sessionStartedAt: Date?

    private var pathMonitor: NWPathMonitor?
    private let pathMonitorQueue = DispatchQueue(label: "com.decodersec.app.pathMonitor", qos: .utility)
    private var pendingPathUpdate: DispatchWorkItem?
    private var latestPath: Network.NWPath?
    private static let pathDebounceInterval: DispatchTimeInterval = .milliseconds(1000)

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        coreStarted = false
        coreError = nil
        resourcesPathError = nil
        lastConfigContent = nil
        lastPreparedXray = nil
        geoStripped = false
        sessionStartedAt = Date()
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

        lastCoreType = payload.coreType
        lastUseZashboard = payload.useZashboard
        lastConfigContent = payload.configContent
        TunnelLogBuffer.shared.append("payload core=\(payload.coreType.rawValue) zashboard=\(payload.useZashboard)")

        let configContent: String
        do {
            configContent = try prepareConfig(payload)
        } catch {
            coreError = error.localizedDescription
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
                self.coreError = error.localizedDescription
                TunnelLogBuffer.shared.append("setTunnelNetworkSettings failed: \(error.localizedDescription)")
                completionHandler(error)
                return
            }

            let fd = TunnelFD.lookup(for: self.packetFlow)
            if fd < 0 {
                self.coreError = "could not obtain TUN file descriptor"
                TunnelLogBuffer.shared.append(self.coreError!)
                completionHandler(NSError(
                    domain: "DecoderSec",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: self.coreError!]
                ))
                return
            }
            TunnelLogBuffer.shared.append("TUN fd=\(fd)")

            let resPath = EVCore.resourcesURL(for: payload.coreType).path
            var resErr: NSError?
            if !EvcoreSetResourcesPath(resPath, &resErr), let resErr {
                self.resourcesPathError = resErr.localizedDescription
                TunnelLogBuffer.shared.append("SetResourcesPath failed: \(resErr.localizedDescription)")
            }

            var coreErr: NSError?
            _ = EvcoreStopAll(&coreErr)
            coreErr = nil

            let started = self.startCore(
                payload: payload,
                primaryConfig: configContent,
                tunFD: Int(fd),
                coreErr: &coreErr
            )

            guard started else {
                var message = Self.describeCoreError(coreErr)
                if self.geoStripped {
                    message += " (geo rules were stripped — missing .dat in extension)"
                }
                self.coreStarted = false
                self.coreError = message
                TunnelLogBuffer.shared.append("EvcoreStartCore failed: \(message)")
                completionHandler(nil)
                return
            }

            self.coreStarted = true
            self.coreError = nil
            TunnelLogBuffer.shared.append("EvcoreStartCore OK")
            self.startPathMonitor()
            completionHandler(nil)
        }
    }

    /// Android libv2ray: pass JSON close to provider config; retry hardened normalize on failure.
    private func startCore(
        payload: TunnelConfigPayload,
        primaryConfig: String,
        tunFD: Int,
        coreErr: inout NSError?
    ) -> Bool {
        var candidates: [(label: String, json: String)] = [("minimal", primaryConfig)]
        if payload.coreType == .xray, let prepared = lastPreparedXray, prepared.hardened != prepared.minimal {
            candidates.append(("hardened", prepared.hardened))
        }

        for (index, candidate) in candidates.enumerated() {
            if index > 0 {
                var stopErr: NSError?
                _ = EvcoreStopAll(&stopErr)
                coreErr = nil
            }
            TunnelLogBuffer.shared.append("EvcoreStartCore try \(candidate.label) (\(candidate.json.utf8.count) bytes)")
            if EvcoreStartCore(
                payload.coreType.rawValue,
                candidate.json,
                tunFD,
                Self.tunnelMTU,
                &coreErr
            ) {
                if index > 0 {
                    TunnelLogBuffer.shared.append("EvcoreStartCore OK (\(candidate.label) fallback)")
                }
                return true
            }
            let message = Self.describeCoreError(coreErr)
            TunnelLogBuffer.shared.append("EvcoreStartCore \(candidate.label) failed: \(message)")
        }
        return false
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
            geoStripped = stripGeo
            if stripGeo, let missing = status.missingSummary {
                TunnelLogBuffer.shared.append("missing geo (\(missing)) — stripping geosite/geoip rules")
                // Never block startTunnel on geo download — iOS kills the extension (~30s budget).
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
            }
            let prepared = try XrayNormalizer.prepareForTunnel(
                raw,
                useZashboard: payload.useZashboard,
                stripGeoRules: stripGeo
            )
            lastPreparedXray = prepared
            return prepared.minimal
        }
        return try ConfigNormalizer.normalize(raw, for: payload.coreType, useZashboard: payload.useZashboard)
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        TunnelLogBuffer.shared.append("stopTunnel reason=\(reason.rawValue)")
        stopPathMonitor()
        coreStarted = false

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
        var payload: [String: Any] = [
            "running": coreStarted,
            "geoStripped": geoStripped,
        ]
        if let err = coreError, !err.isEmpty {
            payload["error"] = err
        } else if !coreStarted {
            payload["error"] = "Core is not running."
        }
        payload["resourcesPath"] = EVCore.resourcesURL(for: lastCoreType).path
        if let resourcesPathError {
            payload["resourcesPathError"] = resourcesPathError
        }
        if let started = sessionStartedAt {
            payload["sessionSeconds"] = Int(Date().timeIntervalSince(started))
        }

        if let config = lastConfigContent {
            let geo = GeoResourceBootstrap.status(forConfig: config, in: EVCore.resourcesURL(for: .xray))
            payload["geoNeedsGeoip"] = geo.needsGeoip
            payload["geoNeedsGeosite"] = geo.needsGeosite
            payload["geoHasGeoip"] = geo.hasGeoip
            payload["geoHasGeosite"] = geo.hasGeosite
        }
        return payload
    }

    /// Clash controller lives inside the NE when Dashboard is enabled for mihomo/sing-box.
    /// Xray has no Evcore traffic API — report unavailable.
    private func trafficPayload() -> [String: Any] {
        guard coreStarted else {
            return ["available": false, "reason": "core not running"]
        }
        guard lastUseZashboard, lastCoreType != .xray else {
            return [
                "available": false,
                "reason": lastCoreType == .xray
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
