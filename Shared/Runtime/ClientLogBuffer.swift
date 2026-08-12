//
//  ClientLogBuffer.swift
//  Shared/Runtime
//
//  App-side connect pipeline log. Unlike TunnelLogBuffer (lives only inside
//  the Packet Tunnel process), this survives when the extension never launches
//  — which is exactly the "Log console empty + failed before tunnel" case.
//

import Foundation
import os

final class ClientLogBuffer {
    static let shared = ClientLogBuffer()

    private let lock = NSLock()
    private var lines: [String] = []
    private let capacity = 200
    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()
    private let osLogger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.decodersec.app",
        category: "app"
    )

    private init() {}

    func append(_ message: String) {
        let stamp = formatter.string(from: Date())
        let line = "[\(stamp)] [app] \(message)"
        lock.lock()
        lines.append(line)
        if lines.count > capacity {
            lines.removeFirst(lines.count - capacity)
        }
        lock.unlock()
        NSLog("DecoderSecApp: %@", message)
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
