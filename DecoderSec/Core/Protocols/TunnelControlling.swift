//
//  TunnelControlling.swift
//  DecoderSec/Core/Protocols
//
//  Protocol seam for the tunnel lifecycle — lets Views and DeepLinkCenter
//  depend on an abstraction instead of TunnelManager.shared directly.
//  Phase 2 rewrite.
//

import Foundation
import NetworkExtension

@MainActor
protocol TunnelControlling: AnyObject, ObservableObject {
    var status: NEVPNStatus { get }
    var isReady: Bool { get }
    var coreRunning: Bool { get }
    var lastError: String? { get }
    var pendingReconnect: Bool { get }

    func setEnabled(_ on: Bool, configuration: Configuration?) async
    func reconnect() async
    func applyAlwaysOn(_ enabled: Bool) async
    func clearLastError()
    func refreshCoreStatus(retries: Int)
}
