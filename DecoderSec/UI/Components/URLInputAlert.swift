//
//  URLInputAlert.swift
//  DecoderSec
//
//  Created by NodePassProject on 5/2/26.
//

import UIKit

enum URLInputAlert {
    static func present(
        title: String,
        message: String? = nil,
        placeholder: String = "https://… or happ://crypt5/…",
        onSubmit: @escaping (URL) -> Void
    ) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)

        alert.addTextField { tf in
            tf.placeholder = placeholder
            tf.keyboardType = .URL
            tf.textContentType = .URL
            tf.autocapitalizationType = .none
            tf.autocorrectionType = .no
            tf.clearButtonMode = .whileEditing
        }

        alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))

        let submit = UIAlertAction(title: String(localized: "Subscribe"), style: .default) { _ in
            let raw = alert.textFields?.first?.text ?? ""
            guard let url = parsed(raw) else { return }
            onSubmit(url)
        }
        submit.isEnabled = false
        alert.addAction(submit)
        alert.preferredAction = submit

        alert.textFields?.first?.addAction(UIAction { _ in
            let text = alert.textFields?.first?.text ?? ""
            submit.isEnabled = parsed(text) != nil
        }, for: .editingChanged)

        topViewController()?.present(alert, animated: true)
    }

    /// Accepts https subscriptions, Happ deep links (`happ://crypt5/…`), and share links.
    private static func parsed(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Prefer Foundation parsing; fall back to percent-encoding odd characters in the path.
        let url = URL(string: trimmed) ?? URL(string: trimmed.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) ?? "")
        guard let url, let scheme = url.scheme?.lowercased() else { return nil }

        if scheme == "http" || scheme == "https" {
            guard let host = url.host, !host.isEmpty else { return nil }
            return url
        }

        if HappDeepLink.aliasSchemes.contains(scheme) {
            // happ://crypt5/… — host is "crypt5"; happ://add/https://… also OK
            return url
        }

        if HappDeepLink.shareSchemes.contains(scheme) {
            return url
        }

        return nil
    }

    private static func topViewController() -> UIViewController? {
        guard let scene = UIApplication.shared.connectedScenes
            .first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene
            ?? UIApplication.shared.connectedScenes.first as? UIWindowScene else {
            return nil
        }
        guard let root = scene.windows.first(where: \.isKeyWindow)?.rootViewController
            ?? scene.windows.first?.rootViewController else {
            return nil
        }
        var top = root
        while let presented = top.presentedViewController {
            top = presented
        }
        return top
    }
}
