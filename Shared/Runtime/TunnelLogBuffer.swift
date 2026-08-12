//
//  TunnelLogBuffer.swift
//  Shared/Runtime
//
//  Bounded in-memory ring buffer for Packet Tunnel lifecycle events.
//  Full Xray/mihomo/sing-box stdout is not exposed by EverywhereCore —
//  this captures provider-side events only (start/stop/geo/errors/IPC).
//
//  Also mirrors every line to the unified logging system (os_log/Logger).
//  ESign sideloads have no attached debugger/Xcode console, so when the
//  appex never reaches `startTunnel` (crash, missing entitlement) this ring
//  buffer is unreachable via IPC — os_log is the only channel a device log
//  viewer (Console.app over cable, or a third-party on-device log reader)
//  can still pick up.
//

import Foundation
import os

final class TunnelLogBuffer {
    static let shared = TunnelLogBuffer()

    private let lock = NSLock()
    private var lines: [String] = []
    private let capacity = 400
    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()
    private let osLogger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.decodersec.app.PacketTunnel",
        category: "tunnel"
    )

    private init() {}

    func append(_ message: String) {
        let stamp = formatter.string(from: Date())
        let line = "[\(stamp)] \(message)"
        lock.lock()
        lines.append(line)
        if lines.count > capacity {
            lines.removeFirst(lines.count - capacity)
        }
        lock.unlock()
        NSLog("DecoderSec: %@", message)
        osLogger.log("\(message, privacy: .public)")
    }

    func snapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return lines
    }

    func clear() {
        lock.lock()
        lines.removeAll(keepingCapacity: true)
        lock.unlock()
    }
}
