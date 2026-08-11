//
//  SettingsView.swift
//  Everywhere
//
//  Created by NodePassProject on 5/2/26.
//

import SwiftUI

struct SettingsView: View {
    @ObservedObject private var appState = AppState.shared
    @ObservedObject private var tunnel = TunnelManager.shared

    var body: some View {
        NavigationView {
            Form {
                Section {
                    HStack(spacing: 14) {
                        Image("BrandLogo")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 44, height: 44)
                            .neonGlow(radius: 8, opacity: 0.35)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(Brand.displayName)
                                .font(Brand.Font.display(18))
                            Text(Brand.tagline)
                                .font(Brand.Font.mono(11))
                                .foregroundStyle(Brand.Color.secondaryText)
                        }
                    }
                    .padding(.vertical, 4)
                    .listRowBackground(Brand.Color.surface)
                }

                Section("VPN") {
                    Toggle(isOn: $appState.alwaysOnEnabled) {
                        Label("Always On", systemImage: "bolt")
                    }
                    .disabled(tunnel.pendingReconnect)
                    NavigationLink {
                        TunnelSettingsView()
                    } label: {
                        Label("Tunnel", systemImage: "shield")
                    }
                }

                Section("Network") {
                    NavigationLink {
                        DNSSettingsView()
                    } label: {
                        Label("DNS", systemImage: "network")
                    }
                    NavigationLink {
                        RoutingSettingsView()
                    } label: {
                        Label("Happ routing", systemImage: "arrow.triangle.branch")
                    }
                }

                Section("IO") {
                    NavigationLink {
                        ResourcesView()
                    } label: {
                        Label("Resources", systemImage: "folder")
                    }
                }

                Section("About") {
                    NavigationLink {
                        AcknowledgementView()
                    } label: {
                        Label("Acknowledgements", systemImage: "heart")
                    }
                    Text("Based on Everywhere · GPLv3")
                        .font(Brand.Font.mono(11))
                        .foregroundStyle(Brand.Color.secondaryText)
                }
            }
            .background(Brand.Color.void)
            .navigationTitle("Settings")
            .modifier(HideScrollBackgroundIfAvailable())
            .onChange(of: appState.alwaysOnEnabled) { newValue in
                Task { await tunnel.applyAlwaysOn(newValue) }
            }
        }
        .navigationViewStyle(.stack)
    }
}

private struct HideScrollBackgroundIfAvailable: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 16.0, *) {
            content.scrollContentBackground(.hidden)
        } else {
            content
        }
    }
}
