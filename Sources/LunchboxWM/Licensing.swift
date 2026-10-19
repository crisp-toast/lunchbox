import AppKit
import Security
import LunchboxCore

/// LunchboxWM's license and free trial: what's stored on this Mac, and whether tiling may run.
final class Licensing {
    /// The store's Ed25519 public key. Its private half signs licenses on the server
    /// (LICENSE_PRIVATE_KEY) and is kept off this repo.
    static let publicKey = "qLQZTRdDyv019zqGNELstTUJa3rmQXnLNk5eoYgM1nU="
    /// The store. Buy and Lost License links go here.
    static let site = "https://lunchboxwm.com"
    static let buyURL = URL(string: site + "/#pricing")!
    static let recoverURL = URL(string: site + "/recover.html")!
    static let revokedURL = URL(string: site + "/api/revoked")!

    private static let licenseKey = "license"
    private static let trialKey = "trialStarted"
    private static let checkedKey = "revocationChecked"

    private(set) var license: License?
    var onChange: (() -> Void)?
    /// A license turned out to be refunded or charged back, and was switched off.
    var onRevoked: ((License) -> Void)?
    private let defaults = UserDefaults.standard

    init() {
        license = defaults.string(forKey: Self.licenseKey).flatMap { License.parse($0, publicKeyBase64: Self.publicKey) }
        if trialStart == nil {
            startTrial()
        } else if Keychain.read(Self.trialKey) == nil, let start = trialStart {
            // The settings know when the trial began but the Keychain doesn't (they came from the
            // app's old ID): keep a copy there too.
            Keychain.write(String(start.timeIntervalSince1970), Self.trialKey)
        }
    }

    /// When the trial began: the earlier of what's in LunchboxWM's settings and the Keychain,
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

    private struct RevokedList: Decodable { let revoked: [String] }

    /// Licensed copies look about once a week for their order on the store's list of refunded
    /// and charged-back licenses. The request carries nothing about this Mac or the license;
    /// offline, or if the site can't be reached, nothing changes.
    func checkRevocationIfDue(now: Date = Date()) {
        guard let license else { return }
        if let last = defaults.object(forKey: Self.checkedKey) as? Date, now.timeIntervalSince(last) < 6.5 * 86_400 { return }
        let request = URLRequest(url: Self.revokedURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        URLSession(configuration: .ephemeral).dataTask(with: request) { [weak self] data, response, _ in
            guard let data, (response as? HTTPURLResponse)?.statusCode == 200,
                  let list = try? JSONDecoder().decode(RevokedList.self, from: data) else { return }
            DispatchQueue.main.async {
                guard let self else { return }
                self.defaults.set(now, forKey: Self.checkedKey)
                guard self.license?.order == license.order, list.revoked.contains(license.revocationHash) else { return }
                log.notice("license for order \(license.order, privacy: .public) was refunded or disputed; switching it off")
                self.removeLicense()
                self.onRevoked?(license)
            }
        }.resume()
    }

    func removeLicense() {
        license = nil
        defaults.removeObject(forKey: Self.licenseKey)
        onChange?()
    }
}

/// A tiny wrapper over generic-password items in the login Keychain.
enum Keychain {
    private static let service = "com.sentientdonut.lunchbox"

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
