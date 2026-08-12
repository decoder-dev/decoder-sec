//
//  XrayNormalizer.swift
//  DecoderSec
//
//  iOS-safe normalize for Happ / v2rayN subscription JSON.
//  Android (v2rayNG): balancers always ship with observatory/burstObservatory,
//  or use random/roundRobin without probes. Happ desktop configs often have
//  balancers + observatory + DNS localhost — the last two break EvcoreStartCore
//  on iOS Packet Tunnel (no local DNS inbound; observatory probes hang TUN).
//

import Foundation

enum XrayNormalizer: JSONCoreNormalizer {
    private static let logFloor = "warning"
    private static let logOrder = ["debug", "info", "warning", "error", "none"]

    /// Single iOS-safe config for Packet Tunnel (Android custom JSON + TUN injection).
    static func normalize(_ content: String, useZashboard: Bool) throws -> String {
        try normalize(content, useZashboard: useZashboard, stripGeoRules: false)
    }

    static func normalize(_ content: String, useZashboard _: Bool, stripGeoRules: Bool) throws -> String {
        var root = try parseJSONObject(content)

        // Balancers without live observatory hang or fail on iOS TUN.
        // v2rayNG keeps observatory WITH balancers; we flatten to a fixed outbound.
        root.removeValue(forKey: "burstObservatory")
        root.removeValue(forKey: "observatory")

        var inbounds = (root["inbounds"] as? [[String: Any]]) ?? []
        inbounds = inbounds.filter { isTunInbound($0, typeKey: "protocol") }

        if let first = inbounds.firstIndex(where: { isTunInbound($0, typeKey: "protocol") }) {
            var patched = inbounds[first]
            patched["protocol"] = "tun"
            patched["tag"] = decoderTunTag
            var settings = (patched["settings"] as? [String: Any]) ?? [:]
            settings["name"] = "utun"
            settings["MTU"] = tunnelMTU
            patched["settings"] = settings
            patched["sniffing"] = [
                "enabled": true,
                "destOverride": ["http", "tls", "quic"],
                "routeOnly": false,
            ]
            inbounds[first] = patched
            removeOtherTunInbounds(&inbounds, keep: first, typeKey: "protocol")
        } else {
            inbounds.append([
                "tag": decoderTunTag,
                "protocol": "tun",
                "settings": ["name": "utun", "MTU": tunnelMTU],
                "sniffing": [
                    "enabled": true,
                    "destOverride": ["http", "tls", "quic"],
                    "routeOnly": false,
                ],
            ])
        }
        root["inbounds"] = inbounds
        root["log"] = cappedLog(root["log"] as? [String: Any])
        root["dns"] = sanitizeDNS(root["dns"])
        let outbounds = sanitizeOutbounds(root["outbounds"] as? [[String: Any]] ?? [])
        root["outbounds"] = outbounds
        root["routing"] = sanitizeRouting(
            root["routing"] as? [String: Any],
            outbounds: outbounds,
            stripGeoRules: stripGeoRules
        )
        return try serializeJSON(root)
    }

    /// Features that break or hang Xray on iOS Packet Tunnel if left as-is.
    static func iosHazards(in content: String) -> [String] {
        guard let root = try? parseJSONObject(content) else { return ["unparseable"] }
        var hazards: [String] = []
        let routing = root["routing"] as? [String: Any] ?? [:]
        if routing["balancers"] != nil { hazards.append("balancers") }
        let rules = routing["rules"] as? [[String: Any]] ?? []
        if rules.contains(where: { ($0["balancerTag"] as? String)?.isEmpty == false }) {
            hazards.append("balancerTag")
        }
        if root["observatory"] != nil { hazards.append("observatory") }
        if root["burstObservatory"] != nil { hazards.append("burstObservatory") }
        if dnsHasLocalhost(root["dns"]) { hazards.append("dns-localhost") }
        return hazards
    }

    private static func dnsHasLocalhost(_ dns: Any?) -> Bool {
        guard let dnsObj = dns as? [String: Any],
              let servers = dnsObj["servers"] as? [Any] else { return false }
        return servers.contains { entry in
            if let s = entry as? String {
                let t = s.trimmingCharacters(in: .whitespaces).lowercased()
                return t == "localhost" || t == "127.0.0.1"
            }
            if let obj = entry as? [String: Any], let address = obj["address"] as? String {
                let t = address.trimmingCharacters(in: .whitespaces).lowercased()
                return t == "localhost" || t == "127.0.0.1"
            }
            return false
        }
    }

    private static func sanitizeOutbounds(_ outbounds: [[String: Any]]) -> [[String: Any]] {
        outbounds.map { outbound in
            var copy = outbound
            copy.removeValue(forKey: "burstObservatory")
            copy.removeValue(forKey: "observatory")
            return copy
        }
    }

    private static func sanitizeDNS(_ dns: Any?) -> Any? {
        guard var dnsObj = dns as? [String: Any] else { return dns }
        guard var servers = dnsObj["servers"] as? [Any] else { return dns }

        servers = servers.compactMap { entry -> Any? in
            if let s = entry as? String {
                let trimmed = s.trimmingCharacters(in: .whitespaces).lowercased()
                if trimmed == "localhost" || trimmed == "127.0.0.1" { return nil }
                return s
            }
            if let obj = entry as? [String: Any] {
                if let address = obj["address"] as? String {
                    let trimmed = address.trimmingCharacters(in: .whitespaces).lowercased()
                    if trimmed == "localhost" || trimmed == "127.0.0.1" { return nil }
                }
                return obj
            }
            return entry
        }

        if servers.isEmpty { servers = ["1.1.1.1", "8.8.8.8"] }
        dnsObj["servers"] = servers
        return dnsObj
    }

    private static func sanitizeRouting(
        _ routing: [String: Any]?,
        outbounds: [[String: Any]],
        stripGeoRules: Bool
    ) -> [String: Any]? {
        var routing = routing ?? [:]
        var rules = (routing["rules"] as? [[String: Any]]) ?? []
        routing.removeValue(forKey: "balancers")
        let fallbackOutbound = resolveProxyTag(from: outbounds) ?? "direct"

        rules = rules.compactMap { rule -> [String: Any]? in
            var copy = rule
            copy.removeValue(forKey: "inboundTag")

            if let balancerTag = copy["balancerTag"] as? String, !balancerTag.isEmpty {
                copy.removeValue(forKey: "balancerTag")
                copy["outboundTag"] = fallbackOutbound
            }

            if stripGeoRules {
                copy = stripGeoTokens(from: copy, key: "domain", prefix: "geosite:")
                copy = stripGeoTokens(from: copy, key: "ip", prefix: "geoip:")
            }

            // Drop empty shells after geo strip / balancer flatten.
            guard ruleHasSelectors(copy) || copy["outboundTag"] != nil else { return nil }
            return copy
        }

        if !rules.contains(where: looksLikeCatchAll) {
            rules.append([
                "type": "field",
                "outboundTag": fallbackOutbound,
                "network": "tcp,udp",
            ])
        }

        routing["rules"] = rules
        if routing["domainStrategy"] == nil {
            routing["domainStrategy"] = "IPIfNonMatch"
        }
        return routing
    }

    private static func ruleHasSelectors(_ rule: [String: Any]) -> Bool {
        let hasDomain = hasSelectorValue(rule["domain"])
        let hasIP = hasSelectorValue(rule["ip"])
        let hasPort = rule["port"] != nil
        let hasProtocol = rule["protocol"] != nil
        let hasNetwork = rule["network"] != nil
        let hasProcess = rule["process"] != nil
        let hasUser = rule["user"] != nil
        return hasDomain || hasIP || hasPort || hasProtocol || hasNetwork || hasProcess || hasUser
    }

    private static func hasSelectorValue(_ value: Any?) -> Bool {
        if let arr = value as? [Any], !arr.isEmpty { return true }
        if let s = value as? String, !s.isEmpty { return true }
        return false
    }

    private static func stripGeoTokens(from rule: [String: Any], key: String, prefix: String) -> [String: Any] {
        var copy = rule
        if let values = copy[key] as? [Any] {
            let filtered = values.compactMap { $0 as? String }.filter { !$0.lowercased().hasPrefix(prefix) }
            if filtered.isEmpty { copy.removeValue(forKey: key) } else { copy[key] = filtered }
        } else if let single = copy[key] as? String {
            if single.lowercased().hasPrefix(prefix) {
                copy.removeValue(forKey: key)
            }
        }
        return copy
    }

    private static func looksLikeCatchAll(_ rule: [String: Any]) -> Bool {
        let hasForward = rule["outboundTag"] != nil || rule["balancerTag"] != nil
        return hasForward && !ruleHasSelectors(rule)
    }

    private static func resolveProxyTag(from outbounds: [[String: Any]]) -> String? {
        if outbounds.contains(where: { ($0["tag"] as? String) == "proxy" }) { return "proxy" }
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

    private static func cappedLog(_ existing: [String: Any]?) -> [String: Any] {
        var log = existing ?? [:]
        log["loglevel"] = cappedLevel(log["loglevel"] as? String, order: logOrder, floor: logFloor)
        if let access = log["access"] as? String, isLogFilePath(access) { log["access"] = "" }
        if let error = log["error"] as? String, isLogFilePath(error) { log["error"] = "" }
        return log
    }
}
