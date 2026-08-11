//
//  BrandIdentity.swift
//  DecoderSec
//

import Foundation

enum BrandIdentity {
    static let displayName = "decoder sec."
    static let shortName = "decoder"
    static let legalName = "Decoder Sec"
    static let tagline = "Private tunnels. Your rules."

    /// Default IDs used at build time. After ESign remaps the bundle ID,
    /// prefer ``EVCore.Identifier/networkExtension`` which reads the embedded appex.
    static let bundleID = "com.decodersec.app"
    static let networkExtensionID = "com.decodersec.app.PacketTunnel"
}
