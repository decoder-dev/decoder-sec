//
//  ShareLinkToXray.swift
//  Everywhere
//
//  Convert Happ/INCY-style share links into a minimal Xray JSON config.
//

import Foundation

enum ShareLinkToXray {
    struct ParsedNode: Equatable {
        var name: String
        var outbound: [String: Any]

        static func == (lhs: ParsedNode, rhs: ParsedNode) -> Bool {
            lhs.name == rhs.name
        }
    }

    static func xrayConfig(fromShareLinks links: [String]) throws -> (name: String, json: String) {
        var outbounds: [[String: Any]] = []
        var names: [String] = []
        for link in links {
            let trimmed = link.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            let node = try parseNode(trimmed)
            var outbound = node.outbound
            if outbounds.isEmpty {
                outbound["tag"] = "proxy"
            } else {
                outbound["tag"] = "proxy-\(outbounds.count)"
            }
            outbounds.append(outbound)
            names.append(node.name)
        }
        guard !outbounds.isEmpty else {
            throw ShareLinkError.empty
        }
        outbounds.append(["tag": "direct", "protocol": "freedom"])
        outbounds.append(["tag": "block", "protocol": "blackhole"])

        let root: [String: Any] = [
            "log": ["loglevel": "warning"],
            "inbounds": [],
            "outbounds": outbounds,
            "routing": [
                "domainStrategy": "IPIfNonMatch",
                "rules": [
                    [
                        "type": "field",
                        "outboundTag": "proxy",
                        "network": "tcp,udp",
                    ]
                ],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        guard let json = String(data: data, encoding: .utf8) else { throw ShareLinkError.encode }
        let name = names.first.map { names.count > 1 ? "\($0) +\(names.count - 1)" : $0 } ?? "Imported"
        return (name, json)
    }

    static func parseNode(_ link: String) throws -> ParsedNode {
        guard let url = URL(string: link), let scheme = url.scheme?.lowercased() else {
            throw ShareLinkError.invalidURI
        }
        switch scheme {
        case "vless":
            return try parseVLESS(url, raw: link)
        case "vmess":
            return try parseVMESS(link)
        case "trojan":
            return try parseTrojan(url)
        case "ss":
            return try parseShadowsocks(url, raw: link)
        case "socks", "socks5":
            return try parseSocks(url)
        case "hysteria2", "hy2":
            return try parseHysteria2(url)
        default:
            throw ShareLinkError.unsupportedScheme(scheme)
        }
    }

    // MARK: - Protocols

    private static func parseVLESS(_ url: URL, raw: String) throws -> ParsedNode {
        let uuid = url.user ?? ""
        guard !uuid.isEmpty, let host = url.host, let port = url.port ?? optionalPort(url) else {
            throw ShareLinkError.invalidURI
        }
        let q = queryDict(url)
        let name = fragmentName(url) ?? host
        let security = (q["security"] ?? q["encryption"] ?? "none").lowercased()
        var stream: [String: Any] = [
            "network": (q["type"] ?? q["network"] ?? "tcp").lowercased(),
        ]
        var reality: [String: Any] = [:]
        var tls: [String: Any] = [:]

        if security == "reality" {
            stream["security"] = "reality"
            reality["serverName"] = q["sni"] ?? q["serverName"] ?? ""
            reality["fingerprint"] = q["fp"] ?? "chrome"
            reality["publicKey"] = q["pbk"] ?? ""
            reality["shortId"] = q["sid"] ?? ""
            reality["spiderX"] = q["spx"] ?? ""
            stream["realitySettings"] = reality
        } else if security == "tls" {
            stream["security"] = "tls"
            tls["serverName"] = q["sni"] ?? host
            tls["fingerprint"] = q["fp"] ?? "chrome"
            if let alpn = q["alpn"] { tls["alpn"] = alpn.split(separator: ",").map(String.init) }
            stream["tlsSettings"] = tls
        } else {
            stream["security"] = "none"
        }

        let network = (stream["network"] as? String) ?? "tcp"
        switch network {
        case "ws":
            stream["wsSettings"] = [
                "path": q["path"] ?? "/",
                "headers": ["Host": q["host"] ?? host],
            ]
        case "grpc":
            stream["grpcSettings"] = [
                "serviceName": q["serviceName"] ?? q["path"] ?? "",
            ]
        case "httpupgrade", "http":
            stream["httpupgradeSettings"] = [
                "path": q["path"] ?? "/",
                "host": q["host"] ?? host,
            ]
        case "xhttp", "splithttp":
            stream["xhttpSettings"] = [
                "path": q["path"] ?? "/",
                "host": q["host"] ?? host,
                "mode": q["mode"] ?? "auto",
            ]
        default:
            break
        }

        var outbound: [String: Any] = [
            "protocol": "vless",
            "settings": [
                "vnext": [[
                    "address": host,
                    "port": port,
                    "users": [[
                        "id": uuid,
                        "encryption": q["encryption"] ?? "none",
                        "flow": q["flow"] ?? "",
                    ]],
                ]]
            ],
            "streamSettings": stream,
        ]
        _ = raw
        return ParsedNode(name: name, outbound: outbound)
    }

    private static func parseVMESS(_ raw: String) throws -> ParsedNode {
        guard let schemeRange = raw.range(of: "://") else { throw ShareLinkError.invalidURI }
        var payload = String(raw[schemeRange.upperBound...])
        if let hash = payload.firstIndex(of: "#") {
            payload = String(payload[..<hash])
        }
        guard let data = HappDeepLink.decodeBase64(payload),
              let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ShareLinkError.invalidURI
        }
        let host = (obj["add"] as? String) ?? ""
        let port = intValue(obj["port"]) ?? 443
        let uuid = (obj["id"] as? String) ?? ""
        let name = (obj["ps"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? host
        let network = ((obj["net"] as? String) ?? "tcp").lowercased()
        let tls = ((obj["tls"] as? String) ?? "").lowercased()

        var stream: [String: Any] = ["network": network]
        if tls == "tls" {
            stream["security"] = "tls"
            stream["tlsSettings"] = [
                "serverName": (obj["sni"] as? String) ?? (obj["host"] as? String) ?? host,
            ]
        } else {
            stream["security"] = "none"
        }
        if network == "ws" {
            stream["wsSettings"] = [
                "path": (obj["path"] as? String) ?? "/",
                "headers": ["Host": (obj["host"] as? String) ?? host],
            ]
        }

        let outbound: [String: Any] = [
            "protocol": "vmess",
            "settings": [
                "vnext": [[
                    "address": host,
                    "port": port,
                    "users": [[
                        "id": uuid,
                        "alterId": intValue(obj["aid"]) ?? 0,
                        "security": (obj["scy"] as? String) ?? "auto",
                    ]],
                ]]
            ],
            "streamSettings": stream,
        ]
        return ParsedNode(name: name, outbound: outbound)
    }

    private static func parseTrojan(_ url: URL) throws -> ParsedNode {
        let password = url.user ?? ""
        guard !password.isEmpty, let host = url.host else { throw ShareLinkError.invalidURI }
        let port = url.port ?? 443
        let q = queryDict(url)
        let name = fragmentName(url) ?? host
        var stream: [String: Any] = [
            "network": (q["type"] ?? "tcp").lowercased(),
            "security": (q["security"] ?? "tls").lowercased(),
        ]
        if (stream["security"] as? String) == "tls" {
            stream["tlsSettings"] = [
                "serverName": q["sni"] ?? host,
                "fingerprint": q["fp"] ?? "chrome",
            ]
        }
        let outbound: [String: Any] = [
            "protocol": "trojan",
            "settings": [
                "servers": [[
                    "address": host,
                    "port": port,
                    "password": password,
                ]]
            ],
            "streamSettings": stream,
        ]
        return ParsedNode(name: name, outbound: outbound)
    }

    private static func parseShadowsocks(_ url: URL, raw: String) throws -> ParsedNode {
        // SIP002 ss://base64(method:pass)@host:port#name  OR ss://base64(method:pass@host:port)
        let name = fragmentName(url) ?? url.host ?? "Shadowsocks"
        if let host = url.host, let user = url.user {
            let port = url.port ?? 8388
            let decodedUser = user.removingPercentEncoding.flatMap { HappDeepLink.decodeBase64($0).flatMap { String(data: $0, encoding: .utf8) } } ?? user.removingPercentEncoding ?? user
            let parts = decodedUser.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { throw ShareLinkError.invalidURI }
            return shadowsocksNode(method: parts[0], password: parts[1], host: host, port: port, name: name)
        }
        // legacy full-body base64
        guard let schemeRange = raw.range(of: "://") else { throw ShareLinkError.invalidURI }
        var payload = String(raw[schemeRange.upperBound...])
        if let hash = payload.firstIndex(of: "#") {
            payload = String(payload[..<hash])
        }
        guard let data = HappDeepLink.decodeBase64(payload),
              let decoded = String(data: data, encoding: .utf8) else {
            throw ShareLinkError.invalidURI
        }
        // method:pass@host:port
        guard let at = decoded.firstIndex(of: "@") else { throw ShareLinkError.invalidURI }
        let userinfo = String(decoded[..<at])
        let hostport = String(decoded[decoded.index(after: at)...])
        let up = userinfo.split(separator: ":", maxSplits: 1).map(String.init)
        let hp = hostport.split(separator: ":", maxSplits: 1).map(String.init)
        guard up.count == 2, hp.count == 2, let port = Int(hp[1]) else { throw ShareLinkError.invalidURI }
        return shadowsocksNode(method: up[0], password: up[1], host: hp[0], port: port, name: name)
    }

    private static func shadowsocksNode(method: String, password: String, host: String, port: Int, name: String) -> ParsedNode {
        let outbound: [String: Any] = [
            "protocol": "shadowsocks",
            "settings": [
                "servers": [[
                    "address": host,
                    "port": port,
                    "method": method,
                    "password": password,
                ]]
            ],
        ]
        return ParsedNode(name: name, outbound: outbound)
    }

    private static func parseSocks(_ url: URL) throws -> ParsedNode {
        guard let host = url.host else { throw ShareLinkError.invalidURI }
        let port = url.port ?? 1080
        let name = fragmentName(url) ?? host
        var users: [[String: Any]] = []
        if let user = url.user {
            users.append([
                "user": user,
                "pass": url.password ?? "",
            ])
        }
        var server: [String: Any] = [
            "address": host,
            "port": port,
        ]
        if !users.isEmpty { server["users"] = users }
        let outbound: [String: Any] = [
            "protocol": "socks",
            "settings": ["servers": [server]],
        ]
        return ParsedNode(name: name, outbound: outbound)
    }

    private static func parseHysteria2(_ url: URL) throws -> ParsedNode {
        // Xray outbound uses protocol "hysteria2" on recent cores.
        let auth = url.user ?? ""
        guard let host = url.host else { throw ShareLinkError.invalidURI }
        let port = url.port ?? 443
        let q = queryDict(url)
        let name = fragmentName(url) ?? host
        var stream: [String: Any] = [
            "network": "hysteria2",
            "security": "tls",
            "tlsSettings": [
                "serverName": q["sni"] ?? host,
                "allowInsecure": (q["insecure"] == "1"),
            ],
        ]
        if let obfs = q["obfs"], !obfs.isEmpty {
            stream["hy2Settings"] = [
                "obfs": ["type": obfs, "password": q["obfs-password"] ?? ""],
            ]
        }
        let outbound: [String: Any] = [
            "protocol": "hysteria2",
            "settings": [
                "servers": [[
                    "address": host,
                    "port": port,
                    "password": auth,
                ]]
            ],
            "streamSettings": stream,
        ]
        return ParsedNode(name: name, outbound: outbound)
    }

    // MARK: - Utils

    private static func queryDict(_ url: URL) -> [String: String] {
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return [:] }
        var dict: [String: String] = [:]
        for item in comps.queryItems ?? [] {
            dict[item.name] = item.value ?? ""
        }
        return dict
    }

    private static func fragmentName(_ url: URL) -> String? {
        guard let f = url.fragment?.removingPercentEncoding, !f.isEmpty else { return nil }
        // Happ: Title?serverDescription=…
        return f.split(separator: "?", maxSplits: 1).first.map(String.init)
    }

    private static func optionalPort(_ url: URL) -> Int? {
        url.port
    }

    private static func intValue(_ any: Any?) -> Int? {
        if let i = any as? Int { return i }
        if let s = any as? String { return Int(s) }
        if let n = any as? NSNumber { return n.intValue }
        return nil
    }
}

enum ShareLinkError: LocalizedError {
    case empty
    case encode
    case invalidURI
    case unsupportedScheme(String)

    var errorDescription: String? {
        switch self {
        case .empty: return "No share links found."
        case .encode: return "Could not encode Xray JSON."
        case .invalidURI: return "Invalid share link."
        case .unsupportedScheme(let s): return "Unsupported scheme: \(s)"
        }
    }
}
