//
//  TunnelFD.swift
//  DecoderSec
//
//  Created by NodePassProject on 5/2/26.
//

import Darwin
import NetworkExtension

//   AF_SYSTEM         = 32  (sys/socket.h)
//   SYSPROTO_CONTROL  = 2   (sys/sys_domain.h)
//   UTUN_OPT_IFNAME   = 2   (net/if_utun.h)
enum TunnelFD {
    private static let afSystem: UInt8 = 32
    private static let sysprotoControl: Int32 = 2
    private static let utunOptIfname: Int32 = 2

    static func lookup(for _: NEPacketTunnelFlow, maxAttempts: Int = 12, delayMs: Int = 50) -> Int32 {
        for attempt in 0..<maxAttempts {
            if let fd = scanUtunFDs() { return fd }
            if attempt + 1 < maxAttempts {
                usleep(useconds_t(delayMs * 1000))
            }
        }
        return -1
    }

    private static func scanUtunFDs() -> Int32? {
        var best: Int32?
        var bestIndex = -1
        for fd in Int32(0)..<1024 where isUtunSocket(fd) {
            if let idx = utunIndex(for: fd), idx >= bestIndex {
                bestIndex = idx
                best = fd
            } else if best == nil {
                best = fd
            }
        }
        return best
    }

    private static func utunIndex(for fd: Int32) -> Int? {
        var nameBuf = [CChar](repeating: 0, count: 96)
        var nameLen = socklen_t(nameBuf.count)
        let optRes = nameBuf.withUnsafeMutableBufferPointer { buf in
            getsockopt(fd, sysprotoControl, utunOptIfname, buf.baseAddress, &nameLen)
        }
        guard optRes == 0 else { return nil }
        let name = String(cString: nameBuf)
        guard name.hasPrefix("utun") else { return nil }
        return Int(name.dropFirst(4)) ?? 0
    }

    private static func isUtunSocket(_ fd: Int32) -> Bool {
        var saBuf = [UInt8](repeating: 0, count: 32)
        var saLen = socklen_t(saBuf.count)
        let getRes = saBuf.withUnsafeMutableBufferPointer { buf -> Int32 in
            buf.baseAddress!.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                getpeername(fd, sa, &saLen)
            }
        }
        guard getRes == 0, saBuf[1] == afSystem else { return false }

        var nameBuf = [CChar](repeating: 0, count: 96)
        var nameLen = socklen_t(nameBuf.count)
        let optRes = nameBuf.withUnsafeMutableBufferPointer { buf in
            getsockopt(fd, sysprotoControl, utunOptIfname, buf.baseAddress, &nameLen)
        }
        return optRes == 0
    }
}
