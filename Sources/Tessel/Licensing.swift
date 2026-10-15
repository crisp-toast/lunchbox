import AppKit
import Security
import TesselCore

/// Tessel's license and free trial: what's stored on this Mac, and whether tiling may run.
final class Licensing {
    /// The store's Ed25519 public key. Its private half signs licenses on the server
    /// (LICENSE_PRIVATE_KEY) and is kept off this repo.
    static let publicKey = "qLQZTRdDyv019zqGNELstTUJa3rmQXnLNk5eoYgM1nU="
    /// The store. Buy and Lost License links go here.
    static let site = "https://tessel.sentientdonut.com"
    static let buyURL = URL(string: site + "/#pricing")!
    static let recoverURL = URL(string: site + "/recover.html")!

    private static let licenseKey = "license"
    private static let trialKey = "trialStarted"

    private(set) var license: License?
    var onChange: (() -> Void)?
    private let defaults = UserDefaults.standard

    init() {
        license = defaults.string(forKey: Self.licenseKey).flatMap { License.parse($0, publicKeyBase64: Self.publicKey) }
        if trialStart == nil { startTrial() }
    }

    /// When the trial began: the earlier of what's in Tessel's settings and the Keychain,
    /// so clearing the settings doesn't hand out a fresh trial.
    var trialStart: Date? {
        let stored = [defaults.object(forKey: Self.trialKey) as? Date,
                      Keychain.read(Self.trialKey).flatMap(Double.init).map(Date.init(timeIntervalSince1970:))]
        return stored.compactMap { $0 }.min()
    }

    private func startTrial() {
        let now = Date()
        defaults.set(now, forKey: Self.trialKey)
        Keychain.write(String(now.timeIntervalSince1970), Self.trialKey)
    }

    var trial: Trial { Trial.state(firstLaunch: trialStart ?? Date(), now: Date()) }

    /// Licensed, or still in the trial.
    var canTile: Bool { license != nil || trial != .ended }

    /// Checks and keeps a pasted key or activation link. Returns nil for one the store didn't sign.
    @discardableResult
    func activate(_ text: String) -> License? {
        guard let parsed = License.parse(text, publicKeyBase64: Self.publicKey) else { return nil }
        license = parsed
        defaults.set(parsed.key, forKey: Self.licenseKey)
        log.notice("licensed to \(parsed.email, privacy: .private) (order \(parsed.order, privacy: .public))")
        onChange?()
        return parsed
    }

    func removeLicense() {
        license = nil
        defaults.removeObject(forKey: Self.licenseKey)
        onChange?()
    }
}

/// A tiny wrapper over generic-password items in the login Keychain.
enum Keychain {
    private static let service = "com.tyleryouens.tessel"

    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    static func read(_ account: String) -> String? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ value: String, _ account: String) {
        SecItemDelete(query(account) as CFDictionary)
        var q = query(account)
        q[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(q as CFDictionary, nil)
    }
}
