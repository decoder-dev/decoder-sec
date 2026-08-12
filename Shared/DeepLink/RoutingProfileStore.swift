//
//  RoutingProfileStore.swift
//  DecoderSec
//
//  Stores Happ routing profiles imported via happ://routing/...
//

import Combine
import Foundation

struct HappRoutingProfile: Codable, Equatable, Identifiable {
    var id: UUID
    var name: String
    var json: [String: AnyCodable]
    var sourceURL: String?
    var updatedAt: Date

    var rawObject: [String: Any] {
        json.mapValues(\.value)
    }
}

/// Type-erased Codable box for arbitrary Happ routing JSON.
struct AnyCodable: Codable, Equatable {
    let value: Any

    init(_ value: Any) { self.value = value }

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { value = NSNull(); return }
        if let b = try? c.decode(Bool.self) { value = b; return }
        if let i = try? c.decode(Int.self) { value = i; return }
        if let d = try? c.decode(Double.self) { value = d; return }
        if let s = try? c.decode(String.self) { value = s; return }
        if let a = try? c.decode([AnyCodable].self) { value = a.map(\.value); return }
        if let o = try? c.decode([String: AnyCodable].self) { value = o.mapValues(\.value); return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unsupported")
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch value {
        case is NSNull: try c.encodeNil()
        case let b as Bool: try c.encode(b)
        case let i as Int: try c.encode(i)
        case let d as Double: try c.encode(d)
        case let s as String: try c.encode(s)
        case let a as [Any]: try c.encode(a.map(AnyCodable.init))
        case let o as [String: Any]: try c.encode(o.mapValues(AnyCodable.init))
        default:
            throw EncodingError.invalidValue(value, .init(codingPath: c.codingPath, debugDescription: "Unsupported"))
        }
    }

    static func == (lhs: AnyCodable, rhs: AnyCodable) -> Bool {
        String(describing: lhs.value) == String(describing: rhs.value)
    }
}

final class RoutingProfileStore: ObservableObject {
    static let shared = RoutingProfileStore()

    @Published private(set) var profiles: [HappRoutingProfile] = []
    @Published var routingEnabled: Bool {
        didSet { defaults.set(routingEnabled, forKey: Keys.enabled) }
    }
    @Published var activeProfileID: UUID? {
        didSet { defaults.set(activeProfileID?.uuidString, forKey: Keys.active) }
    }

    var activeProfile: HappRoutingProfile? {
        guard let id = activeProfileID else { return nil }
        return profiles.first { $0.id == id }
    }

    private let defaults: UserDefaults
    private enum Keys {
        static let profiles = "happ.routing.profiles"
        static let enabled = "happ.routing.enabled"
        static let active = "happ.routing.active"
    }

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.routingEnabled = defaults.object(forKey: Keys.enabled) as? Bool ?? false
        if let raw = defaults.string(forKey: Keys.active) {
            self.activeProfileID = UUID(uuidString: raw)
        } else {
            self.activeProfileID = nil
        }
        reload()
    }

    func reload() {
        guard let data = defaults.data(forKey: Keys.profiles),
              let decoded = try? JSONDecoder().decode([HappRoutingProfile].self, from: data) else {
            profiles = []
            return
        }
        profiles = decoded
    }

    @discardableResult
    func upsert(fromJSONObject obj: [String: Any], activate: Bool, sourceURL: String? = nil) -> HappRoutingProfile {
        let name = (obj["Name"] as? String) ?? (obj["name"] as? String) ?? "Routing"
        let boxed = obj.mapValues(AnyCodable.init)
        if let idx = profiles.firstIndex(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            profiles[idx].json = boxed
            profiles[idx].updatedAt = Date()
            profiles[idx].sourceURL = sourceURL ?? profiles[idx].sourceURL
            persist()
            if activate {
                activeProfileID = profiles[idx].id
                routingEnabled = true
            } else if activeProfileID == nil {
                // First profile becomes active after geo download in Happ;
                // we activate when enabled later — keep id if none.
                activeProfileID = profiles[idx].id
            }
            return profiles[idx]
        }
        let profile = HappRoutingProfile(
            id: UUID(),
            name: name,
            json: boxed,
            sourceURL: sourceURL,
            updatedAt: Date()
        )
        profiles.append(profile)
        persist()
        if activate || profiles.count == 1 {
            activeProfileID = profile.id
            if activate { routingEnabled = true }
        }
        return profile
    }

    func upsert(fromJSONData data: Data, activate: Bool, sourceURL: String? = nil) throws -> HappRoutingProfile {
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "RoutingProfileStore", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Routing payload is not a JSON object."])
        }
        return upsert(fromJSONObject: obj, activate: activate, sourceURL: sourceURL)
    }

    func disable() {
        routingEnabled = false
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(profiles) {
            defaults.set(data, forKey: Keys.profiles)
        }
    }
}

enum HappRoutingApplier {
    /// Merge Happ routing profile fields into an Xray JSON config string.
    ///
    /// Stability rules:
    /// - Do not assume outbound tag "proxy" exists.
    /// - Keep existing routing rules and append them after Happ rules.
    /// - Avoid destructive DNS overwrite when config already has a DNS section.
    static func apply(profile: HappRoutingProfile, toXrayJSON json: String) throws -> String {
        guard var root = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else {
            throw NSError(domain: "HappRoutingApplier", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Config is not JSON."])
        }
        let p = profile.rawObject

        var outbounds = (root["outbounds"] as? [[String: Any]]) ?? []

        // Ensure block/direct outbounds exist; needed by Happ rules.
        if !outbounds.contains(where: { ($0["tag"] as? String) == "block" }) {
            outbounds.append(["tag": "block", "protocol": "blackhole"])
        }
        if !outbounds.contains(where: { ($0["tag"] as? String) == "direct" }) {
            outbounds.append(["tag": "direct", "protocol": "freedom"])
        }

        let blockTag = "block"
        let directTag = "direct"
        let proxyTag = resolveProxyTag(from: outbounds) ?? directTag

        let domainStrategy = (p["DomainStrategy"] as? String)
        let directSites = stringArray(p["DirectSites"])
        let proxySites = stringArray(p["ProxySites"])
        let blockSites = stringArray(p["BlockSites"])
        let directIp = stringArray(p["DirectIp"])
        let proxyIp = stringArray(p["ProxyIp"])
        let blockIp = stringArray(p["BlockIp"])

        var happRules: [[String: Any]] = []
        if !blockSites.isEmpty || !blockIp.isEmpty {
            var rule: [String: Any] = ["type": "field", "outboundTag": blockTag]
            if !blockSites.isEmpty { rule["domain"] = blockSites }
            if !blockIp.isEmpty { rule["ip"] = blockIp }
            happRules.append(rule)
        }
        if !directSites.isEmpty || !directIp.isEmpty {
            var rule: [String: Any] = ["type": "field", "outboundTag": directTag]
            if !directSites.isEmpty { rule["domain"] = directSites }
            if !directIp.isEmpty { rule["ip"] = directIp }
            happRules.append(rule)
        }
        if !proxySites.isEmpty || !proxyIp.isEmpty {
            var rule: [String: Any] = ["type": "field", "outboundTag": proxyTag]
            if !proxySites.isEmpty { rule["domain"] = proxySites }
            if !proxyIp.isEmpty { rule["ip"] = proxyIp }
            happRules.append(rule)
        }

        // Final catch-all depends on GlobalProxy. If we couldn't resolve a proxy
        // outbound, this gracefully falls back to direct.
        let globalProxy = boolish(p["GlobalProxy"], default: true)
        happRules.append([
            "type": "field",
            "outboundTag": globalProxy ? proxyTag : directTag,
            "network": "tcp,udp",
        ])

        // Merge with existing routing instead of replacing everything.
        // Keep non-Happ rules so provider-specific routing logic survives.
        var routing = (root["routing"] as? [String: Any]) ?? [:]
        let existingRules = (routing["rules"] as? [[String: Any]]) ?? []
        let keptExisting = existingRules.filter { !looksLikeManagedHappRule($0, proxyTag: proxyTag, directTag: directTag, blockTag: blockTag) }
        routing["rules"] = happRules + keptExisting
        if let domainStrategy, !domainStrategy.isEmpty {
            routing["domainStrategy"] = domainStrategy
        } else if routing["domainStrategy"] == nil {
            routing["domainStrategy"] = "IPIfNonMatch"
        }

        root["routing"] = routing
        root["outbounds"] = outbounds

        // DNS: only apply Happ hints when config has no explicit dns section.
        if root["dns"] == nil,
           let remote = p["RemoteDNSDomain"] as? String,
           !remote.isEmpty {
            let domestic = p["DomesticDNSDomain"] as? String
            root["dns"] = [
                "servers": [remote, domestic].compactMap { $0 },
                "queryStrategy": "UseIP",
            ]
        }

        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        guard let out = String(data: data, encoding: .utf8) else {
            throw NSError(domain: "HappRoutingApplier", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to serialize JSON."])
        }
        return out
    }

    private static func resolveProxyTag(from outbounds: [[String: Any]]) -> String? {
        // Preferred explicit tag
        if outbounds.contains(where: { ($0["tag"] as? String) == "proxy" }) {
            return "proxy"
        }

        // Otherwise pick first non-direct/non-block outbound tag.
        for item in outbounds {
            guard let tag = item["tag"] as? String, !tag.isEmpty else { continue }
            let lower = tag.lowercased()
            if lower == "direct" || lower == "block" || lower == "dns_out" || lower == "dns-out" {
                continue
            }
            let proto = (item["protocol"] as? String)?.lowercased() ?? ""
            if proto == "freedom" || proto == "blackhole" {
                continue
            }
            return tag
        }
        return nil
    }

    private static func looksLikeManagedHappRule(_ rule: [String: Any], proxyTag: String, directTag: String, blockTag: String) -> Bool {
        guard let type = rule["type"] as? String, type == "field" else { return false }
        guard let outbound = rule["outboundTag"] as? String else { return false }
        if outbound == proxyTag || outbound == directTag || outbound == blockTag {
            return true
        }
        return false
    }

    private static func stringArray(_ any: Any?) -> [String] {
        if let a = any as? [String] { return a }
        if let a = any as? [Any] { return a.compactMap { $0 as? String } }
        return []
    }

    private static func boolish(_ any: Any?, default def: Bool) -> Bool {
        if let b = any as? Bool { return b }
        if let s = any as? String {
            return ["1", "true", "yes", "on"].contains(s.lowercased())
        }
        return def
    }
}
