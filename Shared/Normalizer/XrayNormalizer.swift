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
import Darwin

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
        root["dns"] = sanitizeDNS(root["dns"], stripGeoRules: stripGeoRules)
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
    /// Fast path: Shared/C `ds_config_scan` (no JSON parse). Refine with JSON when needed.
    static func iosHazards(in content: String) -> [String] {
        var hazards: [String] = []
        let flags = content.withCString { ptr -> UInt32 in
            ds_config_scan(ptr, strlen(ptr))
        }
        if (flags & UInt32(DS_SCAN_BALANCER)) != 0 { hazards.append("balancers") }
        if (flags & UInt32(DS_SCAN_OBSERVATORY)) != 0 { hazards.append("observatory") }
        if (flags & UInt32(DS_SCAN_LOCALHOST)) != 0 { hazards.append("dns-localhost") }

        // JSON refine for balancerTag-only / unparseable edge cases.
        guard let root = try? parseJSONObject(content) else {
            if hazards.isEmpty { return ["unparseable"] }
            return hazards
        }
        let routing = root["routing"] as? [String: Any] ?? [:]
        if routing["balancers"] != nil, !hazards.contains("balancers") {
            hazards.append("balancers")
        }
        let rules = routing["rules"] as? [[String: Any]] ?? []
        if rules.contains(where: { ($0["balancerTag"] as? String)?.isEmpty == false }),
           !hazards.contains("balancerTag") {
            hazards.append("balancerTag")
        }
        if root["observatory"] != nil || root["burstObservatory"] != nil,
           !hazards.contains("observatory") {
            hazards.append("observatory")
        }
        if dnsHasLocalhost(root["dns"]), !hazards.contains("dns-localhost") {
            hazards.append("dns-localhost")
        }
        return hazards
    }

    private static func dnsHasLocalhost(_ dns: Any?) -> Bool {
        guard let dnsObj = dns as? [String: Any],
              let servers = dnsObj["servers"] as? [Any] else { return false }
        return servers.contains { entry in
            if let s = entry as? String {
                let t = s.trimmingCharacters(in: .whitespaces).lowercased()
                return isLocalhostResolver(t)
            }
            if let obj = entry as? [String: Any], let address = obj["address"] as? String {
                let t = address.trimmingCharacters(in: .whitespaces).lowercased()
                return isLocalhostResolver(t)
            }
            return false
        }
    }

    private static func sanitizeOutbounds(_ outbounds: [[String: Any]]) -> [[String: Any]] {
        var sanitized = outbounds.map { outbound in
            var copy = outbound
            copy.removeValue(forKey: "burstObservatory")
            copy.removeValue(forKey: "observatory")
            return copy
        }
        if sanitized.isEmpty || !sanitized.contains(where: { ($0["tag"] as? String) == "direct" }) {
            sanitized.append([
                "tag": "direct",
                "protocol": "freedom",
            ])
        }
        return sanitized
    }

    private static func sanitizeDNS(_ dns: Any?, stripGeoRules: Bool) -> Any? {
        guard var dnsObj = dns as? [String: Any] else { return dns }
        guard var servers = dnsObj["servers"] as? [Any] else { return dns }

        servers = servers.compactMap { entry -> Any? in
            if let s = entry as? String {
                let trimmed = s.trimmingCharacters(in: .whitespaces).lowercased()
                if isLocalhostResolver(trimmed) { return nil }
                return s
            }
            if var obj = entry as? [String: Any] {
                if let address = obj["address"] as? String {
                    let trimmed = address.trimmingCharacters(in: .whitespaces).lowercased()
                    if isLocalhostResolver(trimmed) { return nil }
                }
                if stripGeoRules {
                    obj = stripGeoTokens(from: obj, key: "domains", prefix: "geosite:")
                    obj = stripGeoTokens(from: obj, key: "domains", prefix: "geoip:")
                }
                return obj
            }
            return entry
        }

        // "localhost" in a Happ/desktop DNS list is usually the domain-agnostic
        // fallback resolver (matched last, after every domain-scoped entry).
        // Stripping it can leave e.g. a single `domains: ["geosite:cn"]` server
        // with nothing to answer any other query — Xray then has no DNS path
        // at all for the rest of the traffic. Only skip re-adding a default
        // when a server with no `domains` restriction already covers it.
        let hasCatchAllServer = servers.contains { entry in
            if entry is String { return true }
            if let obj = entry as? [String: Any] {
                let domains = obj["domains"] as? [Any]
                return domains == nil || domains?.isEmpty == true
            }
            return false
        }
        if !hasCatchAllServer {
            servers.append(contentsOf: ContainerPaths.defaultDNSServers as [Any])
        }

        dnsObj["servers"] = servers
        return dnsObj
    }

    private static func isLocalhostResolver(_ value: String) -> Bool {
        value == "localhost"
            || value == "127.0.0.1"
            || value == "::1"
            || value.hasPrefix("127.0.0.1:")
            || value.hasPrefix("[::1]:")
    }

    private static func sanitizeRouting(
        _ routing: [String: Any]?,
        outbounds: [[String: Any]],
        stripGeoRules: Bool
    ) -> [String: Any]? {
        var routing = routing ?? [:]
        var rules = (routing["rules"] as? [[String: Any]]) ?? []
        let balancers = (routing["balancers"] as? [[String: Any]]) ?? []
        let outboundTags = Set(outbounds.compactMap { $0["tag"] as? String })
        let fallbackOutbound = resolveProxyTag(from: outbounds) ?? "direct"
        // v2rayNG's getBalance() picks a balancer's live outbound at runtime
        // from its `selector` tag-prefix list (health-checked by observatory).
        // We have no reliable observatory on iOS, so resolve once here — but
        // still respect `selector` per balancer, otherwise a Happ config with
        // a dedicated "whitelist" balancer next to the main "proxy" balancer
        // would collapse both onto the same outbound and silently drop the
        // whitelist-lv2/lv3 routing intent.
        let balancerOutbounds = resolveBalancerOutbounds(balancers, outbounds: outbounds, fallback: fallbackOutbound)
        routing.removeValue(forKey: "balancers")

        rules = rules.compactMap { rule -> [String: Any]? in
            var copy = rule
            copy.removeValue(forKey: "inboundTag")

            if let balancerTag = copy["balancerTag"] as? String, !balancerTag.isEmpty {
                copy.removeValue(forKey: "balancerTag")
                copy["outboundTag"] = balancerOutbounds[balancerTag] ?? fallbackOutbound
            }
            if let outboundTag = copy["outboundTag"] as? String {
                if outboundTag.isEmpty || !outboundTags.contains(outboundTag) {
                    copy["outboundTag"] = fallbackOutbound
                }
            }
            if copy["outboundTag"] == nil {
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
        return hasForward && !ruleHasSelectorsExceptCatchAllNetwork(rule)
    }

    private static func ruleHasSelectorsExceptCatchAllNetwork(_ rule: [String: Any]) -> Bool {
        var copy = rule
        if let network = copy["network"] as? String {
            let normalized = network
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty }
                .sorted()
            if normalized == ["tcp", "udp"] {
                copy.removeValue(forKey: "network")
            }
        }
        return ruleHasSelectors(copy)
    }

    /// Maps each `balancers[].tag` to a single concrete outbound tag, honoring
    /// `selector` (a list of tag prefixes, e.g. `["whitelist-"]`) when present
    /// so multi-balancer configs keep routing distinct traffic to distinct
    /// outbound pools instead of everything falling back to `proxy`.
    private static func resolveBalancerOutbounds(
        _ balancers: [[String: Any]],
        outbounds: [[String: Any]],
        fallback: String
    ) -> [String: String] {
        let tags = outbounds.compactMap { $0["tag"] as? String }
        var map: [String: String] = [:]
        for balancer in balancers {
            guard let tag = balancer["tag"] as? String, !tag.isEmpty else { continue }
            let selectors = (balancer["selector"] as? [Any])?.compactMap { $0 as? String } ?? []
            guard !selectors.isEmpty else {
                map[tag] = fallback
                continue
            }
            if selectors.contains("proxy"), tags.contains("proxy") {
                map[tag] = "proxy"
                continue
            }
            let match = tags.first { candidate in
                selectors.contains { prefix in !prefix.isEmpty && candidate.hasPrefix(prefix) }
            }
            map[tag] = match ?? fallback
        }
        return map
    }

    private static func resolveProxyTag(from outbounds: [[String: Any]]) -> String? {
        if outbounds.contains(where: { ($0["tag"] as? String) == "proxy" }) { return "proxy" }
        if let proxyPrefix = outbounds.compactMap({ $0["tag"] as? String }).first(where: { $0.lowercased().hasPrefix("proxy-") }) {
            return proxyPrefix
        }
        if let nonWhitelist = firstUsableOutboundTag(from: outbounds, skipWhitelist: true) {
            return nonWhitelist
        }
        return firstUsableOutboundTag(from: outbounds, skipWhitelist: false)
    }

    private static func firstUsableOutboundTag(from outbounds: [[String: Any]], skipWhitelist: Bool) -> String? {
        for item in outbounds {
            guard let tag = item["tag"] as? String, !tag.isEmpty else { continue }
            let lower = tag.lowercased()
            if skipWhitelist && lower.hasPrefix("whitelist-") { continue }
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
