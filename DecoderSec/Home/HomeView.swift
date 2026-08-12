//
//  HomeView.swift
//  DecoderSec
//
//  decoder sec. home — one composition: brand, status, connect.
//

import NetworkExtension
import SwiftUI

struct HomeView: View {
    @ObservedObject private var appState = AppState.shared
    @ObservedObject private var tunnel = TunnelManager.shared
    @ObservedObject private var store = ConfigurationStore.shared
    @State private var coreSwitchBlocked = false
    @State private var pulse = false
    @State private var showSubscribe = false
    @State private var heroAppeared = false

    var body: some View {
        NavigationView {
            ZStack {
                Brand.Color.void.ignoresSafeArea()
                ambientBackground

                ScrollView {
                    VStack(spacing: 0) {
                        brandHero
                            .padding(.top, 28)
                            .padding(.bottom, 32)
                            .opacity(heroAppeared ? 1 : 0)
                            .offset(y: heroAppeared ? 0 : 12)

                        statusLine
                            .padding(.bottom, 24)

                        if store.active == nil {
                            emptyConfigCTA
                                .padding(.bottom, 28)
                        } else {
                            connectControl
                                .padding(.bottom, 32)
                        }

                        secondaryStrip
                            .padding(.bottom, 24)
                    }
                    .padding(.horizontal, 24)
                }
            }
            .navigationBarHidden(true)
            .alert(String(localized: "Tunnel is running"), isPresented: $coreSwitchBlocked) {
                Button(String(localized: "OK"), role: .cancel) {}
            } message: {
                Text(String(localized: "Stop the tunnel before switching cores."))
            }
            .alert(
                String(localized: "Connection failed"),
                isPresented: errorAlertBinding,
                presenting: tunnel.lastError
            ) { _ in
                Button(String(localized: "OK"), role: .cancel) { tunnel.clearLastError() }
            } message: { message in
                Text(message)
            }
            .sheet(isPresented: $showSubscribe) {
                SubscribeSheet()
            }
            .onAppear {
                withAnimation(.easeOut(duration: 0.55)) { heroAppeared = true }
                withAnimation(.easeInOut(duration: 2.6).repeatForever(autoreverses: true)) {
                    pulse = true
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    // MARK: - Sections

    private var ambientBackground: some View {
        ZStack {
            RadialGradient(
                colors: [
                    Brand.Color.neon.opacity(tunnel.status == .connected ? 0.16 : 0.06),
                    .clear,
                ],
                center: .center,
                startRadius: 20,
                endRadius: 360
            )
            .scaleEffect(pulse ? 1.06 : 0.94)
            .blur(radius: 10)
            .animation(.easeInOut(duration: 2.6).repeatForever(autoreverses: true), value: pulse)

            LinearGradient(
                colors: [
                    Brand.Color.void,
                    Brand.Color.surface.opacity(0.28),
                    Brand.Color.void,
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .opacity(0.85)
        }
        .allowsHitTesting(false)
    }

    private var brandHero: some View {
        VStack(spacing: 16) {
            Image("BrandLogo")
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: 108, height: 108)
                .neonGlow(
                    radius: tunnel.status == .connected ? 18 : 10,
                    opacity: tunnel.status == .connected ? 0.55 : 0.28
                )
                .accessibilityHidden(true)

            VStack(spacing: 8) {
                Text(Brand.displayName)
                    .font(Brand.Font.display(36))
                    .tracking(0.8)
                    .foregroundStyle(Brand.Color.primaryText)

                Text(Brand.tagline)
                    .font(Brand.Font.mono(12))
                    .tracking(0.5)
                    .foregroundStyle(Brand.Color.secondaryText)
            }
        }
    }

    private var statusLine: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
                .neonGlow(radius: 5, opacity: tunnel.status == .connected ? 0.8 : 0.15)

            Text(statusText.uppercased())
                .font(Brand.Font.mono(12, weight: .semibold))
                .tracking(1.4)
                .foregroundStyle(Brand.Color.secondaryText)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Capsule().fill(Brand.Color.surface.opacity(0.9)))
        .overlay(Capsule().stroke(Brand.Color.hairline, lineWidth: 1))
    }

    private var emptyConfigCTA: some View {
        VStack(spacing: 14) {
            Text(String(localized: "No active configuration"))
                .font(Brand.Font.display(18))
                .foregroundStyle(Brand.Color.primaryText)

            Text(String(localized: "Import a Happ link or https subscription to connect."))
                .font(Brand.Font.body(14))
                .foregroundStyle(Brand.Color.secondaryText)
                .multilineTextAlignment(.center)

            Button {
                showSubscribe = true
            } label: {
                Text(String(localized: "Add subscription"))
                    .font(Brand.Font.display(16))
                    .foregroundStyle(Brand.Color.void)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(
                        LinearGradient(
                            colors: [Brand.Color.neon, Brand.Color.neonDim],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                    )
                    .neonGlow(radius: 14, opacity: 0.4)
            }
            .buttonStyle(.plain)

            NavigationLink {
                ConfigurationsView()
            } label: {
                Text(String(localized: "Browse configurations"))
                    .font(Brand.Font.callout(14))
                    .foregroundStyle(Brand.Color.neon)
            }
        }
        .padding(20)
        .brandPanel(cornerRadius: 18)
    }

    private var connectControl: some View {
        Button {
            guard let active = store.active else { return }
            let on = !(tunnel.status == .connected || tunnel.status == .connecting)
            Task { await tunnel.setEnabled(on, configuration: active) }
        } label: {
            Text(connectTitle)
                .font(Brand.Font.display(17))
                .tracking(0.6)
                .foregroundStyle(Brand.Color.void)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
                .background(
                    LinearGradient(
                        colors: [Brand.Color.neon, Brand.Color.neonDim],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                )
                .neonGlow(radius: 14, opacity: isToggleDisabled ? 0.12 : 0.42)
        }
        .buttonStyle(.plain)
        .disabled(isToggleDisabled)
        .opacity(isToggleDisabled ? 0.45 : 1)
        .accessibilityLabel(connectTitle)
    }

    private var secondaryStrip: some View {
        VStack(spacing: 12) {
            NavigationLink {
                ConfigurationsView()
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(String(localized: "Configuration"))
                            .font(Brand.Font.mono(11))
                            .foregroundStyle(Brand.Color.secondaryText)
                        Text(store.active?.name ?? String(localized: "None"))
                            .font(Brand.Font.body(16))
                            .foregroundStyle(Brand.Color.primaryText)
                            .lineLimit(1)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Brand.Color.secondaryText)
                }
                .padding(16)
                .brandPanel()
            }
            .buttonStyle(.plain)

            HStack(spacing: 8) {
                ForEach(CoreType.allCases) { core in
                    coreChip(core)
                }
            }

            Toggle(isOn: $appState.useZashboardEnabled) {
                Text(String(localized: "Dashboard"))
                    .font(Brand.Font.body(15))
                    .foregroundStyle(Brand.Color.primaryText)
            }
            .disabled(isToggleDisabled)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .brandPanel()
        }
    }

    private func coreChip(_ core: CoreType) -> some View {
        let selected = store.selectedCore == core
        return Button {
            if tunnel.status.isActive {
                coreSwitchBlocked = true
            } else {
                store.selectedCore = core
            }
        } label: {
            Text(core.displayName)
                .font(Brand.Font.mono(11, weight: .semibold))
                .foregroundStyle(selected ? Brand.Color.void : Brand.Color.secondaryText)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity)
                .background(
                    selected ? Brand.Color.neon : Brand.Color.surface,
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(selected ? Brand.Color.neon : Brand.Color.hairline, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: - State

    private var connectTitle: String {
        switch tunnel.status {
        case .connected, .connecting: return String(localized: "Disconnect")
        default: return String(localized: "Connect")
        }
    }

    private var statusColor: Color {
        switch tunnel.status {
        case .connected: return Brand.Color.neon
        case .connecting, .reasserting: return Brand.Color.neon.opacity(0.55)
        case .disconnecting: return .orange
        default: return Brand.Color.secondaryText
        }
    }

    private var errorAlertBinding: Binding<Bool> {
        Binding(
            get: { tunnel.lastError != nil },
            set: { if !$0 { tunnel.clearLastError() } }
        )
    }

    private var statusText: String {
        if !tunnel.isReady { return String(localized: "Loading") }
        switch tunnel.status {
        case .connected: return String(localized: "Connected")
        case .connecting: return String(localized: "Connecting")
        case .disconnecting: return String(localized: "Disconnecting")
        case .reasserting: return String(localized: "Reconnecting")
        case .disconnected: return String(localized: "Disconnected")
        case .invalid: return String(localized: "Not Configured")
        @unknown default: return String(localized: "Unknown")
        }
    }

    private var isToggleDisabled: Bool {
        if !tunnel.isReady { return true }
        if tunnel.status.isTransitioning { return true }
        return store.active == nil
    }
}
