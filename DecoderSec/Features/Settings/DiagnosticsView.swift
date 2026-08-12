import NetworkExtension
import SwiftUI

struct DiagnosticsView: View {
    @EnvironmentObject private var store: ConfigurationStore
    @EnvironmentObject private var tunnel: TunnelManager
    @EnvironmentObject private var routing: RoutingProfileStore

    @State private var note: String?

    var body: some View {
        Form {
            Section("Tunnel") {
                row("VPN status", vpnStatusText)
                row("Core running", tunnel.coreRunning ? "yes" : "no")
                row("Last error", displayedCoreError)
            }

            Section("Geo resources") {
                row("Needs geoip.dat", geoRow(
                    tunnel.tunnelDiagnostics.geoNeedsGeoip || (snapshot?.usesGeoRules == true),
                    tunnel.tunnelDiagnostics.geoHasGeoip
                ))
                row("Needs geosite.dat", geoRow(
                    tunnel.tunnelDiagnostics.geoNeedsGeosite || (snapshot?.usesGeoRules == true),
                    tunnel.tunnelDiagnostics.geoHasGeosite
                ))
                row("Geo rules stripped", tunnel.tunnelDiagnostics.geoStripped ? "yes" : "no")
                if let path = tunnel.tunnelDiagnostics.resourcesPath {
                    row("Extension resources path", path)
                }
                if let err = tunnel.tunnelDiagnostics.resourcesPathError {
                    row("Resources path error", err)
                }
            }

            Section("Routing") {
                row("Routing enabled", routing.routingEnabled ? "yes" : "no")
                row("Active routing profile", routing.activeProfile?.name ?? "none")
                row("Profiles count", "\(routing.profiles.count)")
            }

            Section("Xray config") {
                row("Active Xray config", activeXray?.name ?? "none")
                row("Outbound tags", snapshot?.outboundTags.joined(separator: ", ") ?? "—")
                row("Resolved proxy tag", snapshot?.resolvedProxyTag ?? "none")
                row("Routing rules", snapshot.map { "\($0.routingRuleCount)" } ?? "—")
                row("Has catch-all", snapshot?.hasCatchAll == true ? "yes" : "no")
                row("Has balancer", snapshot?.hasBalancer == true ? "yes" : "no")
                row("DNS servers", snapshot?.dnsServers.joined(separator: ", ") ?? "—")
                row("Uses geosite/geoip", snapshot?.usesGeoRules == true ? "yes" : "no")
            }

            Section("Actions") {
                Button("Refresh core status") {
                    tunnel.refreshCoreStatus(retries: 3)
                    note = "Requested tunnel diagnostics."
                }

                Button("Re-apply Happ routing to active Xray") {
                    reapplyRouting()
                }
                .disabled(activeXray == nil || !routing.routingEnabled || routing.activeProfile == nil)

                Button("Reconnect VPN") {
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
                Section("Result") {
                    Text(note)
                        .font(.footnote)
                }
            }
        }
        .navigationTitle("Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if tunnel.status == .connected {
                tunnel.refreshCoreStatus(retries: 3)
            }
        }
    }

    private var displayedCoreError: String {
        if let err = tunnel.tunnelDiagnostics.coreError, !err.isEmpty { return err }
        if let err = tunnel.lastError, !err.isEmpty { return err }
        return "—"
    }

    private func geoRow(_ needed: Bool, _ present: Bool) -> String {
        if !needed { return "not required" }
        return present ? "present" : "missing (auto-download on connect)"
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
        case .connected: return "connected"
        case .connecting: return "connecting"
        case .disconnecting: return "disconnecting"
        case .disconnected: return "disconnected"
        case .reasserting: return "reasserting"
        case .invalid: return "invalid"
        @unknown default: return "unknown"
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
            note = "No active Xray configuration."
            return
        }
        guard routing.routingEnabled, let profile = routing.activeProfile else {
            note = "Routing is disabled or no active routing profile."
            return
        }
        do {
            let updated = try HappRoutingApplier.apply(profile: profile, toXrayJSON: cfg.content)
            store.update(cfg, content: updated)
            note = "Routing re-applied to \(cfg.name)."
        } catch {
            note = "Routing apply failed: \(error.localizedDescription)"
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
        let hasBalancer = rules.contains(where: { $0["balancerTag"] != nil })

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
            usesGeoRules: json.contains("geosite:") || json.contains("geoip:")
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
