//
//  ConfigurationsView.swift
//  DecoderSec
//
//  Created by NodePassProject on 5/2/26.
//

import SwiftUI
import UniformTypeIdentifiers

struct ConfigurationsView: View {
    @EnvironmentObject private var store: ConfigurationStore
    @EnvironmentObject private var tunnel: TunnelManager
    @State private var pendingDelete: Configuration?
    @State private var blockedAlert = false
    @State private var fileImporting = false
    @State private var isDownloading = false
    @State private var importErrorMessage: String?
    @State private var showSubscribe = false
    @State private var isRefreshingAll = false

    private var activeID: UUID? { store.activeIDByCoreType[store.selectedCore] }

    var body: some View {
        List {
            ForEach(store.configurationsForSelectedCore) { config in
                NavigationLink {
                    ConfigEditorScreen(configuration: config)
                } label: {
                    row(for: config)
                }
                .swipeActions(edge: .leading, allowsFullSwipe: false) {
                    Button {
                        quickConnect(config)
                    } label: {
                        Label(String(localized: "Connect"), systemImage: "bolt.fill")
                    }
                    .tint(.mint)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    if config.sourceURL != nil {
                        Button {
                            updateSubscription(config)
                        } label: {
                            Label("Update", systemImage: "arrow.clockwise")
                        }
                        .tint(.green)
                    }
                    Button {
                        promptRename(config)
                    } label: {
                        Label("Rename", systemImage: "pencil")
                    }
                    .tint(.blue)
                    Button(role: .destructive) {
                        pendingDelete = config
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        }
        .overlay {
            if store.configurationsForSelectedCore.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "doc.badge.plus")
                        .font(.system(size: 26))
                        .foregroundStyle(.secondary)
                    Text(String(localized: "No configurations"))
                        .font(.headline)
                    Text(String(localized: "Create one, import a file, or add a subscription."))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button(String(localized: "Subscribe")) { showSubscribe = true }
                        .buttonStyle(.borderedProminent)
                        .padding(.top, 4)
                }
                .padding(20)
            }
        }

        .refreshable {
            await refreshSubscriptions()
        }
        .navigationTitle("\(store.selectedCore.displayName) configurations")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if isDownloading {
                    ProgressView()
                } else {
                    Menu {
                        Button {
                            promptCreate()
                        } label: {
                            Label("New", systemImage: "plus")
                        }
                        Button {
                            fileImporting = true
                        } label: {
                            Label("Import from file", systemImage: "doc")
                        }
                        Button {
                            showSubscribe = true
                        } label: {
                            Label("Subscribe", systemImage: "link")
                        }
                        if store.configurationsForSelectedCore.contains(where: { $0.sourceURL != nil }) {
                            Button {
                                Task { await refreshSubscriptions() }
                            } label: {
                                Label(String(localized: "Refresh subscriptions"), systemImage: "arrow.clockwise")
                            }
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
        }
        .sheet(isPresented: $showSubscribe) {
            SubscribeSheet()
        }
        .fileImporter(
            isPresented: $fileImporting,
            allowedContentTypes: [.json, .yaml, .text, .data, .item],
            allowsMultipleSelection: false
        ) { result in
            handleFileImport(result)
        }
        .alert("Tunnel is running", isPresented: $blockedAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Stop the tunnel before switching the active configuration or deleting the active one.")
        }
        .alert("Import error", isPresented: importErrorBinding, presenting: importErrorMessage) { _ in
            Button("OK", role: .cancel) {}
        } message: { msg in
            Text(msg)
        }
        .confirmationDialog(
            "Delete configuration?",
            isPresented: deleteDialogBinding,
            titleVisibility: .visible,
            presenting: pendingDelete
        ) { config in
            Button("Delete \(config.name)", role: .destructive) {
                delete(config)
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        }
    }

    private func row(for config: Configuration) -> some View {
        HStack(spacing: 12) {
            Image(systemName: activeID == config.id ? "checkmark.circle.fill" : "circle")
                .foregroundColor(activeID == config.id ? .accentColor : .secondary)
                .font(.title3)
                .onTapGesture {
                    activate(config)
                }
            VStack(alignment: .leading) {
                Text(config.name)
                    .lineLimit(1)
                Text(config.sourceURL ?? String(localized: "Local"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button {
                quickConnect(config)
            } label: {
                Image(systemName: "bolt.circle.fill")
                    .font(.title3)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(activeID == config.id && tunnel.status.isActive ? Color.green : Color.accentColor)
            .accessibilityLabel(String(localized: "Connect"))
        }
        .contentShape(Rectangle())
    }

    private var deleteDialogBinding: Binding<Bool> {
        Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        )
    }

    private var importErrorBinding: Binding<Bool> {
        Binding(
            get: { importErrorMessage != nil },
            set: { if !$0 { importErrorMessage = nil } }
        )
    }

    private func activate(_ config: Configuration) {
        if tunnel.status.isActive {
            blockedAlert = true
            return
        }
        store.setActive(config)
    }

    private func delete(_ config: Configuration) {
        defer { pendingDelete = nil }
        if tunnel.status.isActive, activeID == config.id {
            blockedAlert = true
            return
        }
        store.delete(config)
    }

    private func promptCreate() {
        let core = store.selectedCore
        NameInputAlert.present(
            title: String(localized: "New \(core.displayName) configuration"),
            message: String(localized: "Enter a name for the new configuration."),
            placeholder: String(localized: "Name")
        ) { name in
            store.create(name: name, type: core, content: core.defaultConfig)
        }
    }

    private func promptRename(_ config: Configuration) {
        NameInputAlert.present(
            title: String(localized: "Rename configuration"),
            initialValue: config.name
        ) { name in
            store.update(config, name: name)
        }
    }

    private func extractRemarks(from content: String, fallbackUrl: URL) -> String {
        // JSON
        if let data = content.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let remarks = json["remarks"] as? String,
            !remarks.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return remarks.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return derivedName(from: fallbackUrl)
    }

    private func handleFileImport(_ result: Result<[URL], Error>) {
        let core = store.selectedCore
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let content = try String(contentsOf: url, encoding: .utf8)
                store.create(name: extractRemarks(from: content, fallbackUrl: url), type: core, content: content)
            } catch {
                importErrorMessage = "Could not read \(url.lastPathComponent): \(error.localizedDescription)"
            }
        case .failure(let err):
            importErrorMessage = err.localizedDescription
        }
    }

    private func updateSubscription(_ config: Configuration) {
        guard let raw = config.sourceURL, let url = URL(string: raw) else { return }
        isDownloading = true
        Task { @MainActor in
            defer { isDownloading = false }
            do {
                let result = try await SubscriptionImporter.fetch(from: url)
                store.update(config, content: result.content)
            } catch {
                importErrorMessage = error.localizedDescription
            }
        }
    }


    private func quickConnect(_ config: Configuration) {
        Task { @MainActor in
            if tunnel.status.isActive {
                await tunnel.setEnabled(false, configuration: store.active)
            }
            store.setActive(config)
            await tunnel.setEnabled(true, configuration: config)
            if let err = tunnel.lastError { importErrorMessage = err }
        }
    }

    private func refreshSubscriptions() async {
        guard !isRefreshingAll else { return }
        let targets = store.configurationsForSelectedCore.filter { $0.sourceURL != nil }
        guard !targets.isEmpty else { return }

        isRefreshingAll = true
        isDownloading = true
        defer {
            isRefreshingAll = false
            isDownloading = false
        }

        var failCount = 0
        for config in targets {
            do {
                guard let raw = config.sourceURL, let url = URL(string: raw) else { continue }
                let result = try await SubscriptionImporter.fetch(from: url)
                store.update(config, content: result.content)
            } catch {
                failCount += 1
            }
        }

        if failCount > 0 {
            importErrorMessage = String(localized: "Some subscriptions failed to refresh (\(failCount)).")
        }
    }

    private func derivedName(from url: URL) -> String {
        let stripped = url.deletingPathExtension().lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !stripped.isEmpty, stripped != "/" {
            return stripped
        }
        if let host = url.host, !host.isEmpty {
            return host
        }
        return String(localized: "Imported Configuration")
    }
}
