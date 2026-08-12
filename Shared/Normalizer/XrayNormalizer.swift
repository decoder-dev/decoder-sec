//
//  XrayNormalizer.swift
//  DecoderSec
//
//  iOS-safe normalize for Happ / v2rayN subscription JSON.
//  Aligns with Xray docs (DNS, routing, sockopt.dialerProxy) and mobile clients
//  (v2rayNG / INCY): always ship a DNS block, strip geo tokens from all IP/DNS
//  fields, keep random/roundRobin balancers, flatten leastPing/leastLoad only,
//  and preserve dialerProxy chains in minimal boot.
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
        // C pre-pass blanks geosite:/geoip: JSON string literals to "" before
        // Foundation JSONSerialization — avoids large intermediate trees when
        // Happ configs carry dozens of whitelist geo categories.
        let prepared: String
        if stripGeoRules {
            prepared = blankGeoStringsInC(content) ?? content
        } else {
            prepared = content
        }
        var root = try parseJSONObject(prepared)

        // leastPing/leastLoad need observatory probes; those hang on iOS TUN.
        // random/roundRobin work without observatory (Xray treats all as alive).
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
            // Preserve provider sniffing excludes when present; ensure enabled.
            var sniffing = (patched["sniffing"] as? [String: Any]) ?? [:]
            sniffing["enabled"] = true
            if sniffing["destOverride"] == nil {
                sniffing["destOverride"] = ["http", "tls", "quic"]
            }
            if sniffing["routeOnly"] == nil {
                sniffing["routeOnly"] = false
            }
            patched["sniffing"] = sniffing
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

    /// Absolute boot guarantee for Packet Tunnel: proxy outbound (+ dialerProxy
    /// chain) + tun + public DNS + catch-all. No geo, observatory, or localhost DNS.
    static func minimalBootConfigs(from content: String, limit: Int = 3) throws -> [(tag: String, json: String)] {
        let root = try parseJSONObject(content)
        let outbounds = (root["outbounds"] as? [[String: Any]]) ?? []
        let candidates = usableProxyOutbounds(from: outbounds)
        guard !candidates.isEmpty else {
            throw NormalizeError.parseFailed("no usable proxy outbound for minimal boot")
        }

        var results: [(tag: String, json: String)] = []
        for outbound in candidates.prefix(max(1, limit)) {
            var proxy = scrubOutboundObservatory(outbound)
            let tag = {
                let t = (proxy["tag"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return t.isEmpty ? "proxy" : t
            }()
            proxy["tag"] = tag

            // Keep WARP-before-VLESS / dialerProxy chains (Xray sockopt docs).
            var chain = resolveDialerChain(for: proxy, in: outbounds)
            if chain.isEmpty { chain = [proxy] }
            chain[0] = proxy
            chain = chain.map(scrubOutboundObservatory)

            var outboundList: [[String: Any]] = chain
            if !outboundList.contains(where: { ($0["tag"] as? String) == "direct" }) {
                outboundList.append(["tag": "direct", "protocol": "freedom"])
            }
            if !outboundList.contains(where: { ($0["tag"] as? String) == "block" }) {
                outboundList.append(["tag": "block", "protocol": "blackhole"])
            }

            let config: [String: Any] = [
                "log": ["loglevel": "warning"],
                "dns": [
                    "servers": ContainerPaths.defaultDNSServers,
                    "queryStrategy": "UseIP",
                ],
                "inbounds": [[
                    "tag": decoderTunTag,
                    "protocol": "tun",
                    "settings": ["name": "utun", "MTU": tunnelMTU],
                    "sniffing": [
                        "enabled": true,
                        "destOverride": ["http", "tls", "quic"],
                        "routeOnly": false,
                    ],
                ]],
                "outbounds": outboundList,
                "routing": [
                    "domainStrategy": "AsIs",
                    "rules": [[
                        "type": "field",
                        "network": "tcp,udp",
                        "outboundTag": tag,
                    ]],
                ],
            ]
            results.append((tag: tag, json: try serializeJSON(config)))
        }
        return results
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
        if root["dns"] == nil, !hazards.contains("dns-missing") {
            hazards.append("dns-missing")
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
        var sanitized = outbounds.map(scrubOutboundObservatory)
        if sanitized.isEmpty || !sanitized.contains(where: { ($0["tag"] as? String) == "direct" }) {
            sanitized.append([
                "tag": "direct",
                "protocol": "freedom",
            ])
        }
        return sanitized
    }

    /// Xray DNS docs + INCY: missing `dns.servers` ⇒ OS resolver from inside
    /// Packet Tunnel — DNS leak (NE never loops its own traffic into TUN).
    private static func sanitizeDNS(_ dns: Any?, stripGeoRules: Bool) -> Any? {
        guard var dnsObj = dns as? [String: Any] else {
            return [
                "servers": ContainerPaths.defaultDNSServers,
                "queryStrategy": "UseIP",
            ]
        }
        guard var servers = dnsObj["servers"] as? [Any], !servers.isEmpty else {
            dnsObj["servers"] = ContainerPaths.defaultDNSServers
            if dnsObj["queryStrategy"] == nil {
                dnsObj["queryStrategy"] = "UseIP"
            }
            return dnsObj
        }

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
                    // DNS docs: domains + expectedIPs/unexpectedIPs use geo tokens.
                    obj = stripGeoTokens(from: obj, key: "domains", prefix: "geosite:")
                    obj = stripGeoTokens(from: obj, key: "domains", prefix: "geoip:")
                    obj = stripGeoTokens(from: obj, key: "expectedIPs", prefix: "geoip:")
                    obj = stripGeoTokens(from: obj, key: "unexpectedIPs", prefix: "geoip:")
                }
                return obj
            }
            return entry
        }

        // After stripping localhost, ensure a catch-all resolver remains.
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
        if dnsObj["queryStrategy"] == nil {
            dnsObj["queryStrategy"] = "UseIP"
        }
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

        // Xray routing docs: only leastPing/leastLoad require observatory.
        // random/roundRobin (default) work without probes — keep them.
        let keepBalancers = balancers.filter { !balancerRequiresObservatory($0) }
        let flattenBalancers = balancers.filter { balancerRequiresObservatory($0) }
        let balancerOutbounds = resolveBalancerOutbounds(
            flattenBalancers, outbounds: outbounds, fallback: fallbackOutbound
        )
        let keptBalancerTags = Set(keepBalancers.compactMap { $0["tag"] as? String })

        if keepBalancers.isEmpty {
            routing.removeValue(forKey: "balancers")
        } else {
            routing["balancers"] = keepBalancers
        }

        rules = rules.compactMap { rule -> [String: Any]? in
            var copy = rule
            copy.removeValue(forKey: "inboundTag")

            if let balancerTag = copy["balancerTag"] as? String, !balancerTag.isEmpty {
                if keptBalancerTags.contains(balancerTag) {
                    // Keep balancerTag for random/roundRobin balancers.
                    copy.removeValue(forKey: "outboundTag")
                } else {
                    copy.removeValue(forKey: "balancerTag")
                    copy["outboundTag"] = balancerOutbounds[balancerTag] ?? fallbackOutbound
                }
            }
            if let outboundTag = copy["outboundTag"] as? String, copy["balancerTag"] == nil {
                if outboundTag.isEmpty || !outboundTags.contains(outboundTag) {
                    copy["outboundTag"] = fallbackOutbound
                }
            }
            if copy["outboundTag"] == nil, copy["balancerTag"] == nil {
                copy["outboundTag"] = fallbackOutbound
            }

            if stripGeoRules {
                // Routing docs: domain/ip + sourceIP/localIP accept geoip:/geosite:.
                copy = stripGeoTokens(from: copy, key: "domain", prefix: "geosite:")
                copy = stripGeoTokens(from: copy, key: "ip", prefix: "geoip:")
                copy = stripGeoTokens(from: copy, key: "sourceIP", prefix: "geoip:")
                copy = stripGeoTokens(from: copy, key: "localIP", prefix: "geoip:")
            }

            guard ruleHasSelectors(copy) || copy["outboundTag"] != nil || copy["balancerTag"] != nil else {
                return nil
            }
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

    /// Xray: leastPing / leastLoad must be used with an observatory.
    private static func balancerRequiresObservatory(_ balancer: [String: Any]) -> Bool {
        guard let strategy = balancer["strategy"] as? [String: Any],
              let type = (strategy["type"] as? String)?.lowercased() else {
            return false // default strategy is random
        }
        return type == "leastping" || type == "leastload"
    }

    private static func ruleHasSelectors(_ rule: [String: Any]) -> Bool {
        let hasDomain = hasSelectorValue(rule["domain"])
        let hasIP = hasSelectorValue(rule["ip"])
        let hasSourceIP = hasSelectorValue(rule["sourceIP"])
        let hasLocalIP = hasSelectorValue(rule["localIP"])
        let hasPort = rule["port"] != nil
        let hasProtocol = rule["protocol"] != nil
        let hasNetwork = rule["network"] != nil
        let hasProcess = rule["process"] != nil
        let hasUser = rule["user"] != nil
        return hasDomain || hasIP || hasSourceIP || hasLocalIP
            || hasPort || hasProtocol || hasNetwork || hasProcess || hasUser
    }

    private static func hasSelectorValue(_ value: Any?) -> Bool {
        if let arr = value as? [Any], !arr.isEmpty { return true }
        if let s = value as? String, !s.isEmpty { return true }
        return false
    }

    private static func stripGeoTokens(from rule: [String: Any], key: String, prefix: String) -> [String: Any] {
        var copy = rule
        if let values = copy[key] as? [Any] {
            let filtered = values.compactMap { $0 as? String }
                .filter { !$0.isEmpty && !$0.lowercased().hasPrefix(prefix) }
            if filtered.isEmpty { copy.removeValue(forKey: key) } else { copy[key] = filtered }
        } else if let single = copy[key] as? String {
            if single.isEmpty || single.lowercased().hasPrefix(prefix) {
                copy.removeValue(forKey: key)
            }
        }
        return copy
    }

    private static func blankGeoStringsInC(_ content: String) -> String? {
        content.withCString { ptr -> String? in
            let len = strlen(ptr)
            var outLen: Int = 0
            guard let raw = ds_json_blank_geo_strings(ptr, len, &outLen) else { return nil }
            defer { free(raw) }
            return String(cString: raw)
        }
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

    private static func usableProxyOutbounds(from outbounds: [[String: Any]]) -> [[String: Any]] {
        var preferred: [[String: Any]] = []
        var normal: [[String: Any]] = []
        var whitelist: [[String: Any]] = []

        for item in outbounds {
            guard let tag = item["tag"] as? String, !tag.isEmpty else { continue }
            let lower = tag.lowercased()
            if lower == "direct" || lower == "block" || lower == "dns_out" || lower == "dns-out" { continue }
            let proto = (item["protocol"] as? String)?.lowercased() ?? ""
            if proto == "freedom" || proto == "blackhole" || proto == "dns" { continue }
            if proto.isEmpty { continue }

            if lower == "proxy" || lower.hasPrefix("proxy-") {
                preferred.append(item)
            } else if lower.hasPrefix("whitelist-") {
                whitelist.append(item)
            } else {
                normal.append(item)
            }
        }
        return preferred + normal + whitelist
    }

    private static func firstUsableOutboundTag(from outbounds: [[String: Any]], skipWhitelist: Bool) -> String? {
        for item in usableProxyOutbounds(from: outbounds) {
            guard let tag = item["tag"] as? String, !tag.isEmpty else { continue }
            if skipWhitelist && tag.lowercased().hasPrefix("whitelist-") { continue }
            return tag
        }
        return nil
    }

    /// `streamSettings.sockopt.dialerProxy` or legacy `proxySettings.tag`.
    private static func dialerProxyTag(of outbound: [String: Any]) -> String? {
        if let stream = outbound["streamSettings"] as? [String: Any],
           let sockopt = stream["sockopt"] as? [String: Any],
           let tag = sockopt["dialerProxy"] as? String,
           !tag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return tag
        }
        if let proxySettings = outbound["proxySettings"] as? [String: Any],
           let tag = proxySettings["tag"] as? String,
           !tag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return tag
        }
        return nil
    }

    /// Follow dialerProxy/proxySettings so minimal boot keeps WARP→VLESS chains.
    private static func resolveDialerChain(
        for candidate: [String: Any],
        in allOutbounds: [[String: Any]]
    ) -> [[String: Any]] {
        var chain = [candidate]
        var seen: Set<String> = []
        if let tag = candidate["tag"] as? String { seen.insert(tag) }
        var current = candidate
        while let nextTag = dialerProxyTag(of: current), !seen.contains(nextTag),
              let next = allOutbounds.first(where: { ($0["tag"] as? String) == nextTag }) {
            chain.append(next)
            seen.insert(nextTag)
            current = next
            if chain.count > 8 { break } // defensive cycle cap
        }
        return chain
    }

    private static func scrubOutboundObservatory(_ outbound: [String: Any]) -> [String: Any] {
        var copy = outbound
        copy.removeValue(forKey: "burstObservatory")
        copy.removeValue(forKey: "observatory")
        return copy
    }

    private static func cappedLog(_ existing: [String: Any]?) -> [String: Any] {
        var log = existing ?? [:]
        log["loglevel"] = cappedLevel(log["loglevel"] as? String, order: logOrder, floor: logFloor)
        if let access = log["access"] as? String, isLogFilePath(access) { log["access"] = "" }
        if let error = log["error"] as? String, isLogFilePath(error) { log["error"] = "" }
        return log
    }
}
