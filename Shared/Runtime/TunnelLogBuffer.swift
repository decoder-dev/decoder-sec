//
//  TunnelLogBuffer.swift
//  Shared/Runtime
//
//  Bounded in-memory ring buffer for Packet Tunnel lifecycle events.
//  Full Xray/mihomo/sing-box stdout is not exposed by EverywhereCore —
//  this captures provider-side events only (start/stop/geo/errors/IPC).
//

import Foundation

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
