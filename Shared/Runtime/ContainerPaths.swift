//
//  ContainerPaths.swift
//  DecoderSec (Shared/Runtime)
//
//  Local filesystem paths used by the host app and the Packet Tunnel.
//  Split from EVCore.swift — Phase 2 rewrite.
//

import Foundation

enum ContainerPaths {
    static let defaultDNSServers = ["1.1.1.1", "8.8.8.8"]

    /// Application Support container shared between app and extension (no App Group).
    static var containerURL: URL {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.temporaryDirectory
        let url = base.appendingPathComponent("DecoderSec", isDirectory: true)
        try? fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Per-core geo/resource directory (Xray: geo, sing-box: geoip etc.).
    static func resourcesURL(for core: CoreType) -> URL {
        let url = containerURL
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent(core.rawValue, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
