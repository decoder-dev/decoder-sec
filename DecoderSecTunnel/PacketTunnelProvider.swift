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
    private var lastCoreType: CoreType = .xray
    private var geoStripped = false

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
        geoStripped = false

        let providerConfig = (protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration

        guard let payload = TunnelConfigPayload.decode(options: options, providerConfiguration: providerConfig) else {
            completionHandler(NSError(domain: "DecoderSec", code: -2, userInfo: [
                NSLocalizedDescriptionKey: "missing configContent — start the tunnel from the app once"
            ]))
            return
        }

        lastCoreType = payload.coreType
        lastConfigContent = payload.configContent

        let configContent: String
        do {
            configContent = try prepareConfig(payload)
        } catch {
            coreError = error.localizedDescription
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
                completionHandler(error)
                return
            }

            let fd = TunnelFD.lookup(for: self.packetFlow)
            if fd < 0 {
                self.coreError = "could not obtain TUN file descriptor"
                completionHandler(NSError(
                    domain: "DecoderSec",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: self.coreError!]
                ))
                return
            }

            let resPath = EVCore.resourcesURL(for: payload.coreType).path
            var resErr: NSError?
            if !EvcoreSetResourcesPath(resPath, &resErr), let resErr {
                self.resourcesPathError = resErr.localizedDescription
                NSLog("DecoderSec: SetResourcesPath failed: \(resErr)")
            }

            var coreErr: NSError?
            let started = EvcoreStartCore(
                payload.coreType.rawValue,
                configContent,
                Int(fd),
                Self.tunnelMTU,
                &coreErr
            )

            guard started else {
                var message = Self.describeCoreError(coreErr)
                if self.geoStripped {
                    message += " (geo rules were stripped — missing .dat in extension)"
                }
                self.coreStarted = false
                self.coreError = message
                NSLog("DecoderSec: EvcoreStartCore failed: \(message)")
                // Keep NE alive so the app can read coreError via IPC (Everywhere pattern).
                completionHandler(nil)
                return
            }

            self.coreStarted = true
            self.coreError = nil
            self.startPathMonitor()
            completionHandler(nil)
        }
    }

    private func prepareConfig(_ payload: TunnelConfigPayload) throws -> String {
        if payload.coreType == .xray {
            let dir = EVCore.resourcesURL(for: .xray)
            GeoResourceBootstrap.tryEnsurePresent(forConfig: payload.configContent, in: dir)
            let status = GeoResourceBootstrap.status(forConfig: payload.configContent, in: dir)
            let stripGeo = !status.isReady
            geoStripped = stripGeo
            if stripGeo, let missing = status.missingSummary {
                NSLog("DecoderSec: missing geo files (\(missing)) — stripping geosite/geoip rules")
            }
            return try XrayNormalizer.normalize(
                payload.configContent,
                useZashboard: payload.useZashboard,
                stripGeoRules: stripGeo
            )
        }
        return try ConfigNormalizer.normalize(
            payload.configContent,
            for: payload.coreType,
            useZashboard: payload.useZashboard
        )
    }

    override func stopTunnel(with _: NEProviderStopReason, completionHandler: @escaping () -> Void) {
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
                NSLog("DecoderSec: StopAll failed: \(err)")
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
        completionHandler()
    }

    override func wake() {
        var err: NSError?
        _ = EvcoreResume(&err)
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

        if let config = lastConfigContent {
            let geo = GeoResourceBootstrap.status(forConfig: config, in: EVCore.resourcesURL(for: .xray))
            payload["geoNeedsGeoip"] = geo.needsGeoip
            payload["geoNeedsGeosite"] = geo.needsGeosite
            payload["geoHasGeoip"] = geo.hasGeoip
            payload["geoHasGeosite"] = geo.hasGeosite
        }
        return payload
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
