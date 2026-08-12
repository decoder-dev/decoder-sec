//
//  TunnelFD.swift
//  DecoderSec
//
//  Thin Swift wrapper — heavy utun FD scan lives in Shared/C/ds_tunnel_fd.c
//

import Foundation

enum TunnelFD {
    /// Locate the Packet Tunnel utun control socket for EvcoreStartCore.
    static func lookup(for _: Any? = nil, maxAttempts: Int = 12, delayMs: Int = 50) -> Int32 {
        ds_utun_lookup_fd(Int32(maxAttempts), Int32(delayMs))
    }
}
