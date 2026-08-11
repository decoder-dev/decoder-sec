//
//  SettingsView.swift
//  DecoderSec
//
//  Created by NodePassProject on 5/2/26.
//

import SwiftUI

struct SettingsView: View {
    @ObservedObject private var appState = AppState.shared
    @ObservedObject private var tunnel = TunnelManager.shared

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 14) {
                        Image("BrandLogo")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 44, height: 44)
                            .neonGlow(radius: 8, opacity: 0.28)
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

                Section(String(localized: "VPN")) {
                    Toggle(isOn: $appState.alwaysOnEnabled) {
                        Label(String(localized: "Always On"), systemImage: "bolt")
                    }
                    .disabled(tunnel.pendingReconnect)
                    NavigationLink {
                        TunnelSettingsView()
                    } label: {
                        Label(String(localized: "Tunnel"), systemImage: "shield")
                    }
                }

                Section(String(localized: "Network")) {
                    NavigationLink {
                        DNSSettingsView()
                    } label: {
                        Label(String(localized: "DNS"), systemImage: "network")
                    }
                    NavigationLink {
                        RoutingSettingsView()
                    } label: {
                        Label(String(localized: "Happ routing"), systemImage: "arrow.triangle.branch")
                    }
                }

                Section(String(localized: "IO")) {
                    NavigationLink {
                        ResourcesView()
                    } label: {
                        Label(String(localized: "Resources"), systemImage: "folder")
                    }
                }

                Section(String(localized: "About")) {
                    NavigationLink {
                        AcknowledgementView()
                    } label: {
                        Label(String(localized: "Acknowledgements"), systemImage: "heart")
                    }
                    LabeledContent(String(localized: "Version")) {
                        Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")
                            .font(Brand.Font.mono(12))
                            .foregroundStyle(Brand.Color.secondaryText)
                    }
                    Text("decoder-sec · GPLv3")
                        .font(Brand.Font.mono(11))
                        .foregroundStyle(Brand.Color.secondaryText)
                }
            }
            .background(Brand.Color.void)
            .navigationTitle(String(localized: "Settings"))
            .scrollContentBackground(.hidden)
            .onChange(of: appState.alwaysOnEnabled) { _, newValue in
                Task { await tunnel.applyAlwaysOn(newValue) }
            }
        }
    }
}
