//
//  XrayNodeCatalog.swift
//  Shared/Domain
//

import Foundation

struct XrayNode: Identifiable, Equatable {
    var tag: String
    var displayName: String
    var proto: String?

    var id: String { tag }
}

enum XrayNodeCatalog {
    static func nodes(from json: String) -> [XrayNode] {
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let outbounds = root["outbounds"] as? [[String: Any]] else {
            return []
        }
        return outbounds.compactMap { item in
            guard let tag = item["tag"] as? String, !tag.isEmpty else { return nil }
            let lower = tag.lowercased()
            if lower == "direct" || lower == "block" || lower == "dns_out" || lower == "dns-out" { return nil }
            let proto = (item["protocol"] as? String)?.lowercased() ?? ""
            if proto == "freedom" || proto == "blackhole" { return nil }
            let remark = (item["remark"] as? String)
                ?? (item["settings"] as? [String: Any])?["address"] as? String
            let name = remark.map { "\($0) (\(tag))" } ?? tag
            return XrayNode(tag: tag, displayName: name, proto: proto.isEmpty ? nil : proto)
        }
    }
}

enum XrayNodeSelection {
    private static func key(for configID: UUID) -> String { "decoder.node.\(configID.uuidString)" }

    static func selectedTag(for configID: UUID) -> String? {
        UserDefaults.standard.string(forKey: key(for: configID))
    }

    static func setSelectedTag(_ tag: String, for configID: UUID) {
        UserDefaults.standard.set(tag, forKey: key(for: configID))
    }

    /// Rewrites routing catch-all / proxy rules to use the chosen outbound tag.
    static func applySelection(to json: String, configID: UUID) -> String {
        let nodes = XrayNodeCatalog.nodes(from: json)
        guard nodes.count > 1 else { return json }
        let tag = selectedTag(for: configID) ?? nodes.first?.tag ?? "proxy"
        guard var root = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else {
            return json
        }
        var routing = (root["routing"] as? [String: Any]) ?? [:]
        var rules = (routing["rules"] as? [[String: Any]]) ?? []
        for idx in rules.indices {
            var rule = rules[idx]
            if let outbound = rule["outboundTag"] as? String,
               outbound == "proxy" || nodes.contains(where: { $0.tag == outbound }) {
                rule["outboundTag"] = tag
                rules[idx] = rule
            }
        }
        routing["rules"] = rules
        root["routing"] = routing
        guard let data = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]),
              let out = String(data: data, encoding: .utf8) else {
            return json
        }
        return out
    }
}
