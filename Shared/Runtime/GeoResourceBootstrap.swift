//
//  GeoResourceBootstrap.swift
//  Shared/Runtime
//
//  Ensures Xray geo resources exist in the Packet Tunnel container before
//  EvcoreStartCore. The host app and extension do not share Application
//  Support without App Groups, so geo files imported in Settings → Resources
//  are not visible here — we bootstrap standard geoip/geosite.dat on demand.
//

import Foundation

enum GeoResourceBootstrap {
    static let geoipFileName = "geoip.dat"
    static let geositeFileName = "geosite.dat"

    private static let geoipURL = URL(string: "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat")!
    private static let geositeURL = URL(string: "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat")!

    struct Status: Equatable {
        var directory: String
        var needsGeoip: Bool
        var needsGeosite: Bool
        var hasGeoip: Bool
        var hasGeosite: Bool

        var isReady: Bool {
            (!needsGeoip || hasGeoip) && (!needsGeosite || hasGeosite)
        }
    }

    static func status(forConfig configJSON: String, in directory: URL) -> Status {
        let needsIp = referencesGeoip(configJSON)
        let needsSite = referencesGeosite(configJSON)
        let fm = FileManager.default
        return Status(
            directory: directory.path,
            needsGeoip: needsIp,
            needsGeosite: needsSite,
            hasGeoip: fm.fileExists(atPath: directory.appendingPathComponent(geoipFileName).path),
            hasGeosite: fm.fileExists(atPath: directory.appendingPathComponent(geositeFileName).path)
        )
    }

    /// Downloads any missing geo files referenced by the config.
    static func ensurePresent(forConfig configJSON: String, in directory: URL) async throws {
        let snapshot = status(forConfig: configJSON, in: directory)
        guard !snapshot.isReady else { return }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        if snapshot.needsGeoip && !snapshot.hasGeoip {
            try await download(from: geoipURL, to: directory.appendingPathComponent(geoipFileName))
        }
        if snapshot.needsGeosite && !snapshot.hasGeosite {
            try await download(from: geositeURL, to: directory.appendingPathComponent(geositeFileName))
        }
    }

    static func referencesGeoip(_ configJSON: String) -> Bool {
        configJSON.contains("geoip:")
    }

    static func referencesGeosite(_ configJSON: String) -> Bool {
        configJSON.contains("geosite:")
    }

    private static func download(from url: URL, to destination: URL) async throws {
        let (tempURL, response) = try await URLSession.shared.download(from: url)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw NSError(
                domain: "GeoResourceBootstrap",
                code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "Geo download failed (HTTP \(http.statusCode))."]
            )
        }
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        try fm.moveItem(at: tempURL, to: destination)
    }
}
