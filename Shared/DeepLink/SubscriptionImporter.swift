//
//  SubscriptionImporter.swift
//  DecoderSec
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
        /// Extra full Xray JSON configs from a multi-profile subscription body.
        var additionalConfigs: [(name: String, content: String)] = []
    }

    static func fetch(from url: URL) async throws -> Result {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 20
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        DeviceIdentity.applySubscriptionHeaders(to: &request)

        let (data, response) = try await URLSession.shared.data(for: request)
        let http = response as? HTTPURLResponse

        if let http, !(200...299).contains(http.statusCode) {
            throw NSError(
                domain: "SubscriptionImporter",
                code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: String(localized: "Server returned HTTP \(http.statusCode).")]
            )
        }

        if let http, let hwidError = hwidPanelError(http: http, body: data) {
            throw hwidError
        }

        var routingHeader: String?
        if let http {
            routingHeader = http.value(forHTTPHeaderField: "routing")
                ?? http.value(forHTTPHeaderField: "Routing")
        }

        guard var text = String(data: data, encoding: .utf8) else {
            throw NSError(
                domain: "SubscriptionImporter",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: String(localized: "Response is not valid UTF-8 text.")]
            )
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)

        if text.isEmpty, let http, let announce = panelAnnounce(http: http) {
            throw NSError(
                domain: "SubscriptionImporter",
                code: -13,
                userInfo: [NSLocalizedDescriptionKey: announce]
            )
        }

        // Whole body may be base64 of the real body.
        if !text.contains("://"), !text.hasPrefix("{"), !text.hasPrefix("["),
           let decoded = HappDeepLink.decodeBase64(text),
           let asString = String(data: decoded, encoding: .utf8) {
            text = asString.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if looksLikeUnsupportedDummy(text) {
            throw NSError(
                domain: "SubscriptionImporter",
                code: -12,
                userInfo: [NSLocalizedDescriptionKey: String(localized: "Provider returned “App not supported”. Send X-HWID (device id) is required — update the app, or ask the panel admin to allow this client.")]
            )
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

        // JSON array: share-link strings and/or full Xray config objects (Happ / Remnawave).
        if text.hasPrefix("["),
           let data = text.data(using: .utf8),
           let arr = try? JSONSerialization.jsonObject(with: data) as? [Any] {
            var links: [String] = []
            var configs: [(name: String, content: String)] = []
            for item in arr {
                if let s = item as? String {
                    links.append(s)
                    continue
                }
                if let obj = item as? [String: Any],
                   obj["outbounds"] != nil || obj["inbounds"] != nil {
                    let name = (obj["remarks"] as? String)
                        ?? (obj["name"] as? String)
                        ?? fallbackName
                    let pretty = try prettyJSON(obj)
                    configs.append((name, pretty))
                }
            }
            if !configs.isEmpty {
                let first = configs[0]
                let rest = Array(configs.dropFirst())
                return Result(
                    name: first.name,
                    content: first.content,
                    sourceURL: nil,
                    embeddedRoutingDeepLink: nil,
                    additionalConfigs: rest
                )
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
            userInfo: [NSLocalizedDescriptionKey: String(localized: "Unrecognized subscription body.")]
        )
    }

    private static func hwidPanelError(http: HTTPURLResponse, body: Data) -> NSError? {
        if headerTruthy(http, "x-hwid-not-supported") || headerTruthy(http, "X-Hwid-Not-Supported") {
            return NSError(
                domain: "SubscriptionImporter",
                code: -11,
                userInfo: [NSLocalizedDescriptionKey: String(localized: "This subscription requires a device ID (HWID). The panel rejected the request — ask your provider to allow this app, or import the config in Happ once so the device is registered.")]
            )
        }
        if headerTruthy(http, "x-hwid-max-devices-reached")
            || headerTruthy(http, "X-Hwid-Max-Devices-Reached")
            || headerTruthy(http, "x-hwid-limit")
            || headerTruthy(http, "X-Hwid-Limit") {
            let announce = panelAnnounce(http: http)
            return NSError(
                domain: "SubscriptionImporter",
                code: -14,
                userInfo: [NSLocalizedDescriptionKey: announce ?? String(localized: "Device limit reached on the subscription panel. Remove an old device in your provider dashboard.")]
            )
        }
        return nil
    }

    private static func headerTruthy(_ http: HTTPURLResponse, _ name: String) -> Bool {
        guard let raw = http.value(forHTTPHeaderField: name) else { return false }
        let v = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return v == "true" || v == "1" || v == "yes" || v == "on"
    }

    private static func panelAnnounce(http: HTTPURLResponse) -> String? {
        if let a = http.value(forHTTPHeaderField: "announce"), !a.isEmpty { return a }
        if let a = http.value(forHTTPHeaderField: "Announce"), !a.isEmpty { return a }
        return nil
    }

    private static func looksLikeUnsupportedDummy(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.contains("app%20not%20supported")
            || lower.contains("app not supported")
            || lower.contains("#app not supported")
            || (lower.contains("not supported") && lower.contains("vless://") && !lower.contains("\n"))
    }

    private static func prettyJSON(_ obj: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
        guard let s = String(data: data, encoding: .utf8) else {
            throw NSError(domain: "SubscriptionImporter", code: -3,
                          userInfo: [NSLocalizedDescriptionKey: String(localized: "JSON encode failed.")])
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
