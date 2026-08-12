//
//  XrayNormalizer.swift
//  DecoderSec
//
//  Created by NodePassProject on 5/24/26.
//

import Foundation

enum XrayNormalizer: JSONCoreNormalizer {
    private static let logFloor = "warning"
    private static let logOrder = ["debug", "info", "warning", "error", "none"]

    static func normalize(_ content: String, useZashboard _: Bool) throws -> String {
        var root = try parseJSONObject(content)
        root.removeValue(forKey: "burstObservatory")
        root.removeValue(forKey: "observatory")

        var inbounds = (root["inbounds"] as? [[String: Any]]) ?? []
        inbounds = inbounds.filter { shouldKeepInbound($0) }

        if let first = inbounds.firstIndex(where: { isTunInbound($0, typeKey: "protocol") }) {
            var patched = inbounds[first]
            patched["protocol"] = "tun"
            patched["tag"] = decoderTunTag
            var settings = (patched["settings"] as? [String: Any]) ?? [:]
            settings["name"] = "utun"
            settings["MTU"] = tunnelMTU
            patched["settings"] = settings
            inbounds[first] = patched
            removeOtherTunInbounds(&inbounds, keep: first, typeKey: "protocol")
        } else {
            inbounds.append([
                "tag": decoderTunTag,
                "protocol": "tun",
                "settings": [
                    "name": "utun",
                    "MTU": tunnelMTU,
                ],
            ])
        }
        root["inbounds"] = inbounds
        root["log"] = cappedLog(root["log"] as? [String: Any])
        root["dns"] = sanitizeDNS(root["dns"])
        root["routing"] = sanitizeRouting(root["routing"] as? [String: Any], outbounds: root["outbounds"] as? [[String: Any]] ?? [])
        root["outbounds"] = sanitizeOutbounds(root["outbounds"] as? [[String: Any]] ?? [])
        return try serializeJSON(root)
    }

    /// Local proxy inbounds (socks/http/dokodemo) are for desktop Happ clients and
    /// conflict with iOS packet-tunnel mode — keep only TUN/sniffing inbounds if any.
    private static func shouldKeepInbound(_ inbound: [String: Any]) -> Bool {
        let proto = (inbound["protocol"] as? String)?.lowercased() ?? ""
        switch proto {
        case "tun", "socks", "http", "dokodemo-door", "mixed":
            return proto == "tun"
        default:
            return true
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
                if trimmed == "localhost" { return "127.0.0.1" }
                return s
            }
            if var obj = entry as? [String: Any] {
                if let address = obj["address"] as? String {
                    let trimmed = address.trimmingCharacters(in: .whitespaces).lowercased()
                    if trimmed == "localhost" {
                        obj["address"] = "127.0.0.1"
                    }
                }
                return obj
            }
            return entry
        }

        if servers.isEmpty {
            return nil
        }
        dnsObj["servers"] = servers
        return dnsObj
    }

    /// Drop rules that reference undefined balancers; map to proxy outbound when possible.
    private static func sanitizeRouting(_ routing: [String: Any]?, outbounds: [[String: Any]]) -> [String: Any]? {
        guard var routing else { return nil }
        let rules = (routing["rules"] as? [[String: Any]]) ?? []
        guard !rules.isEmpty else { return routing }

        let balancers = (routing["balancers"] as? [[String: Any]]) ?? []
        let definedTags = Set(balancers.compactMap { $0["tag"] as? String })
        let fallbackOutbound = resolveProxyTag(from: outbounds) ?? "direct"

        let sanitized = rules.compactMap { rule -> [String: Any]? in
            guard let balancerTag = rule["balancerTag"] as? String, !balancerTag.isEmpty else {
                return rule
            }
            if definedTags.contains(balancerTag) {
                return rule
            }
            var copy = rule
            copy.removeValue(forKey: "balancerTag")
            copy["outboundTag"] = fallbackOutbound
            return copy
        }

        routing["rules"] = sanitized
        return routing
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

    private static func cappedLog(_ existing: [String: Any]?) -> [String: Any] {
        var log = existing ?? [:]
        log["loglevel"] = cappedLevel(log["loglevel"] as? String, order: logOrder, floor: logFloor)
        if let access = log["access"] as? String, isLogFilePath(access) { log["access"] = "" }
        if let error = log["error"] as? String, isLogFilePath(error) { log["error"] = "" }
        return log
    }
}
