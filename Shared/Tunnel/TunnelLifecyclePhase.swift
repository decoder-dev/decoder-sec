//
//  TunnelLifecyclePhase.swift
//  Shared
//
//  App-side lifecycle mirror for NEVPNStatus + core IPC.
//  See docs/TUNNEL_SCHEME.md.
//

import Foundation

enum TunnelLifecyclePhase: Equatable {
    case idle
    case preparingProfile
    case connecting
    case tunnelUpCorePending
    case ready
    case coreFailed
    case disconnecting
    case failed(String)

    var isOperational: Bool {
        switch self {
        case .ready, .tunnelUpCorePending, .coreFailed: true
        default: false
        }
    }

    var displaySummary: String {
        switch self {
        case .idle:
            return String(localized: "Disconnected")
        case .preparingProfile:
            return String(localized: "Preparing VPN profile…")
        case .connecting:
            return String(localized: "Connecting…")
        case .tunnelUpCorePending:
            return String(localized: "Tunnel up — starting core…")
        case .ready:
            return String(localized: "Connected")
        case .coreFailed:
            return String(localized: "Connected (core not running)")
        case .disconnecting:
            return String(localized: "Disconnecting…")
        case .failed(let message):
            return message
        }
    }
}
