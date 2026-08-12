//
//  NodePickerView.swift
//  DecoderSec
//

import SwiftUI

struct NodePickerView: View {
    let configuration: Configuration
    @Environment(\.dismiss) private var dismiss
    @State private var selectedTag: String

    init(configuration: Configuration) {
        self.configuration = configuration
        _selectedTag = State(initialValue: XrayNodeSelection.selectedTag(for: configuration.id)
            ?? XrayNodeCatalog.nodes(from: configuration.content).first?.tag
            ?? "proxy")
    }

    private var nodes: [XrayNode] {
        XrayNodeCatalog.nodes(from: configuration.content)
    }

    var body: some View {
        List {
            ForEach(nodes) { node in
                Button {
                    selectedTag = node.tag
                    XrayNodeSelection.setSelectedTag(node.tag, for: configuration.id)
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(node.displayName)
                                .foregroundStyle(.primary)
                            if let proto = node.proto {
                                Text(proto.uppercased())
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if selectedTag == node.tag {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        }
                    }
                }
            }
        }
        .navigationTitle(String(localized: "Servers"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(String(localized: "Done")) { dismiss() }
            }
        }
    }
}
