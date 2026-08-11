import Foundation
import UIKit

/// Stable device identity for Remnawave/Happ subscription endpoints that require `X-HWID`.
enum DeviceIdentity {
    private static let hwidKey = "decodersec.device.hwid"

    /// Matches Remnawave validation: `^[a-zA-Z0-9=-]{10,64}$`
    static var hwid: String {
        let defaults = UserDefaults.standard
        if let existing = defaults.string(forKey: hwidKey),
           existing.range(of: #"^[a-zA-Z0-9=-]{10,64}$"#, options: .regularExpression) != nil {
            return existing
        }

        let generated = generateHWID()
        defaults.set(generated, forKey: hwidKey)
        return generated
    }

    static var userAgent: String {
        "Happ/3.9.0/ios DecoderSec/\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0")"
    }

    static var deviceOS: String { "iOS" }

    static var osVersion: String {
        UIDevice.current.systemVersion
    }

    static var deviceModel: String {
        var systemInfo = utsname()
        uname(&systemInfo)
        return withUnsafePointer(to: &systemInfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) {
                String(cString: $0)
            }
        }
    }

    static func applySubscriptionHeaders(to request: inout URLRequest) {
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(hwid, forHTTPHeaderField: "X-HWID")
        request.setValue(deviceOS, forHTTPHeaderField: "x-device-os")
        request.setValue(osVersion, forHTTPHeaderField: "x-ver-os")
        request.setValue(deviceModel, forHTTPHeaderField: "x-device-model")
        request.setValue("1", forHTTPHeaderField: "x-app-version")
    }

    private static func generateHWID() -> String {
        // Prefer vendor UUID (stable per vendor on device), then fall back to random.
        let raw = (UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString)
            .replacingOccurrences(of: "-", with: "")
        let clipped = String(raw.prefix(32))
        if clipped.count >= 10 {
            return clipped
        }
        return String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(32))
    }
}
