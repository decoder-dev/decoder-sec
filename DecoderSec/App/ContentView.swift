//
//  ContentView.swift
//  DecoderSec
//
//  Created by NodePassProject on 5/2/26.
//

import NetworkExtension
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var tunnel: TunnelManager
    @EnvironmentObject private var store: ConfigurationStore
    @EnvironmentObject private var deepLinks: DeepLinkCenter
    @State private var minimized: Bool = false

    var body: some View {
        ZStack {
            Brand.Color.void.ignoresSafeArea()

            if tunnel.coreRunning && !minimized {
                RunningRootView()
            } else {
                TabView {
                    HomeView()
                        .tabItem { Label(Brand.shortName, systemImage: "shield.lefthalf.filled") }

                    SettingsView()
                        .tabItem { Label(String(localized: "Settings"), systemImage: "slider.horizontal.3") }
                }
            }

            if tunnel.coreRunning {
                FloatingMenuButton(
                    isMinimized: minimized,
                    onToggleMinimize: { minimized.toggle() },
                    onStop: stopTunnel
                )
            }
        }
        .brandTheme()
        .animation(.default, value: tunnel.coreRunning)
        .animation(.default, value: minimized)
        .onChange(of: tunnel.coreRunning) { running in
            if !running { minimized = false }
        }
        .overlay(alignment: .top) {
            VStack(spacing: 8) {
                if let storeError = store.storeError {
                    storageBanner(storeError)
                }
                if deepLinks.isBusy {
                    ProgressView(String(localized: "Handling deep link…"))
                        .tint(Brand.Color.neon)
                        .padding(10)
                        .background(Brand.Color.surface.opacity(0.92), in: Capsule())
                        .overlay(Capsule().stroke(Brand.Color.hairline, lineWidth: 1))
                }
            }
            .padding(.top, 8)
            .padding(.horizontal, 16)
            .animation(.default, value: store.storeError)
        }
        .alert(
            Brand.displayName,
            isPresented: Binding(
                get: { deepLinks.banner != nil },
                set: { if !$0 { deepLinks.banner = nil } }
            )
        ) {
            Button(String(localized: "OK"), role: .cancel) { deepLinks.banner = nil }
        } message: {
            Text(deepLinks.banner ?? "")
        }
        .alert(
            String(localized: "Deep link error"),
            isPresented: Binding(
                get: { deepLinks.lastError != nil },
                set: { if !$0 { deepLinks.lastError = nil } }
            )
        ) {
            Button(String(localized: "OK"), role: .cancel) { deepLinks.lastError = nil }
        } message: {
            Text(deepLinks.lastError ?? "")
        }
    }

    private func stopTunnel() {
        Task { await tunnel.setEnabled(false, configuration: store.active) }
    }

    private func storageBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(String(localized: "Storage unavailable"))
                    .font(Brand.Font.mono(11, weight: .semibold))
                    .foregroundStyle(Brand.Color.primaryText)
                Text(message)
                    .font(Brand.Font.mono(10))
                    .foregroundStyle(Brand.Color.secondaryText)
                    .lineLimit(3)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .brandPanel(cornerRadius: 12)
    }
}

private struct RunningRootView: View {
    @EnvironmentObject private var store: ConfigurationStore
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var tunnel: TunnelManager
    @State private var pulse = false

    var body: some View {
        ZStack {
            Brand.Color.void.ignoresSafeArea()
            if appState.useZashboardEnabled && store.selectedCore != .xray {
                DashboardView()
            } else {
                sessionChrome
            }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }

    private var sessionChrome: some View {
        ZStack {
            RadialGradient(
                colors: [Brand.Color.neon.opacity(0.14), .clear],
                center: .center,
                startRadius: 10,
                endRadius: 280
            )
            .scaleEffect(pulse ? 1.05 : 0.95)
            .allowsHitTesting(false)

            VStack(spacing: 18) {
                Image("BrandLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 76, height: 76)
                    .neonGlow(radius: 16, opacity: 0.5)

                Text(Brand.displayName)
                    .font(Brand.Font.display(24))
                    .foregroundStyle(Brand.Color.primaryText)

                Text(String(localized: "\(store.selectedCore.displayName) is running"))
                    .font(Brand.Font.mono(13))
                    .foregroundStyle(Brand.Color.secondaryText)

                if let name = store.active?.name {
                    Text(name)
                        .font(Brand.Font.body(15))
                        .foregroundStyle(Brand.Color.primaryText)
                        .lineLimit(1)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .brandPanel(cornerRadius: 12)
                        .padding(.top, 8)
                }

                Text(sessionStatus)
                    .font(Brand.Font.mono(11, weight: .semibold))
                    .tracking(1.2)
                    .foregroundStyle(Brand.Color.neon)
                    .padding(.top, 4)
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var sessionStatus: String {
        switch tunnel.status {
        case .connected: return String(localized: "Connected").uppercased()
        case .connecting: return String(localized: "Connecting").uppercased()
        case .reasserting: return String(localized: "Reconnecting").uppercased()
        default: return String(localized: "Running").uppercased()
        }
    }
}
