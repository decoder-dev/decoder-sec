//
//  DNSSettingsView.swift
//  DecoderSec
//

import SwiftUI
import Network

private struct DNSServerDraft: Identifiable, Equatable {
    let id = UUID()
    var value: String
}

struct DNSSettingsView: View {
    @Environment(\.editMode) private var editMode

    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var tunnel: TunnelManager

    @State private var serverDrafts: [DNSServerDraft] = []

    private var isEditing: Bool {
        if editMode?.wrappedValue.isEditing == true { return true }
        return false
    }

    var body: some View {
        Form {
            Section(String(localized: "DNS Servers")) {
                ForEach($serverDrafts) { $draft in
                    if isEditing == true {
                        TextField(String(localized: "Address"), text: $draft.value)
                            .keyboardType(.URL)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                    } else {
                        Text(draft.value)
                    }
                }
                .onDelete { offsets in
                    serverDrafts.remove(atOffsets: offsets)
                    save()
                }
                .onMove { source, destination in
                    serverDrafts.move(fromOffsets: source, toOffset: destination)
                    save()
                }
            }

            Section {
                Button(String(localized: "Reset to default")) {
                    reset()
                }
            }
        }
        .navigationTitle(String(localized: "DNS"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                EditButton()
            }
        }
        .onAppear { loadInitial() }
        .onChange(of: isEditing) { newValue in
            if newValue {
                serverDrafts.append(DNSServerDraft(value: ""))
            } else {
                save()
            }
        }
    }

    private func loadInitial() {
        serverDrafts = appState.dnsServers.map { DNSServerDraft(value: $0) }
    }

    private func save() {
        serverDrafts = serverDrafts
            .filter { !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let servers = serverDrafts
            .map { $0.value.trimmingCharacters(in: .whitespacesAndNewlines) }
        appState.dnsServers = servers
        Task { await tunnel.reconnect() }
    }

    private func reset() {
        appState.dnsServers = EVCore.defaultDNSServers
        Task { await tunnel.reconnect() }
    }

    private func isValid(_ raw: String) -> Bool {
        let s = raw.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return false }
        return IPv4Address(s) != nil || IPv6Address(s) != nil
    }
}
