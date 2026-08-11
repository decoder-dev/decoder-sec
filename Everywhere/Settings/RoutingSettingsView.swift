//
//  RoutingSettingsView.swift
//  Everywhere
//
//  Happ routing profiles imported via happ://routing/…
//

import SwiftUI

struct RoutingSettingsView: View {
    @ObservedObject private var routing = RoutingProfileStore.shared

    var body: some View {
        Form {
            Section {
                Toggle("Enable Happ routing", isOn: $routing.routingEnabled)
            } footer: {
                Text("When enabled, the active Happ routing profile is merged into Xray configs on import/connect. Deep links: happ://routing/onadd/… and happ://routing/off.")
            }

            Section("Profiles") {
                if routing.profiles.isEmpty {
                    Text("No profiles yet. Open a happ://routing/onadd/… link.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(routing.profiles) { profile in
                        Button {
                            routing.activeProfileID = profile.id
                            routing.routingEnabled = true
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(profile.name)
                                    if let src = profile.sourceURL {
                                        Text(src)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                                Spacer()
                                if routing.activeProfileID == profile.id {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.accent)
                                }
                            }
                        }
                        .tint(.primary)
                    }
                }
            }
        }
        .navigationTitle("Happ routing")
        .navigationBarTitleDisplayMode(.inline)
    }
}
