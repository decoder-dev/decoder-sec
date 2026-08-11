//
//  HappDeepLink.swift
//  Everywhere
//
//  Happ-compatible deep link grammar (provider bots / QR / Telegram).
//  Spec references:
//    https://www.happ.su/main/faq/adding-configuration-subscription
//    https://www.happ.su/main/dev-docs/routing
//    https://www.happ.su/main/dev-docs/crypto-link
//

import Foundation

enum HappDeepLinkAction: Equatable {
    /// `happ://add/{subscriptionURL}` — plain URL, not base64.
    case addSubscription(URL)
    /// Direct share-link (`vless://`, `vmess://`, …) or `happ://import/{payload}`.
    case importShareLink(String)
    /// `happ://routing/add|onadd/{base64|url}`
    case routingImport(RoutingPayload, activate: Bool)
    /// `happ://routing/off`
    case routingOff
    /// Tunnel controls (Happ bots / INCY-compatible extras under `happ://`).
    case connect
    case disconnect
    case toggle
    case status
    /// `happ://cryptN/...` — encrypted; private keys are not public.
    case unsupportedCrypto(version: String)
}

enum RoutingPayload: Equatable {
    case base64JSON(Data)
    case remoteURL(URL)
}

enum HappDeepLink {
    static let primaryScheme = "happ"
    static let aliasSchemes: Set<String> = ["happ", "everywhere", "decodersec", "decoder"]
    static let shareSchemes: Set<String> = [
        "vless", "vmess", "trojan", "ss", "ssr",
        "socks", "socks5", "hysteria2", "hy2", "wireguard", "wg"
    ]

    static func parse(_ url: URL) -> HappDeepLinkAction? {
        let scheme = (url.scheme ?? "").lowercased()

        if shareSchemes.contains(scheme) {
            return .importShareLink(url.absoluteString)
        }

        guard aliasSchemes.contains(scheme) else { return nil }

        let host = (url.host ?? "").lowercased()
        let path = url.path // begins with "/"
        let pathParts = path.split(separator: "/").map(String.init)

        // happ://crypt4/<payload>  (host = crypt4)
        if host.hasPrefix("crypt") {
            return .unsupportedCrypto(version: host)
        }

        switch host {
        case "add", "subscription", "sub":
            if let sub = subscriptionURL(from: url, pathParts: pathParts) {
                return .addSubscription(sub)
            }
            return nil

        case "import":
            if let raw = residualPayload(from: url, pathParts: pathParts), !raw.isEmpty {
                if let asURL = URL(string: raw), asURL.scheme != nil,
                   ["http", "https"].contains((asURL.scheme ?? "").lowercased()) {
                    return .addSubscription(asURL)
                }
                return .importShareLink(raw)
            }
            return nil

        case "routing":
            return parseRouting(pathParts: pathParts, url: url)

        case "autorouting":
            guard let first = pathParts.first?.lowercased(),
                  first == "onadd" || first == "add",
                  let payload = residualPayload(from: url, pathParts: Array(pathParts.dropFirst())),
                  let remote = URL(string: payload),
                  ["http", "https"].contains((remote.scheme ?? "").lowercased())
            else { return nil }
            return .routingImport(.remoteURL(remote), activate: first == "onadd")

        case "connect", "open":
            return .connect
        case "disconnect", "close":
            return .disconnect
        case "toggle":
            return .toggle
        case "status":
            return .status

        case "":
            // happ:///add/... unusual form
            return parsePathOnly(pathParts: pathParts, url: url)

        default:
            // happ://onadd/{url} shorthand (INCY-compatible)
            if host == "onadd", let payload = residualPayload(from: url, pathParts: pathParts),
               let remote = URL(string: payload),
               ["http", "https"].contains((remote.scheme ?? "").lowercased()) {
                return .routingImport(.remoteURL(remote), activate: true)
            }
            return nil
        }
    }

    // MARK: - Helpers

    private static func parsePathOnly(pathParts: [String], url: URL) -> HappDeepLinkAction? {
        guard let head = pathParts.first?.lowercased() else { return nil }
        let rest = Array(pathParts.dropFirst())
        switch head {
        case "add", "subscription", "sub":
            if let sub = subscriptionURL(from: url, pathParts: rest) { return .addSubscription(sub) }
        case "import":
            if let raw = residualPayload(from: url, pathParts: rest) {
                return .importShareLink(raw)
            }
        case "routing":
            return parseRouting(pathParts: rest, url: url)
        case "connect", "open": return .connect
        case "disconnect", "close": return .disconnect
        case "toggle": return .toggle
        default: break
        }
        return nil
    }

    private static func parseRouting(pathParts: [String], url: URL) -> HappDeepLinkAction? {
        guard let action = pathParts.first?.lowercased() else { return nil }
        let rest = Array(pathParts.dropFirst())

        // Query form: ?data={base64}
        if let dataParam = url.queryItems["data"], !dataParam.isEmpty,
           let decoded = decodeBase64(dataParam) {
            switch action {
            case "add": return .routingImport(.base64JSON(decoded), activate: false)
            case "onadd": return .routingImport(.base64JSON(decoded), activate: true)
            default: break
            }
        }

        switch action {
        case "off":
            return .routingOff
        case "add", "onadd":
            let activate = (action == "onadd")
            guard let payload = residualPayload(from: url, pathParts: rest) else { return nil }
            if let remote = URL(string: payload),
               ["http", "https"].contains((remote.scheme ?? "").lowercased()) {
                return .routingImport(.remoteURL(remote), activate: activate)
            }
            if let decoded = decodeBase64(payload) {
                return .routingImport(.base64JSON(decoded), activate: activate)
            }
            return nil
        default:
            return nil
        }
    }

    /// Reconstruct `https://…` (and query) that Happ puts after `add/`.
    private static func subscriptionURL(from url: URL, pathParts: [String]) -> URL? {
        guard var payload = residualPayload(from: url, pathParts: pathParts) else { return nil }
        if let decoded = payload.removingPercentEncoding, decoded != payload {
            payload = decoded
        }
        // Re-attach query that Foundation split off the nested URL.
        if let q = url.query, !q.isEmpty,
           !payload.contains("?"),
           payload.lowercased().hasPrefix("http") {
            payload += "?" + q
        }
        return URL(string: payload)
    }

    private static func residualPayload(from url: URL, pathParts: [String]) -> String? {
        guard !pathParts.isEmpty else {
            // happ://add?data=…
            if let data = url.queryItems["data"], !data.isEmpty { return data }
            return nil
        }
        // pathParts joined — restores nested URLs that contain "/"
        var joined = pathParts.joined(separator: "/")
        if let q = url.query, !q.isEmpty, !joined.contains("?") {
            // Only append when nested URL lost its query (http case handled in subscriptionURL)
            if joined.lowercased().hasPrefix("http") {
                joined += "?" + q
            }
        }
        return joined
    }

    static func decodeBase64(_ raw: String) -> Data? {
        var s = raw
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let pad = (4 - s.count % 4) % 4
        if pad > 0 { s += String(repeating: "=", count: pad) }
        return Data(base64Encoded: s)
    }
}

private extension URL {
    var queryItems: [String: String] {
        guard let comps = URLComponents(url: self, resolvingAgainstBaseURL: false) else { return [:] }
        var dict: [String: String] = [:]
        for item in comps.queryItems ?? [] {
            dict[item.name] = item.value ?? ""
        }
        return dict
    }
}
