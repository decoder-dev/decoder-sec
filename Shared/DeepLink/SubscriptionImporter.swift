//
//  SubscriptionImporter.swift
//  Everywhere
//
//  Fetch Happ-style subscription bodies and turn them into Xray configs.
//

import Foundation

enum SubscriptionImporter {
    struct Result {
        var name: String
        var content: String
        var sourceURL: String?
        var embeddedRoutingDeepLink: String?
    }

    static func fetch(from url: URL, userAgent: String = "Happ/1.0 decodersec/1.0") async throws -> Result {
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw NSError(
                domain: "SubscriptionImporter",
                code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "Server returned HTTP \(http.statusCode)."]
            )
        }

        var routingHeader: String?
        if let http = response as? HTTPURLResponse {
            // Happ providers may send routing via header.
            routingHeader = http.value(forHTTPHeaderField: "routing")
                ?? http.value(forHTTPHeaderField: "Routing")
        }

        guard var text = String(data: data, encoding: .utf8) else {
            throw NSError(
                domain: "SubscriptionImporter",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Response is not valid UTF-8 text."]
            )
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // Whole body may be base64 of the real body.
        if !text.contains("://"), !text.hasPrefix("{"), !text.hasPrefix("["),
           let decoded = HappDeepLink.decodeBase64(text),
           let asString = String(data: decoded, encoding: .utf8) {
            text = asString.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let parsed = try parseBody(text, fallbackName: derivedName(from: url))
        var result = parsed
        result.sourceURL = url.absoluteString
        if result.embeddedRoutingDeepLink == nil {
            result.embeddedRoutingDeepLink = routingHeader
        }
        return result
    }

    static func parseBody(_ text: String, fallbackName: String) throws -> Result {
        // Full Xray / sing-box JSON object
        if text.hasPrefix("{"),
           let data = text.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let name = (obj["remarks"] as? String)
                ?? (obj["name"] as? String)
                ?? fallbackName
            let pretty = try prettyJSON(obj)
            return Result(name: name, content: pretty, sourceURL: nil, embeddedRoutingDeepLink: nil)
        }

        // JSON array of share-link strings or node objects — take share links / skip objects for now
        if text.hasPrefix("["),
           let data = text.data(using: .utf8),
           let arr = try? JSONSerialization.jsonObject(with: data) as? [Any] {
            var links: [String] = []
            for item in arr {
                if let s = item as? String { links.append(s) }
            }
            if !links.isEmpty {
                let built = try ShareLinkToXray.xrayConfig(fromShareLinks: links)
                return Result(name: built.name, content: built.json, sourceURL: nil, embeddedRoutingDeepLink: nil)
            }
        }

        // Line-oriented body: share links and optional happ://routing embedded lines
        var links: [String] = []
        var routing: String?
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if trimmed.lowercased().hasPrefix("happ://routing/") {
                routing = trimmed
                continue
            }
            if trimmed.contains("://") {
                links.append(trimmed)
            }
        }
        if !links.isEmpty {
            let built = try ShareLinkToXray.xrayConfig(fromShareLinks: links)
            return Result(name: built.name, content: built.json, sourceURL: nil, embeddedRoutingDeepLink: routing)
        }

        // YAML (mihomo) — keep as-is for mihomo core; caller decides core type.
        if text.contains("proxies:") || text.contains("proxy-groups:") {
            return Result(name: fallbackName, content: text, sourceURL: nil, embeddedRoutingDeepLink: routing)
        }

        throw NSError(
            domain: "SubscriptionImporter",
            code: -2,
            userInfo: [NSLocalizedDescriptionKey: "Unrecognized subscription body."]
        )
    }

    private static func prettyJSON(_ obj: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
        guard let s = String(data: data, encoding: .utf8) else {
            throw NSError(domain: "SubscriptionImporter", code: -3,
                          userInfo: [NSLocalizedDescriptionKey: "JSON encode failed."])
        }
        return s
    }

    private static func derivedName(from url: URL) -> String {
        let stripped = url.deletingPathExtension().lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !stripped.isEmpty, stripped != "/" { return stripped }
        return url.host ?? "Subscription"
    }
}
