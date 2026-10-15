import Foundation
import Testing
@testable import TesselCore

/// Keys signed by the store's JavaScript (store/lib/license.js) with a test-only key
/// pair (store/test/fixture.json), so the two sides can't drift apart.
@Suite struct LicenseKeys {
    let publicKey = "in2Zr+hRDI2Ij51LDXdO0gH7joQ8FzSkypconmxWCSc="
    let key = "tessel1.eyJwIjoidGVzc2VsIiwiZSI6ImJ1eWVyQGV4YW1wbGUuY29tIiwibyI6ImNzX3Rlc3RfYTFCMmMzIiwidCI6MTc5MjAwMDAwMH0.0qYx5WIOFT-ut7Oyb5MjBzK7PPlrNxafyApS0agOnLGYogKJdu0PyF8Hxrn7ELD20T_Q2w6529qJGxU8oTE7AQ"

    @Test func storeSignedKeyIsAccepted() throws {
        let license = try #require(License.parse(key, publicKeyBase64: publicKey))
        #expect(license.email == "buyer@example.com")
        #expect(license.order == "cs_test_a1B2c3")
        #expect(license.issued == Date(timeIntervalSince1970: 1_792_000_000))
    }

    @Test func pastedTheWayMailAppsMangleIt() {
        let wrapped = "  \"" + key.prefix(60) + "\n" + key.dropFirst(60).prefix(70) + "\r\n " + key.dropFirst(130) + "\" "
        #expect(License.parse(wrapped, publicKeyBase64: publicKey)?.key == key)
        let link = "tessel://activate?key=" + key
        #expect(License.parse(link, publicKeyBase64: publicKey)?.order == "cs_test_a1B2c3")
    }

    @Test func anyChangeIsRejected() {
        var tampered = Array(key)
        let i = key.distance(from: key.startIndex, to: key.firstIndex(of: ".")!) + 5
        tampered[i] = tampered[i] == "A" ? "B" : "A"
        #expect(License.parse(String(tampered), publicKeyBase64: publicKey) == nil)
        #expect(License.parse(key.replacingOccurrences(of: "tessel1.", with: "tessel2."), publicKeyBase64: publicKey) == nil)
        #expect(License.parse("", publicKeyBase64: publicKey) == nil)
        #expect(License.parse("not a key", publicKeyBase64: publicKey) == nil)
    }

    @Test func anotherStoresKeyIsRejected() {
        // The real store's public key: a key signed with the test pair must not pass.
        #expect(License.parse(key, publicKeyBase64: "qLQZTRdDyv019zqGNELstTUJa3rmQXnLNk5eoYgM1nU=") == nil)
    }
}

@Suite struct FreeTrial {
    let start = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func countsDownFromFirstLaunch() {
        #expect(Trial.state(firstLaunch: start, now: start) == .active(daysLeft: 14))
        #expect(Trial.state(firstLaunch: start, now: start + 86_400 * 13.5) == .active(daysLeft: 1))
        #expect(Trial.state(firstLaunch: start, now: start + 86_400 * 14) == .ended)
    }

    @Test func settingTheClockBackDoesNotAddDays() {
        #expect(Trial.state(firstLaunch: start, now: start - 86_400 * 30) == .active(daysLeft: 14))
    }
}
