//
//  HappCryptDecryptor.swift
//  DecoderSec
//
//  Decrypts happ://crypt…crypt5 links locally (RSA + ChaCha20-Poly1305 for crypt5).
//  Interoperability with Happ subscription deep links; keys bundled for crypt5 markers.
//

import CryptoKit
import Foundation
import Security

enum HappCryptDecryptor {
    enum DecryptError: LocalizedError {
        case invalidLink
        case missingKeys
        case unknownMarker(String)
        case badPayload(String)
        case rsaFailed
        case chachaFailed

        var errorDescription: String? {
            switch self {
            case .invalidLink:
                return String(localized: "Invalid encrypted Happ link.")
            case .missingKeys:
                return String(localized: "Encrypted-link keys are missing from the app bundle.")
            case .unknownMarker(let m):
                return String(localized: "Unknown crypt5 marker: \(m)")
            case .badPayload(let detail):
                return String(localized: "Could not decrypt Happ link: \(detail)")
            case .rsaFailed:
                return String(localized: "RSA decryption failed.")
            case .chachaFailed:
                return String(localized: "ChaCha20 decryption failed.")
            }
        }
    }

    /// Decrypt any `happ://crypt[2-5]/…` URL to plaintext (usually an https subscription URL).
    static func decrypt(url: URL) throws -> String {
        let scheme = (url.scheme ?? "").lowercased()
        guard scheme == "happ" || scheme == "decodersec" || scheme == "decoder" || scheme == "everywhere" else {
            throw DecryptError.invalidLink
        }
        let host = (url.host ?? "").lowercased()
        guard host.hasPrefix("crypt") else { throw DecryptError.invalidLink }

        // Payload is everything after happ://cryptN/ — keep raw path+query fragments.
        var full = url.absoluteString
        if let range = full.range(of: "://\(host)/", options: .caseInsensitive) {
            full = String(full[range.upperBound...])
        } else if let range = full.range(of: "://\(host)", options: .caseInsensitive) {
            full = String(full[range.upperBound...])
            if full.hasPrefix("/") { full.removeFirst() }
        }
        let payload = full.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !payload.isEmpty else { throw DecryptError.invalidLink }

        switch host {
        case "crypt", "crypt1":
            return try decryptLegacyRSA(payload: payload, keyIndex: 0)
        case "crypt2":
            return try decryptLegacyRSA(payload: payload, keyIndex: 1)
        case "crypt3":
            return try decryptLegacyRSA(payload: payload, keyIndex: 2)
        case "crypt4":
            return try decryptLegacyRSA(payload: payload, keyIndex: 3)
        case "crypt5":
            return try decryptCrypt5(payload: payload)
        default:
            throw DecryptError.badPayload(host)
        }
    }

    // MARK: - crypt5

    private static func decryptCrypt5(payload: String) throws -> String {
        let keytable = try loadCrypt5Keys()
        let shuffled = swapBlockHalves(Array(payload.utf8))
        guard shuffled.count >= 8 else { throw DecryptError.badPayload("too short") }

        var markerBytes = [UInt8]()
        markerBytes.append(contentsOf: shuffled.prefix(4))
        markerBytes.append(contentsOf: shuffled.suffix(4))
        let marker = String(bytes: markerBytes, encoding: .utf8) ?? ""
        guard let keyB64 = keytable[marker] else { throw DecryptError.unknownMarker(marker) }

        let body = Array(shuffled.dropFirst(4).dropLast(4))
        let preferSalted = body.count > 12 && !(body[12] >= 48 && body[12] <= 57)

        var firstError: Error?
        for salted in [preferSalted, !preferSalted] {
            do {
                return try decryptCrypt5Body(body, keyBase64: keyB64, salted: salted)
            } catch {
                if firstError == nil { firstError = error }
            }
        }
        throw firstError ?? DecryptError.badPayload("crypt5")
    }

    private static func decryptCrypt5Body(_ body: [UInt8], keyBase64: String, salted: Bool) throws -> String {
        guard body.count >= 13 else { throw DecryptError.badPayload("body short") }

        let nonce = Array(body.prefix(12))
        var salt: [UInt8]?
        var lengthStart = 12
        if salted {
            guard body.count >= 22 else { throw DecryptError.badPayload("salted header") }
            salt = Array(body[14..<22])
            lengthStart = 22
        }

        var lengthEnd = lengthStart
        while lengthEnd < body.count && body[lengthEnd] >= 48 && body[lengthEnd] <= 57 {
            lengthEnd += 1
        }
        guard lengthEnd > lengthStart else { throw DecryptError.badPayload("missing length") }

        let lengthStr = String(bytes: body[lengthStart..<lengthEnd], encoding: .utf8) ?? ""
        guard let segmentLength = Int(lengthStr) else { throw DecryptError.badPayload("bad length") }

        let packed = Array(body[lengthEnd...])
        guard segmentLength > 0, packed.count > segmentLength else {
            throw DecryptError.badPayload("truncated segment")
        }

        let encryptedURL = String(bytes: packed[1..<(segmentLength + 1)], encoding: .utf8) ?? ""
        let rsaCipherB64 = String(bytes: packed[(segmentLength + 1)...], encoding: .utf8) ?? ""
        let rsaCipher = try decodeBase64(rsaCipherB64)

        let privateKey = try makePrivateKey(pkcs8Base64: keyBase64)
        let rsaPlainLatin = try rsaDecryptPKCS1(privateKey: privateKey, cipher: rsaCipher)
        let rsaPlainBytes = Array(rsaPlainLatin.utf8)
        let rsaValue = try decodeBase64(String(bytes: swapAdjacent(rsaPlainBytes), encoding: .utf8) ?? "")
        guard rsaValue.count == 32 else { throw DecryptError.badPayload("key len \(rsaValue.count)") }

        var chachaKey = rsaValue
        if let salt {
            for i in 0..<chachaKey.count {
                chachaKey[i] ^= salt[i % salt.count]
            }
        }

        let ciphertext = try decodeBase64(encryptedURL)
        guard ciphertext.count > 16 else { throw DecryptError.chachaFailed }
        let tag = Array(ciphertext.suffix(16))
        let ct = Array(ciphertext.dropLast(16))

        let key = SymmetricKey(data: Data(chachaKey))
        let nonceObj = try ChaChaPoly.Nonce(data: Data(nonce))
        let box = try ChaChaPoly.SealedBox(nonce: nonceObj, ciphertext: Data(ct), tag: Data(tag))
        let intermediate: Data
        do {
            intermediate = try ChaChaPoly.open(box, using: key)
        } catch {
            throw DecryptError.chachaFailed
        }

        let swapped = swapAdjacent(Array(intermediate))
        let innerB64 = String(bytes: swapped, encoding: .utf8) ?? ""
        let plaintext = try decodeBase64(innerB64)
        guard let out = String(bytes: plaintext, encoding: .utf8) else {
            throw DecryptError.badPayload("utf8")
        }
        return out
    }

    // MARK: - crypt / crypt2 / crypt3 / crypt4 (legacy RSA)

    private static func decryptLegacyRSA(payload: String, keyIndex: Int) throws -> String {
        let keys = try loadLegacyKeys()
        guard keyIndex >= 0, keyIndex < keys.count else { throw DecryptError.badPayload("key index") }
        let privateKey = try makePrivateKey(pkcs1Base64: keys[keyIndex])
        let cipher = try decodeBase64(payload)

        // Key size in bytes from SecKey.
        let keySize = SecKeyGetBlockSize(privateKey)
        guard keySize > 0 else { throw DecryptError.rsaFailed }

        var plaintext = Data()
        var offset = 0
        while offset < cipher.count {
            let end = min(offset + keySize, cipher.count)
            let chunk = Array(cipher[offset..<end])
            let latin = try rsaDecryptPKCS1(privateKey: privateKey, cipher: chunk)
            plaintext.append(contentsOf: latin.utf8)
            offset = end
        }
        guard let out = String(data: plaintext, encoding: .utf8)
                ?? String(data: plaintext, encoding: .isoLatin1) else {
            throw DecryptError.badPayload("utf8")
        }
        return out
    }

    // MARK: - Keys & crypto helpers

    private static func loadCrypt5Keys() throws -> [String: String] {
        guard let url = Bundle.main.url(forResource: "crypt5-keys", withExtension: "json")
                ?? Bundle.main.url(forResource: "crypt5-keys", withExtension: "json", subdirectory: "DeepLink")
        else { throw DecryptError.missingKeys }
        let data = try Data(contentsOf: url)
        guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: String] else {
            throw DecryptError.missingKeys
        }
        return dict
    }

    private static func loadLegacyKeys() throws -> [String] {
        guard let url = Bundle.main.url(forResource: "crypt-legacy-keys", withExtension: "json")
                ?? Bundle.main.url(forResource: "crypt-legacy-keys", withExtension: "json", subdirectory: "DeepLink")
        else { throw DecryptError.missingKeys }
        let data = try Data(contentsOf: url)
        guard let arr = try JSONSerialization.jsonObject(with: data) as? [String] else {
            throw DecryptError.missingKeys
        }
        return arr
    }

    private static func makePrivateKey(pkcs8Base64: String) throws -> SecKey {
        let clean = pkcs8Base64.replacingOccurrences(of: "\\s", with: "", options: .regularExpression)
        guard let der = Data(base64Encoded: clean) else { throw DecryptError.rsaFailed }
        // Prefer PKCS#8; fall back to extracting PKCS#1 OCTET STRING.
        if let key = secKey(fromDER: der, isPKCS8: true) { return key }
        if let pkcs1 = extractPKCS1(fromPKCS8: der), let key = secKey(fromDER: pkcs1, isPKCS8: false) {
            return key
        }
        throw DecryptError.rsaFailed
    }

    private static func makePrivateKey(pkcs1Base64: String) throws -> SecKey {
        let clean = pkcs1Base64.replacingOccurrences(of: "\\s", with: "", options: .regularExpression)
        guard let der = Data(base64Encoded: clean),
              let key = secKey(fromDER: der, isPKCS8: false) else {
            throw DecryptError.rsaFailed
        }
        return key
    }

    private static func secKey(fromDER der: Data, isPKCS8: Bool) -> SecKey? {
        var error: Unmanaged<CFError>?
        let attrs: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
        ]
        if let key = SecKeyCreateWithData(der as CFData, attrs as CFDictionary, &error) {
            return key
        }
        // Some OS versions want explicit PKCS#1 only.
        if isPKCS8, let pkcs1 = extractPKCS1(fromPKCS8: der) {
            return SecKeyCreateWithData(pkcs1 as CFData, attrs as CFDictionary, &error)
        }
        return nil
    }

    /// Pull RSAPrivateKey OCTET STRING out of a PKCS#8 PrivateKeyInfo blob.
    private static func extractPKCS1(fromPKCS8 data: Data) -> Data? {
        // Naive walk: find the second OCTET STRING (tag 0x04) with substantial length.
        let bytes = [UInt8](data)
        var i = 0
        var found = 0
        while i + 2 < bytes.count {
            if bytes[i] == 0x04 {
                var len = 0
                var lenBytes = 0
                if bytes[i + 1] & 0x80 == 0 {
                    len = Int(bytes[i + 1])
                    lenBytes = 1
                } else {
                    let n = Int(bytes[i + 1] & 0x7f)
                    guard i + 1 + n < bytes.count else { break }
                    for j in 0..<n {
                        len = (len << 8) | Int(bytes[i + 2 + j])
                    }
                    lenBytes = 1 + n
                }
                let start = i + 1 + lenBytes
                let end = start + len
                if end <= bytes.count, len > 64 {
                    found += 1
                    // First big OCTET STRING in PrivateKeyInfo is the privateKey field.
                    if found >= 1 {
                        return Data(bytes[start..<end])
                    }
                }
                i = start
            } else {
                i += 1
            }
        }
        return nil
    }

    private static func rsaDecryptPKCS1(privateKey: SecKey, cipher: [UInt8]) throws -> String {
        var error: Unmanaged<CFError>?
        guard let plain = SecKeyCreateDecryptedData(
            privateKey,
            .rsaEncryptionPKCS1,
            Data(cipher) as CFData,
            &error
        ) as Data? else {
            throw DecryptError.rsaFailed
        }
        // node-forge returns a Latin-1 byte string; keep raw bytes as Latin-1.
        return String(bytes: plain, encoding: .isoLatin1) ?? String(decoding: plain, as: UTF8.self)
    }

    private static func decodeBase64(_ value: String) throws -> [UInt8] {
        var clean = value
            .replacingOccurrences(of: "\\s", with: "", options: .regularExpression)
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while clean.hasSuffix("=") { clean.removeLast() }
        while clean.count % 4 != 0 { clean.append("=") }
        guard let data = Data(base64Encoded: clean, options: [.ignoreUnknownCharacters]) else {
            throw DecryptError.badPayload("base64")
        }
        return [UInt8](data)
    }

    private static func swapAdjacent(_ bytes: [UInt8]) -> [UInt8] {
        var result = bytes
        var i = 0
        while i + 1 < result.count {
            result.swapAt(i, i + 1)
            i += 2
        }
        return result
    }

    /// ABCD → CDAB per 4-byte block (self-inverse).
    private static func swapBlockHalves(_ bytes: [UInt8]) -> [UInt8] {
        var result = bytes
        let full = result.count - (result.count % 4)
        var i = 0
        while i < full {
            result.swapAt(i, i + 2)
            result.swapAt(i + 1, i + 3)
            i += 4
        }
        return result
    }
}
