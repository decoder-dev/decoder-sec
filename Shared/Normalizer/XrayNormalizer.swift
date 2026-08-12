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
        try normalize(content, useZashboard: useZashboard, stripGeoRules: false)
    }

    /// - Parameter stripGeoRules: when true, remove geosite:/geoip: selectors so
    ///   Xray can start without .dat files in the extension container.
    static func normalize(_ content: String, useZashboard _: Bool, stripGeoRules: Bool) throws -> String {
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
        let outbounds = (root["outbounds"] as? [[String: Any]]) ?? []
        root["outbounds"] = sanitizeOutbounds(outbounds)
        root["routing"] = sanitizeRouting(
            root["routing"] as? [String: Any],
            outbounds: root["outbounds"] as? [[String: Any]] ?? [],
            stripGeoRules: stripGeoRules
        )
        return try serializeJSON(root)
    }

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
                // Xray "localhost" means built-in DNS; keep as-is for engine,
                // but "127.0.0.1" without a local DNS inbound fails on iOS NE.
                if trimmed == "localhost" || trimmed == "127.0.0.1" {
                    return nil
                }
                return s
            }
            if var obj = entry as? [String: Any] {
                if let address = obj["address"] as? String {
                    let trimmed = address.trimmingCharacters(in: .whitespaces).lowercased()
                    if trimmed == "localhost" || trimmed == "127.0.0.1" {
                        return nil
                    }
                }
                return obj
            }
            return entry
        }

        if servers.isEmpty {
            servers = ["1.1.1.1", "8.8.8.8"]
        }
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
        let balancers = (routing["balancers"] as? [[String: Any]]) ?? []
        let definedBalancerTags = Set(balancers.compactMap { $0["tag"] as? String })
        let fallbackOutbound = resolveProxyTag(from: outbounds) ?? "direct"

        // Observatory-backed balancers break after we strip observatory — flatten.
        if !balancers.isEmpty {
            routing.removeValue(forKey: "balancers")
        }

        rules = rules.compactMap { rule -> [String: Any]? in
            var copy = rule

            if let balancerTag = copy["balancerTag"] as? String, !balancerTag.isEmpty {
                copy.removeValue(forKey: "balancerTag")
                if definedBalancerTags.contains(balancerTag) || !balancerTag.isEmpty {
                    copy["outboundTag"] = fallbackOutbound
                }
            }

            if stripGeoRules {
                if var domains = copy["domain"] as? [Any] {
                    domains = domains.filter { entry in
                        guard let s = entry as? String else { return true }
                        return !s.lowercased().hasPrefix("geosite:")
                    }
                    if domains.isEmpty {
                        copy.removeValue(forKey: "domain")
                    } else {
                        copy["domain"] = domains
                    }
                }
                if var ips = copy["ip"] as? [Any] {
                    ips = ips.filter { entry in
                        guard let s = entry as? String else { return true }
                        return !s.lowercased().hasPrefix("geoip:")
                    }
                    if ips.isEmpty {
                        copy.removeValue(forKey: "ip")
                    } else {
                        copy["ip"] = ips
                    }
                }
            }

            let hasDomain = (copy["domain"] as? [Any])?.isEmpty == false
            let hasIP = (copy["ip"] as? [Any])?.isEmpty == false
            let hasPort = copy["port"] != nil
            let hasProtocol = copy["protocol"] != nil
            let hasInboundTag = copy["inboundTag"] != nil
            let hasNetwork = copy["network"] != nil
            let hasForward = copy["outboundTag"] != nil || copy["balancerTag"] != nil

            // Drop rules that lost all selectors after geo strip and aren't catch-all.
            if stripGeoRules, !hasDomain, !hasIP, !hasPort, !hasProtocol, !hasInboundTag,
               hasForward, hasNetwork == false {
                // keep as catch-all candidate
            } else if stripGeoRules, !hasDomain, !hasIP, !hasPort, !hasProtocol, !hasInboundTag,
                      !hasNetwork, hasForward {
                // keep
            } else if stripGeoRules, !hasDomain, !hasIP, !hasPort, !hasProtocol, !hasInboundTag, !hasNetwork, !hasForward {
                return nil
            }

            // After geo strip, a rule with only outbound and no selectors is fine (catch-all).
            // Drop empty shells with neither selectors nor forward.
            if !hasForward && !hasDomain && !hasIP && !hasPort && !hasProtocol && !hasInboundTag {
                return nil
            }

            return copy
        }

        let hasCatchAll = rules.contains { looksLikeCatchAll($0) }
        if !hasCatchAll {
            rules.append([
                "type": "field",
                "outboundTag": fallbackOutbound,
                "network": "tcp,udp",
            ])
        }

        routing["rules"] = rules
        if routing["domainStrategy"] == nil {
            routing["domainStrategy"] = "AsIs"
        }
        return routing
    }

    private static func looksLikeCatchAll(_ rule: [String: Any]) -> Bool {
        guard (rule["type"] as? String) == "field" else { return false }
        let hasDomain = (rule["domain"] as? [Any])?.isEmpty == false
        let hasIP = (rule["ip"] as? [Any])?.isEmpty == false
        let hasPort = rule["port"] != nil
        let hasProtocol = rule["protocol"] != nil
        let hasInboundTag = rule["inboundTag"] != nil
        let hasProcess = rule["process"] != nil
        let hasForward = rule["outboundTag"] != nil || rule["balancerTag"] != nil
        return hasForward && !hasDomain && !hasIP && !hasPort && !hasProtocol && !hasInboundTag && !hasProcess
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
