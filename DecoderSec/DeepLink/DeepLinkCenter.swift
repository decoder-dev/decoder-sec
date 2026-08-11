//
//  DeepLinkCenter.swift
//  DecoderSec
//
//  Owns Happ-compatible deep-link handling for the UI process.
//

import Combine
import Foundation
import SwiftUI

@MainActor
final class DeepLinkCenter: ObservableObject {
    static let shared = DeepLinkCenter()

    @Published var banner: String?
    @Published var lastError: String?
    @Published var isBusy = false

    private let store = ConfigurationStore.shared
    private let tunnel = TunnelManager.shared
    private let routing = RoutingProfileStore.shared

    func handle(url: URL) {
        Task { await handleAsync(url) }
    }

    func handleAsync(_ url: URL) async {
        guard let action = HappDeepLink.parse(url) else {
            presentError(String(localized: "Unsupported deep link."))
            return
        }
        await perform(action)
    }

    func perform(_ action: HappDeepLinkAction) async {
        isBusy = true
        defer { isBusy = false }
        do {
            switch action {
            case .addSubscription(let url):
                try await importSubscription(url)

            case .importShareLink(let raw):
                try importShare(raw)

            case .routingImport(let payload, let activate):
                try await importRouting(payload, activate: activate)

            case .routingOff:
                routing.disable()
                present(String(localized: "Routing disabled."))

            case .connect:
                store.selectedCore = .xray
                await tunnel.setEnabled(true, configuration: effectiveActiveConfiguration())

            case .disconnect:
                await tunnel.setEnabled(false, configuration: store.active)

            case .toggle:
                if tunnel.status.isActive {
                    await tunnel.setEnabled(false, configuration: store.active)
                } else {
                    store.selectedCore = .xray
                    await tunnel.setEnabled(true, configuration: effectiveActiveConfiguration())
                }

            case .status:
                present(tunnel.status.isActive
                        ? String(localized: "VPN is connected.")
                        : String(localized: "VPN is disconnected."))

            case .encrypted(_, let payloadURL):
                let plain = try HappCryptDecryptor.decrypt(url: payloadURL)
                let trimmed = plain.trimmingCharacters(in: .whitespacesAndNewlines)
                if let sub = URL(string: trimmed),
                   ["http", "https"].contains((sub.scheme ?? "").lowercased()) {
                    try await importSubscription(sub)
                } else if HappDeepLink.shareSchemes.contains(where: { trimmed.lowercased().hasPrefix($0 + "://") })
                            || trimmed.contains("://") {
                    try importShare(trimmed)
                } else if let asURL = URL(string: trimmed), asURL.scheme != nil {
                    try await importSubscription(asURL)
                } else {
                    // Multi-line subscription body
                    try importShare(trimmed)
                }
            }
        } catch {
            presentError(error.localizedDescription)
        }
    }

    // MARK: - Import helpers

    private func importSubscription(_ url: URL) async throws {
        let result = try await SubscriptionImporter.fetch(from: url)
        let core: CoreType = result.content.contains("proxies:") ? .mihomo : .xray
        store.selectedCore = core
        var content = result.content
        if core == .xray, routing.routingEnabled, let profile = routing.activeProfile {
            content = try HappRoutingApplier.apply(profile: profile, toXrayJSON: content)
        }
        guard let cfg = store.create(
            name: result.name,
            type: core,
            content: content,
            sourceURL: result.sourceURL
        ) else {
            throw NSError(domain: "DeepLinkCenter", code: -10, userInfo: [
                NSLocalizedDescriptionKey: store.storeError
                    ?? String(localized: "Local storage is unavailable — can't save the imported subscription.")
            ])
        }
        store.setActive(cfg)

        var extraCount = 0
        for extra in result.additionalConfigs {
            var extraContent = extra.content
            if core == .xray, routing.routingEnabled, let profile = routing.activeProfile {
                extraContent = (try? HappRoutingApplier.apply(profile: profile, toXrayJSON: extraContent)) ?? extraContent
            }
            if store.create(
                name: extra.name,
                type: core,
                content: extraContent,
                sourceURL: result.sourceURL
            ) != nil {
                extraCount += 1
            }
        }

        if let embedded = result.embeddedRoutingDeepLink,
           let rURL = URL(string: embedded),
           let action = HappDeepLink.parse(rURL) {
            await perform(action)
        }
        if extraCount > 0 {
            present(String(localized: "Subscription “\(cfg.name)” imported (+\(extraCount) more)."))
        } else {
            present(String(localized: "Subscription “\(cfg.name)” imported."))
        }
    }

    private func importShare(_ raw: String) throws {
        // Multi-line paste support.
        let links = raw
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let built = try ShareLinkToXray.xrayConfig(fromShareLinks: links.isEmpty ? [raw] : links)
        var content = built.json
        if routing.routingEnabled, let profile = routing.activeProfile {
            content = try HappRoutingApplier.apply(profile: profile, toXrayJSON: content)
        }
        store.selectedCore = .xray
        guard let cfg = store.create(name: built.name, type: .xray, content: content) else {
            throw NSError(domain: "DeepLinkCenter", code: -10, userInfo: [
                NSLocalizedDescriptionKey: store.storeError
                    ?? String(localized: "Local storage is unavailable — can't save the imported subscription.")
            ])
        }
        store.setActive(cfg)
        present(String(localized: "Node “\(cfg.name)” imported."))
    }

    private func importRouting(_ payload: RoutingPayload, activate: Bool) async throws {
        switch payload {
        case .base64JSON(let data):
            let profile = try routing.upsert(fromJSONData: data, activate: activate)
            if activate { try applyRoutingToActiveXray(profile) }
            present(activate
                    ? String(localized: "Routing “\(profile.name)” activated.")
                    : String(localized: "Routing “\(profile.name)” added."))
        case .remoteURL(let url):
            let (data, response) = try await URLSession.shared.data(from: url)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                throw NSError(domain: "DeepLinkCenter", code: http.statusCode,
                              userInfo: [NSLocalizedDescriptionKey: String(localized: "Routing URL HTTP \(http.statusCode).")])
            }
            // Body may be raw JSON or a happ://routing/... deeplink line.
            if let text = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               text.lowercased().hasPrefix("happ://"),
               let deeplink = URL(string: text),
               let action = HappDeepLink.parse(deeplink) {
                await perform(action)
                return
            }
            let profile = try routing.upsert(fromJSONData: data, activate: activate, sourceURL: url.absoluteString)
            if activate { try applyRoutingToActiveXray(profile) }
            present(String(localized: "Routing “\(profile.name)” loaded from URL."))
        }
    }

    private func applyRoutingToActiveXray(_ profile: HappRoutingProfile) throws {
        guard let active = store.configurations.first(where: { $0.id == store.activeIDByCoreType[.xray] })
                ?? store.configurations.first(where: { $0.coreType == .xray }) else { return }
        let updated = try HappRoutingApplier.apply(profile: profile, toXrayJSON: active.content)
        store.update(active, content: updated)
        store.selectedCore = .xray
        store.setActive(active)
    }

    private func effectiveActiveConfiguration() -> Configuration? {
        guard let active = store.active else { return store.configurationsForSelectedCore.first }
        guard active.coreType == .xray,
              routing.routingEnabled,
              let profile = routing.activeProfile else { return active }
        // Apply routing ephemerally into stored content before connect.
        if let updated = try? HappRoutingApplier.apply(profile: profile, toXrayJSON: active.content) {
            store.update(active, content: updated)
        }
        return active
    }

    private func present(_ message: String) {
        lastError = nil
        banner = message
    }

    private func presentError(_ message: String) {
        banner = nil
        lastError = message
    }
}
