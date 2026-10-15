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
    private static let daysKey = "trialDaysUsed"

    private(set) var license: License?
    var onChange: (() -> Void)?
    private let defaults = UserDefaults.standard

    init() {
        license = defaults.string(forKey: Self.licenseKey).flatMap { License.parse($0, publicKeyBase64: Self.publicKey) }
        daysUsed = Set(defaults.stringArray(forKey: Self.daysKey) ?? [])
            .union((Keychain.read(Self.daysKey) ?? "").split(separator: ",").map(String.init))
    }

    /// The days Tessel has done something for you (tiled a window, ran a shortcut), kept in
    /// both its settings and the Keychain, so clearing the settings doesn't restart the trial.
    private var daysUsed: Set<String>

    /// Tessel just did something for you: count today as a day of use, once.
    func noteUse(at date: Date = Date()) {
        guard license == nil else { return }
        let today = Trial.dayStamp(date)
        guard daysUsed.insert(today).inserted else { return }
        let all = daysUsed.sorted()
        defaults.set(all, forKey: Self.daysKey)
        Keychain.write(all.joined(separator: ","), Self.daysKey)
        onChange?()
    }

    var trial: Trial { Trial.state(daysUsed: daysUsed.count) }

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
