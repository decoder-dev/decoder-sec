import NetworkExtension
import SwiftUI

struct DiagnosticsView: View {
    @EnvironmentObject private var store: ConfigurationStore
    @EnvironmentObject private var tunnel: TunnelManager
    @EnvironmentObject private var routing: RoutingProfileStore

    @State private var note: String?

    var body: some View {
        Form {
            Section(String(localized: "Tunnel")) {
                row(String(localized: "Lifecycle"), tunnel.lifecyclePhase.displaySummary)
                row(String(localized: "VPN status"), vpnStatusText)
                row(String(localized: "Core running"), boolText(tunnel.coreRunning))
                row(String(localized: "Last error"), displayedCoreError)
                if let stage = tunnel.tunnelDiagnostics.startupStage, !stage.isEmpty {
                    row(String(localized: "Core startup"), stage)
                }
                if let path = tunnel.tunnelDiagnostics.lastErrorFile, !path.isEmpty {
                    row(String(localized: "Last error file"), path)
                }
                if let seconds = tunnel.tunnelDiagnostics.sessionSeconds {
                    row(String(localized: "Session"), "\(seconds)s")
                }
            }

            Section(String(localized: "Traffic")) {
                if tunnel.tunnelTraffic.available {
                    row(String(localized: "↓ Down"), ByteCountFormatter.string(fromByteCount: tunnel.tunnelTraffic.down, countStyle: .binary))
                    row(String(localized: "↑ Up"), ByteCountFormatter.string(fromByteCount: tunnel.tunnelTraffic.up, countStyle: .binary))
                } else {
                    row(String(localized: "Traffic"), tunnel.tunnelTraffic.reason ?? String(localized: "unavailable"))
                }
            }

            Section(String(localized: "Geo resources")) {
                row(String(localized: "Needs geoip.dat"), geoRow(
                    tunnel.tunnelDiagnostics.geoNeedsGeoip,
                    tunnel.tunnelDiagnostics.geoHasGeoip
                ))
                row(String(localized: "Needs geosite.dat"), geoRow(
                    tunnel.tunnelDiagnostics.geoNeedsGeosite,
                    tunnel.tunnelDiagnostics.geoHasGeosite
                ))
                row(String(localized: "Geo rules stripped"), boolText(tunnel.tunnelDiagnostics.geoStripped))
                if let path = tunnel.tunnelDiagnostics.resourcesPath {
                    row(String(localized: "Extension resources path"), path)
                }
                if let err = tunnel.tunnelDiagnostics.resourcesPathError {
                    row(String(localized: "Resources path error"), err)
                }
            }

            if !tunnel.tunnelDiagnostics.hazards.isEmpty {
                Section(String(localized: "iOS hazards (auto-fixed before start)")) {
                    row(String(localized: "Detected"), tunnel.tunnelDiagnostics.hazards.joined(separator: ", "))
                }
            }

            Section(String(localized: "Routing")) {
                row(String(localized: "Routing enabled"), boolText(routing.routingEnabled))
                row(String(localized: "Active routing profile"), routing.activeProfile?.name ?? String(localized: "none"))
                row(String(localized: "Profiles count"), "\(routing.profiles.count)")
            }

            Section(String(localized: "Xray config")) {
                row(String(localized: "Active Xray config"), activeXray?.name ?? String(localized: "none"))
                row(String(localized: "Outbound tags"), snapshot?.outboundTags.joined(separator: ", ") ?? "—")
                row(String(localized: "Resolved proxy tag"), snapshot?.resolvedProxyTag ?? String(localized: "none"))
                row(String(localized: "Routing rules"), snapshot.map { "\($0.routingRuleCount)" } ?? "—")
                row(String(localized: "Has catch-all"), boolText(snapshot?.hasCatchAll == true))
                row(String(localized: "Has balancer"), boolText(snapshot?.hasBalancer == true))
                row(String(localized: "DNS servers"), snapshot?.dnsServers.joined(separator: ", ") ?? "—")
                row(String(localized: "Uses geosite/geoip"), boolText(snapshot?.usesGeoRules == true))
            }

            Section(String(localized: "Actions")) {
                Button(String(localized: "Refresh core status")) {
                    tunnel.refreshCoreStatus(retries: 3)
                    note = String(localized: "Requested tunnel diagnostics.")
                }

                Button(String(localized: "Re-apply Happ routing to active Xray")) {
                    reapplyRouting()
                }
                .disabled(activeXray == nil || !routing.routingEnabled || routing.activeProfile == nil)

                Button(String(localized: "Reconnect VPN")) {
                    Task {
                        if tunnel.status.isActive {
                            await tunnel.setEnabled(false, configuration: store.active)
                        }
                        await tunnel.setEnabled(true, configuration: effectiveActiveConfiguration())
                    }
                }
                .disabled(effectiveActiveConfiguration() == nil)
            }

            if let note {
                Section(String(localized: "Result")) {
                    Text(note)
                        .font(.footnote)
                }
            }
        }
        .navigationTitle(String(localized: "Diagnostics"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if tunnel.status == .connected {
                tunnel.refreshCoreStatus(retries: 5)
                tunnel.refreshTraffic()
                tunnel.refreshLogs()
            }
        }
    }

    private func boolText(_ value: Bool) -> String {
        value ? String(localized: "yes") : String(localized: "no")
    }

    private var displayedCoreError: String {
        if let err = tunnel.tunnelDiagnostics.coreError,
           !err.isEmpty, err != "Core is not running." {
            return err
        }
        if let err = tunnel.lastError, !err.isEmpty { return err }
        if tunnel.status == .connected, !tunnel.coreRunning,
           let line = tunnel.tunnelLogs.last(where: {
               $0.lowercased().contains("evcorestartcore") && (
                   $0.lowercased().contains("failed") || $0.lowercased().contains("watchdog")
               )
           }) {
            return line
        }
        if tunnel.status == .connected, !tunnel.coreRunning,
           let stage = tunnel.tunnelDiagnostics.startupStage,
           !stage.isEmpty {
            return stage
        }
        if tunnel.status == .connected, !tunnel.coreRunning {
            return String(localized: "Core startup state unavailable — tap Refresh core status")
        }
        return "—"
    }

    private func geoRow(_ needed: Bool, _ present: Bool) -> String {
        if !needed { return String(localized: "not required") }
        return present
            ? String(localized: "present")
            : String(localized: "missing (auto-download on connect)")
    }

    private var activeXray: Configuration? {
        if let id = store.activeIDByCoreType[.xray] {
            return store.configurations.first(where: { $0.id == id })
        }
        return store.configurations.first(where: { $0.coreType == .xray })
    }

    private func effectiveActiveConfiguration() -> Configuration? {
        if let active = store.active { return active }
        return store.configurationsForSelectedCore.first
    }

    private var vpnStatusText: String {
        switch tunnel.status {
        case .connected: return String(localized: "connected")
        case .connecting: return String(localized: "connecting")
        case .disconnecting: return String(localized: "disconnecting")
        case .disconnected: return String(localized: "disconnected")
        case .reasserting: return String(localized: "reasserting")
        case .invalid: return String(localized: "invalid")
        @unknown default: return String(localized: "unknown")
        }
    }

    private func row(_ key: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(key).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.body)
        }
    }

    private var snapshot: XraySnapshot? {
        guard let cfg = activeXray else { return nil }
        return XraySnapshot.from(json: cfg.content)
    }

    private func reapplyRouting() {
        guard let cfg = activeXray else {
            note = String(localized: "No active Xray configuration.")
            return
        }
        guard routing.routingEnabled, let profile = routing.activeProfile else {
            note = String(localized: "Routing is disabled or no active routing profile.")
            return
        }
        do {
            let updated = try HappRoutingApplier.apply(profile: profile, toXrayJSON: cfg.content)
            store.update(cfg, content: updated)
            note = String(format: String(localized: "Routing re-applied to %@."), cfg.name)
        } catch {
            note = String(format: String(localized: "Routing apply failed: %@"), error.localizedDescription)
        }
    }
}

private struct XraySnapshot {
    var outboundTags: [String]
    var resolvedProxyTag: String?
    var routingRuleCount: Int
    var hasCatchAll: Bool
    var hasBalancer: Bool
    var dnsServers: [String]
    var usesGeoRules: Bool

    static func from(json: String) -> XraySnapshot? {
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let outbounds = (root["outbounds"] as? [[String: Any]]) ?? []
        let tags = outbounds.compactMap { $0["tag"] as? String }
        let proxy = resolveProxyTag(from: outbounds)

        let routing = (root["routing"] as? [String: Any]) ?? [:]
        let rules = (routing["rules"] as? [[String: Any]]) ?? []

        let hasCatchAll = rules.contains(where: looksLikeCatchAll)
        let hasBalancer = (routing["balancers"] as? [Any])?.isEmpty == false
            || rules.contains(where: { $0["balancerTag"] != nil })

        var dns: [String] = []
        if let dnsObj = root["dns"] as? [String: Any],
           let servers = dnsObj["servers"] as? [Any] {
            dns = servers.compactMap {
                if let s = $0 as? String { return s }
                if let o = $0 as? [String: Any] { return o["address"] as? String }
                return nil
            }
        }

        return XraySnapshot(
            outboundTags: tags,
            resolvedProxyTag: proxy,
            routingRuleCount: rules.count,
            hasCatchAll: hasCatchAll,
            hasBalancer: hasBalancer,
            dnsServers: dns,
            usesGeoRules: GeoResourceBootstrap.referencesGeosite(json) || GeoResourceBootstrap.referencesGeoip(json)
        )
    }

    private static func resolveProxyTag(from outbounds: [[String: Any]]) -> String? {
        if outbounds.contains(where: { ($0["tag"] as? String) == "proxy" }) {
            return "proxy"
        }
        for item in outbounds {
            guard let tag = item["tag"] as? String, !tag.isEmpty else { continue }
            let lower = tag.lowercased()
            if lower == "direct" || lower == "block" || lower == "dns_out" || lower == "dns-out" { continue }
            let proto = (item["protocol"] as? String)?.lowercased() ?? ""
            if proto == "freedom" || proto == "blackhole" { continue }
            return tag
        }
        return nil
    }

    private static func looksLikeCatchAll(_ rule: [String: Any]) -> Bool {
        guard let type = rule["type"] as? String, type == "field" else { return false }
        let hasDomain = (rule["domain"] as? [Any])?.isEmpty == false
        let hasIP = (rule["ip"] as? [Any])?.isEmpty == false
        let hasPort = rule["port"] != nil
        let hasProtocol = rule["protocol"] != nil
        let hasInboundTag = rule["inboundTag"] != nil
        let hasProcess = rule["process"] != nil
        let hasForward = rule["outboundTag"] != nil || rule["balancerTag"] != nil
        return hasForward && !hasDomain && !hasIP && !hasPort && !hasProtocol && !hasInboundTag && !hasProcess
    }
}
