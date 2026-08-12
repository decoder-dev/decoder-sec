//
//  SettingsView.swift
//  DecoderSec
//
//  Created by NodePassProject on 5/2/26.
//

import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var tunnel: TunnelManager

    var body: some View {
        NavigationView {
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
                    NavigationLink {
                        DiagnosticsView()
                    } label: {
                        Label(String(localized: "Diagnostics"), systemImage: "stethoscope")
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
                    HStack {
                        Text(String(localized: "Version"))
                        Spacer()
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
