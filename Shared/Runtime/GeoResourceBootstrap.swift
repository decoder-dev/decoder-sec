//
//  GeoResourceBootstrap.swift
//  Shared/Runtime
//
//  Geo files live in the Packet Tunnel container (no App Groups). Missing
//  geosite/geoip.dat is a common reason EvcoreStartCore fails for Happ configs.
//

import Foundation

enum GeoResourceBootstrap {
    static let geoipFileName = "geoip.dat"
    static let geositeFileName = "geosite.dat"

    private static let geoipURL = URL(string: "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat")!
    private static let geositeURL = URL(string: "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat")!
    private static let downloadTimeout: TimeInterval = 12

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
            guard !missing.isEmpty else { return nil }
            return missing.joined(separator: ", ")
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

    /// Best-effort download. Returns without throwing when download fails —
    /// caller should strip geo rules if files are still missing.
    static func tryEnsurePresent(forConfig configJSON: String, in directory: URL) {
        let snapshot = status(forConfig: configJSON, in: directory)
        guard !snapshot.isReady else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let group = DispatchGroup()
        if snapshot.needsGeoip && !snapshot.hasGeoip {
            group.enter()
            downloadAsync(from: geoipURL, to: directory.appendingPathComponent(geoipFileName)) {
                group.leave()
            }
        }
        if snapshot.needsGeosite && !snapshot.hasGeosite {
            group.enter()
            downloadAsync(from: geositeURL, to: directory.appendingPathComponent(geositeFileName)) {
                group.leave()
            }
        }
        _ = group.wait(timeout: .now() + downloadTimeout + 2)
    }

    static func referencesGeoip(_ configJSON: String) -> Bool {
        configJSON.range(of: #"geoip:"#, options: .regularExpression) != nil
            || configJSON.contains("\"geoip:")
            || configJSON.contains("geoip:")
    }

    static func referencesGeosite(_ configJSON: String) -> Bool {
        configJSON.range(of: #"geosite:"#, options: .regularExpression) != nil
            || configJSON.contains("\"geosite:")
            || configJSON.contains("geosite:")
    }

    private static func downloadAsync(from url: URL, to destination: URL, completion: @escaping () -> Void) {
        let task = URLSession.shared.downloadTask(with: url) { tempURL, response, error in
            defer { completion() }
            guard error == nil, let tempURL else { return }
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) { return }
            let fm = FileManager.default
            try? fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: destination.path) {
                try? fm.removeItem(at: destination)
            }
            try? fm.moveItem(at: tempURL, to: destination)
        }
        task.resume()
        DispatchQueue.global().asyncAfter(deadline: .now() + downloadTimeout) {
            task.cancel()
        }
    }
}
