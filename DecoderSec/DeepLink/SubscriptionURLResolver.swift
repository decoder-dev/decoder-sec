//
//  SubscriptionURLResolver.swift
//  DecoderSec
//
//  happwn-style decrypt-then-fetch: resolve happ://crypt* stored in sourceURL
//  before SubscriptionImporter.fetch (import + refresh).
//

import Foundation

enum SubscriptionURLResolver {
    enum ResolveError: LocalizedError {
        case empty
        case invalidURL(String)
        case invalidDecryptedURL

        var errorDescription: String? {
            switch self {
            case .empty:
                return String(localized: "Subscription URL is empty.")
            case .invalidURL(let raw):
                return String(localized: "Invalid subscription URL: \(raw)")
            case .invalidDecryptedURL:
                return String(localized: "Decrypted Happ link is not a valid http(s) URL.")
            }
        }
    }

    static func resolve(_ raw: String) throws -> URL {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ResolveError.empty }

        let lower = trimmed.lowercased()
        if lower.hasPrefix("happ://") || lower.hasPrefix("decodersec://")
            || lower.hasPrefix("decoder://") || lower.hasPrefix("everywhere://") {
            guard let cryptURL = URL(string: trimmed) else {
                throw ResolveError.invalidURL(trimmed)
            }
            let decrypted = try HappCryptDecryptor.decrypt(url: cryptURL)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let url = URL(string: decrypted),
                  let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https" else {
                throw ResolveError.invalidDecryptedURL
            }
            return url
        }

        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            throw ResolveError.invalidURL(trimmed)
        }
        return url
    }
}
