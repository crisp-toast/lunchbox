import CryptoKit
import Foundation

/// A Tessel license: who bought it and which order, signed by the store. Checked
/// entirely offline against the store's public key, so a purchase works without an
/// account, a server round trip, or a network connection.
///
/// A key reads `tessel1.<payload>.<signature>`: the payload is compact JSON
/// (`p` product, `e` email, `o` order, `t` issue time in Unix seconds) and the
/// signature is Ed25519 over the payload's bytes, both base64url without padding.
public struct License: Equatable, Sendable {
    public static let prefix = "tessel1"
    public static let product = "tessel"

    public let email: String
    public let order: String
    public let issued: Date
    /// The key as the store issued it, tidied of any spaces or line breaks.
    public let key: String

    private struct Payload: Decodable {
        let p: String
        let e: String
        let o: String
        let t: Double
    }

    /// Reads a key the way people paste it: from an email (wrapped across lines),
    /// with stray spaces or quotes, or as a whole `tessel://activate?key=…` link.
    /// Returns nil unless the store signed it, for this product.
    public static func parse(_ text: String, publicKey: Curve25519.Signing.PublicKey) -> License? {
        let key = extractKey(from: text)
        let parts = key.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, parts[0] == prefix,
              let payload = Data(base64URL: parts[1]), let signature = Data(base64URL: parts[2]),
              publicKey.isValidSignature(signature, for: payload),
              let fields = try? JSONDecoder().decode(Payload.self, from: payload),
              fields.p == product, !fields.e.isEmpty, !fields.o.isEmpty else { return nil }
        return License(email: fields.e, order: fields.o, issued: Date(timeIntervalSince1970: fields.t), key: key)
    }

    public static func parse(_ text: String, publicKeyBase64 base64: String) -> License? {
        guard let raw = Data(base64Encoded: base64),
              let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: raw) else { return nil }
        return parse(text, publicKey: publicKey)
    }

    static func extractKey(from text: String) -> String {
        var s = text
        if let components = URLComponents(string: s.trimmingCharacters(in: .whitespacesAndNewlines)),
           let value = components.queryItems?.first(where: { $0.name == "key" })?.value {
            s = value
        }
        // Keys never contain whitespace, quotes or angle brackets; mail apps add them.
        return s.filter { !$0.isWhitespace && !"\"'<>“”‘’".contains($0) }
    }
}

/// The free trial: every feature for 7 days from the first time Tessel is opened.
public enum Trial: Equatable, Sendable {
    case active(daysLeft: Int)
    case ended

    public static let days = 7

    /// Where the trial stands. Setting the clock back before the first launch doesn't
    /// stretch it past its full length.
    public static func state(firstLaunch: Date, now: Date, days: Int = Trial.days) -> Trial {
        let left = Double(days) - max(0, now.timeIntervalSince(firstLaunch)) / 86_400
        return left > 0 ? .active(daysLeft: Int(left.rounded(.up))) : .ended
    }
}

extension Data {
    /// base64url, with or without padding.
    init?(base64URL text: String) {
        var s = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s += "=" }
        self.init(base64Encoded: s)
    }
}
