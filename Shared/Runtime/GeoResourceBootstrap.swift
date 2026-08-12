//
//  GeoResourceBootstrap.swift
//  Shared/Runtime
//

import Foundation

enum GeoResourceBootstrap {
    static let geoipFileName = "geoip.dat"
    static let geositeFileName = "geosite.dat"

    private static let geoipURL = URL(string: "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat")!
    private static let geositeURL = URL(string: "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat")!
    private static let downloadTimeout: TimeInterval = 45

    struct Status: Equatable {
        var directory: String
        var needsGeoip: Bool
        var needsGeosite: Bool
        var hasGeoip: Bool
        var hasGeosite: Bool

        var isReady: Bool {
            (!needsGeoip || hasGeoip) && (!needsGeosite || hasGeosite)
        }

        var missingSummary: String? {
            var missing: [String] = []
            if needsGeoip && !hasGeoip { missing.append(geoipFileName) }
            if needsGeosite && !hasGeosite { missing.append(geositeFileName) }
            return missing.isEmpty ? nil : missing.joined(separator: ", ")
        }
    }

    static func status(forConfig configJSON: String, in directory: URL) -> Status {
        let fm = FileManager.default
        return Status(
            directory: directory.path,
            needsGeoip: referencesGeoip(configJSON),
            needsGeosite: referencesGeosite(configJSON),
            hasGeoip: fm.fileExists(atPath: directory.appendingPathComponent(geoipFileName).path),
            hasGeosite: fm.fileExists(atPath: directory.appendingPathComponent(geositeFileName).path)
        )
    }

    static func ensurePresentBlocking(forConfig configJSON: String, in directory: URL) throws {
        let snapshot = status(forConfig: configJSON, in: directory)
        guard !snapshot.isReady else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let group = DispatchGroup()
        var firstError: Error?

        if snapshot.needsGeoip && !snapshot.hasGeoip {
            group.enter()
            downloadAsync(from: geoipURL, to: directory.appendingPathComponent(geoipFileName)) { error in
                if let error, firstError == nil { firstError = error }
                group.leave()
            }
        }
        if snapshot.needsGeosite && !snapshot.hasGeosite {
            group.enter()
            downloadAsync(from: geositeURL, to: directory.appendingPathComponent(geositeFileName)) { error in
                if let error, firstError == nil { firstError = error }
                group.leave()
            }
        }

        let wait = group.wait(timeout: .now() + downloadTimeout)
        if wait == .timedOut {
            throw NSError(domain: "GeoResourceBootstrap", code: -3,
                          userInfo: [NSLocalizedDescriptionKey: "Geo download timed out after \(Int(downloadTimeout))s."])
        }
        if let firstError { throw firstError }
    }

    static func tryEnsurePresent(forConfig configJSON: String, in directory: URL) {
        try? ensurePresentBlocking(forConfig: configJSON, in: directory)
    }

    static func referencesGeoip(_ configJSON: String) -> Bool {
        routingRuleStrings(in: configJSON, key: "ip").contains { $0.lowercased().hasPrefix("geoip:") }
    }

    static func referencesGeosite(_ configJSON: String) -> Bool {
        routingRuleStrings(in: configJSON, key: "domain").contains { $0.lowercased().hasPrefix("geosite:") }
    }

    private static func routingRuleStrings(in configJSON: String, key: String) -> [String] {
        guard let data = configJSON.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let routing = root["routing"] as? [String: Any],
              let rules = routing["rules"] as? [[String: Any]] else {
            return []
        }
        return rules.flatMap { rule -> [String] in
            guard let values = rule[key] as? [Any] else { return [] }
            return values.compactMap { $0 as? String }
        }
    }

    private static func downloadAsync(from url: URL, to destination: URL, completion: @escaping (Error?) -> Void) {
        let task = URLSession.shared.downloadTask(with: url) { tempURL, response, error in
            if let error { completion(error); return }
            guard let tempURL else {
                completion(NSError(domain: "GeoResourceBootstrap", code: -2,
                                 userInfo: [NSLocalizedDescriptionKey: "Geo download returned no file."]))
                return
            }
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                completion(NSError(domain: "GeoResourceBootstrap", code: http.statusCode,
                                   userInfo: [NSLocalizedDescriptionKey: "Geo download failed (HTTP \(http.statusCode))."]))
                return
            }
            do {
                let fm = FileManager.default
                if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
                try fm.moveItem(at: tempURL, to: destination)
                completion(nil)
            } catch {
                completion(error)
            }
        }
        task.resume()
    }
}
