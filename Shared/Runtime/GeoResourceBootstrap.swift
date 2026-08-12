//
//  GeoResourceBootstrap.swift
//  Shared/Runtime
//

import Foundation

// Darwin strlen for C scan helpers.
import Darwin
enum GeoResourceBootstrap {
    static let geoipFileName = "geoip.dat"
    static let geositeFileName = "geosite.dat"

    private static let geoipURL = URL(string: "https://cdn.jsdelivr.net/gh/hydraponique/roscomvpn-geoip/release/geoip.dat")!
    private static let geositeURL = URL(string: "https://cdn.jsdelivr.net/gh/hydraponique/roscomvpn-geosite/release/geosite.dat")!
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

    static func fileReport(in directory: URL) -> String {
        [geoipFileName, geositeFileName].map { name in
            let url = directory.appendingPathComponent(name)
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
            if let size {
                return "\(name)=present(\(size) bytes)"
            }
            return "\(name)=missing"
        }.joined(separator: ", ")
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

    static func tryEnsurePresent(forConfig configJSON: String, in directory: URL, onComplete: ((Bool) -> Void)? = nil) {
        DispatchQueue.global(qos: .utility).async {
            let ok = (try? ensurePresentBlocking(forConfig: configJSON, in: directory)) != nil
            onComplete?(ok)
        }
    }

    /// Copy bundled geo from the appex Resources/geo/ folder (v2rayNG `initAssets` pattern).
    @discardableResult
    static func seedBundledGeoIfNeeded(into directory: URL) -> Bool {
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        var copied = false
        for name in [geoipFileName, geositeFileName] {
            let dest = directory.appendingPathComponent(name)
            guard !fm.fileExists(atPath: dest.path) else { continue }
            guard let bundled = Bundle.main.url(forResource: name, withExtension: nil, subdirectory: "geo")
                ?? Bundle.main.url(forResource: name, withExtension: nil) else { continue }
            if ds_copy_file(bundled.path, dest.path) == 0 {
                copied = true
            } else {
                do {
                    try fm.copyItem(at: bundled, to: dest)
                    copied = true
                } catch {
                    continue
                }
            }
        }
        return copied
    }

    static func referencesGeoip(_ configJSON: String) -> Bool {
        let flags = configJSON.withCString { ptr -> UInt32 in
            ds_config_scan(ptr, strlen(ptr))
        }
        if (flags & UInt32(DS_SCAN_GEOIP)) != 0 { return true }
        // Structured fallback when token appears only after JSON transforms.
        if routingRuleValues(in: configJSON, keys: ["ip"]).contains(where: isGeoipToken) {
            return true
        }
        return dnsDomainValues(in: configJSON).contains(where: isGeoipToken)
    }

    static func referencesGeosite(_ configJSON: String) -> Bool {
        let flags = configJSON.withCString { ptr -> UInt32 in
            ds_config_scan(ptr, strlen(ptr))
        }
        if (flags & UInt32(DS_SCAN_GEOSITE)) != 0 { return true }
        if routingRuleValues(in: configJSON, keys: ["domain"]).contains(where: isGeositeToken) {
            return true
        }
        return dnsDomainValues(in: configJSON).contains(where: isGeositeToken)
    }

    // MARK: - Parsing

    private static func isGeoipToken(_ value: String) -> Bool {
        value.lowercased().hasPrefix("geoip:")
    }

    private static func isGeositeToken(_ value: String) -> Bool {
        value.lowercased().hasPrefix("geosite:")
    }

    private static func routingRuleValues(in configJSON: String, keys: [String]) -> [String] {
        guard let root = parseRoot(configJSON),
              let routing = root["routing"] as? [String: Any],
              let rules = routing["rules"] as? [[String: Any]] else {
            return []
        }
        return rules.flatMap { rule in
            keys.flatMap { stringValues(from: rule[$0]) }
        }
    }

    private static func dnsDomainValues(in configJSON: String) -> [String] {
        guard let root = parseRoot(configJSON),
              let dns = root["dns"] as? [String: Any],
              let servers = dns["servers"] as? [Any] else {
            return []
        }
        return servers.flatMap { entry -> [String] in
            guard let obj = entry as? [String: Any] else { return [] }
            return stringValues(from: obj["domains"])
        }
    }

    private static func stringValues(from value: Any?) -> [String] {
        guard let value else { return [] }
        if let single = value as? String { return [single] }
        if let list = value as? [Any] { return list.compactMap { $0 as? String } }
        return []
    }

    private static func parseRoot(_ configJSON: String) -> [String: Any]? {
        guard let data = configJSON.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return root
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
