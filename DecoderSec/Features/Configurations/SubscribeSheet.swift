//
//  SubscribeSheet.swift
//  DecoderSec
//
//  Modern subscribe UI: https URLs, happ://crypt…, and share links.
//

import SwiftUI

struct SubscribeSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var deepLinks: DeepLinkCenter
    @State private var raw = ""
    @State private var localError: String?
    @FocusState private var focused: Bool

    var body: some View {
        NavigationView {
            VStack(alignment: .leading, spacing: 20) {
                Text(String(localized: "Paste a subscription URL, happ://crypt… link, or vless:// node."))
                    .font(Brand.Font.body(15))
                    .foregroundStyle(Brand.Color.secondaryText)

                TextField(String(localized: "https://… or happ://crypt5/…"), text: $raw)
                    .font(Brand.Font.mono(13))
                    .foregroundStyle(Brand.Color.primaryText)
                    .padding(14)
                    .brandPanel(cornerRadius: 12)
                    .focused($focused)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)

                if let localError {
                    Text(localError)
                        .font(Brand.Font.callout(13))
                        .foregroundStyle(Brand.Color.danger)
                }

                Spacer(minLength: 0)
            }
            .padding(20)
            .background(Brand.Color.void.ignoresSafeArea())
            .navigationTitle(String(localized: "Subscribe"))
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarItems(
                leading: Button(String(localized: "Cancel")) { dismiss() },
                trailing: Button(String(localized: "Import")) {
                    Task { await submit() }
                }
                .disabled(raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || deepLinks.isBusy)
            )
            .overlay {
                if deepLinks.isBusy {
                    ProgressView()
                        .tint(Brand.Color.neon)
                        .padding(20)
                        .background(Brand.Color.surface.opacity(0.95), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
            }
            .onAppear { focused = true }
        }
        .brandTheme()
        .navigationViewStyle(.stack)
    }

    @MainActor
    private func submit() async {
        localError = nil
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = Self.parse(trimmed) else {
            localError = String(localized: "Unrecognized link. Use https://, happ://crypt…, or a share link.")
            return
        }
        let scheme = (url.scheme ?? "").lowercased()
        if scheme == "http" || scheme == "https" {
            await deepLinks.perform(.addSubscription(url))
        } else {
            await deepLinks.handleAsync(url)
        }
        if let err = deepLinks.lastError {
            localError = err
            return
        }
        dismiss()
    }

    static func parse(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let url = URL(string: trimmed)
            ?? URL(string: trimmed.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) ?? "")
        guard let url, let scheme = url.scheme?.lowercased() else { return nil }
        if scheme == "http" || scheme == "https" {
            guard let host = url.host, !host.isEmpty else { return nil }
            return url
        }
        if HappDeepLink.aliasSchemes.contains(scheme) { return url }
        if HappDeepLink.shareSchemes.contains(scheme) { return url }
        return nil
    }
}
