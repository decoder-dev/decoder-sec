//
//  TunnelSettingsView.swift
//  DecoderSec
//

import SwiftUI

struct TunnelSettingsView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var tunnel: TunnelManager

    var body: some View {
        Form {
            Section {
                Toggle(String(localized: "Include All Networks"), isOn: $appState.tunnelIncludeAllNetworks)
            }

            Section {
                Toggle(String(localized: "Include Local Networks"), isOn: $appState.tunnelIncludeLocalNetworks)
                if #available(iOS 17.0, *) {
                    Toggle(String(localized: "Include APNs"), isOn: $appState.tunnelIncludeAPNs)
                }
                if #available(iOS 16.4, *) {
                    Toggle(String(localized: "Include Cellular Services"), isOn: $appState.tunnelIncludeCellularServices)
                }
            } footer: {
                if #unavailable(iOS 17.0) {
                    Text(String(localized: "APNs toggle requires iOS 17+."))
                }
            }
            .disabled(!appState.tunnelIncludeAllNetworks)
        }
        .navigationTitle(String(localized: "Tunnel"))
        .navigationBarTitleDisplayMode(.inline)
        .disabled(tunnel.pendingReconnect)
        .onChange(of: appState.tunnelIncludeAllNetworks) { _ in
            Task { await tunnel.reconnect() }
        }
        .onChange(of: appState.tunnelIncludeLocalNetworks) { _ in
            Task { await tunnel.reconnect() }
        }
        .onChange(of: appState.tunnelIncludeAPNs) { _ in
            Task { await tunnel.reconnect() }
        }
        .onChange(of: appState.tunnelIncludeCellularServices) { _ in
            Task { await tunnel.reconnect() }
        }
    }
}
