//
//  Brand.swift
//  DecoderSec
//
//  decoder sec. brand tokens — OLED black + neon emerald, expressive type.
//

import SwiftUI

enum Brand {
    static let displayName = BrandIdentity.displayName
    static let shortName = BrandIdentity.shortName
    static let legalName = BrandIdentity.legalName
    static let tagline = BrandIdentity.tagline

    enum Color {
        /// Neon emerald from the mark.
        static let neon = SwiftUI.Color(red: 0.00, green: 1.00, blue: 0.416)
        static let neonDim = SwiftUI.Color(red: 0.00, green: 0.72, blue: 0.30)
        static let void = SwiftUI.Color.black
        static let surface = SwiftUI.Color(red: 0.11, green: 0.11, blue: 0.118)
        static let surfaceElevated = SwiftUI.Color(red: 0.145, green: 0.145, blue: 0.16)
        static let hairline = SwiftUI.Color.white.opacity(0.08)
        static let secondaryText = SwiftUI.Color.white.opacity(0.55)
        static let primaryText = SwiftUI.Color.white.opacity(0.92)
        static let danger = SwiftUI.Color(red: 1.0, green: 0.35, blue: 0.35)
    }

    enum Font {
        /// Wordmark / hero — rounded display, not default Inter-like UI.
        static func display(_ size: CGFloat) -> SwiftUI.Font {
            .system(size: size, weight: .semibold, design: .rounded)
        }
        /// Status, chips, technical chrome.
        static func mono(_ size: CGFloat, weight: SwiftUI.Font.Weight = .medium) -> SwiftUI.Font {
            .system(size: size, weight: weight, design: .monospaced)
        }
        static func body(_ size: CGFloat = 16) -> SwiftUI.Font {
            .system(size: size, weight: .regular, design: .rounded)
        }
        static func callout(_ size: CGFloat = 14) -> SwiftUI.Font {
            .system(size: size, weight: .medium, design: .rounded)
        }
    }

    /// Solid brand panel surface (glass hooks land when we adopt iOS 26-only chrome).
    struct PanelBackground: View {
        var cornerRadius: CGFloat = 14

        var body: some View {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Brand.Color.surface)
        }
    }
}

struct BrandThemeModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .preferredColorScheme(.dark)
            .tint(Brand.Color.neon)
            .background(Brand.Color.void.ignoresSafeArea())
    }
}

extension View {
    func brandTheme() -> some View {
        modifier(BrandThemeModifier())
    }

    func brandPanel(cornerRadius: CGFloat = 14) -> some View {
        self
            .background(Brand.PanelBackground(cornerRadius: cornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Brand.Color.hairline, lineWidth: 1)
            )
    }
}

struct NeonGlow: ViewModifier {
    var radius: CGFloat = 12
    var opacity: Double = 0.4

    func body(content: Content) -> some View {
        content
            .shadow(color: Brand.Color.neon.opacity(opacity), radius: radius, x: 0, y: 0)
            .shadow(color: Brand.Color.neon.opacity(opacity * 0.35), radius: radius * 1.8, x: 0, y: 0)
    }
}

extension View {
    func neonGlow(radius: CGFloat = 12, opacity: Double = 0.4) -> some View {
        modifier(NeonGlow(radius: radius, opacity: opacity))
    }
}
