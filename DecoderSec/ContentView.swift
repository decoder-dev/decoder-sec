//
//  ContentView.swift
//  DecoderSec
//
//  Created by NodePassProject on 5/2/26.
//

import SwiftUI

struct ContentView: View {
    @ObservedObject private var tunnel = TunnelManager.shared
    @ObservedObject private var store = ConfigurationStore.shared
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
                    ProgressView("Handling deep link…")
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
            Button("OK", role: .cancel) { deepLinks.banner = nil }
        } message: {
            Text(deepLinks.banner ?? "")
        }
        .alert(
            "Deep link error",
            isPresented: Binding(
                get: { deepLinks.lastError != nil },
                set: { if !$0 { deepLinks.lastError = nil } }
            )
        ) {
            Button("OK", role: .cancel) { deepLinks.lastError = nil }
        } message: {
            Text(deepLinks.lastError ?? "")
        }
    }

    private func stopTunnel() {
        Task { await tunnel.setEnabled(false, configuration: store.active) }
    }

    /// Lightweight, non-blocking notice shown when local storage is degraded.
    /// The app stays usable; configurations just can't be persisted this run.
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
        .background(Brand.Color.surface.opacity(0.95), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Brand.Color.hairline, lineWidth: 1)
        )
    }
}

private struct RunningRootView: View {
    @ObservedObject private var store = ConfigurationStore.shared
    @ObservedObject private var appState = AppState.shared

    var body: some View {
        ZStack {
            Brand.Color.void.ignoresSafeArea()
            if appState.useZashboardEnabled && store.selectedCore != .xray {
                DashboardView()
            } else {
                VStack(spacing: 16) {
                    Image("BrandLogo")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 72, height: 72)
                        .neonGlow(radius: 18, opacity: 0.65)

                    Text(Brand.displayName)
                        .font(Brand.Font.display(22))
                        .foregroundStyle(Brand.Color.primaryText)

                    Text("\(store.selectedCore.displayName) is running")
                        .font(Brand.Font.mono(13))
                        .foregroundStyle(Brand.Color.secondaryText)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}
