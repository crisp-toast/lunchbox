import AppKit
import LunchboxCore

/// LunchboxWM's license: what's stored on this Mac, and whether tiling may run. LunchboxWM is
/// paid up front, with no free trial, so without a license nothing tiles.
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
    private static let checkedKey = "revocationChecked"

    private(set) var license: License?
    var onChange: (() -> Void)?
    /// A license turned out to be refunded or charged back, and was switched off.
    var onRevoked: ((License) -> Void)?
    private let defaults = UserDefaults.standard

    init() {
        license = defaults.string(forKey: Self.licenseKey).flatMap { License.parse($0, publicKeyBase64: Self.publicKey) }
    }

    /// Licensed: the only way to tile.
    var canTile: Bool { license != nil }

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
