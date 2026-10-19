import Foundation
import Testing
@testable import LunchboxCore

/// Keys signed by the store's JavaScript (store/lib/license.js) with a test-only key
/// pair (store/test/fixture.json), so the two sides can't drift apart.
@Suite struct LicenseKeys {
    let publicKey = "in2Zr+hRDI2Ij51LDXdO0gH7joQ8FzSkypconmxWCSc="
    let key = "lunchbox1.eyJwIjoibHVuY2hib3giLCJlIjoiYnV5ZXJAZXhhbXBsZS5jb20iLCJvIjoiY3NfdGVzdF9hMUIyYzMiLCJ0IjoxNzkyMDAwMDAwfQ.dhZTnav90YEhLUodJHs3DH6sFsrp1rqt-bpaIWKDti_2e4-jDLOiruT2mKE6rpa0iyOpC81FsaJ0ylM0SOQwBQ"

    @Test func storeSignedKeyIsAccepted() throws {
        let license = try #require(License.parse(key, publicKeyBase64: publicKey))
        #expect(license.email == "buyer@example.com")
        #expect(license.order == "cs_test_a1B2c3")
        #expect(license.issued == Date(timeIntervalSince1970: 1_792_000_000))
    }

    @Test func pastedTheWayMailAppsMangleIt() {
        let wrapped = "  \"" + key.prefix(60) + "\n" + key.dropFirst(60).prefix(70) + "\r\n " + key.dropFirst(130) + "\" "
        #expect(License.parse(wrapped, publicKeyBase64: publicKey)?.key == key)
        let link = "lunchbox://activate?key=" + key
        #expect(License.parse(link, publicKeyBase64: publicKey)?.order == "cs_test_a1B2c3")
    }

    @Test func anyChangeIsRejected() {
        var tampered = Array(key)
        let i = key.distance(from: key.startIndex, to: key.firstIndex(of: ".")!) + 5
        tampered[i] = tampered[i] == "A" ? "B" : "A"
        #expect(License.parse(String(tampered), publicKeyBase64: publicKey) == nil)
        #expect(License.parse(key.replacingOccurrences(of: "lunchbox1.", with: "lunchbox2."), publicKeyBase64: publicKey) == nil)
        #expect(License.parse("", publicKeyBase64: publicKey) == nil)
        #expect(License.parse("not a key", publicKeyBase64: publicKey) == nil)
    }

    @Test func revocationHashMatchesTheStore() throws {
        // store/lib/license.js revocationHash("cs_test_a1B2c3")
        #expect(try #require(License.parse(key, publicKeyBase64: publicKey)).revocationHash == "a727f84a580276b3")
    }

    @Test func aKeyFromBeforeTheRenameStillWorks() throws {
        // Signed by the same store key while LunchboxWM was called Tessel (the owner's key is one).
        let legacy = "tessel1.eyJwIjoidGVzc2VsIiwiZSI6ImJ1eWVyQGV4YW1wbGUuY29tIiwibyI6ImNzX3Rlc3RfYTFCMmMzIiwidCI6MTc5MjAwMDAwMH0.0qYx5WIOFT-ut7Oyb5MjBzK7PPlrNxafyApS0agOnLGYogKJdu0PyF8Hxrn7ELD20T_Q2w6529qJGxU8oTE7AQ"
        #expect(try #require(License.parse(legacy, publicKeyBase64: publicKey)).order == "cs_test_a1B2c3")
        // But only as itself: Tessel's product under LunchboxWM's prefix is no key at all.
        #expect(License.parse(legacy.replacingOccurrences(of: "tessel1.", with: "lunchbox1."), publicKeyBase64: publicKey) == nil)
    }

    @Test func anotherStoresKeyIsRejected() {
        // The real store's public key: a key signed with the test pair must not pass.
        #expect(License.parse(key, publicKeyBase64: "qLQZTRdDyv019zqGNELstTUJa3rmQXnLNk5eoYgM1nU=") == nil)
    }
}

@Suite struct FreeTrial {
    let start = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func sevenDaysFromFirstLaunch() {
        #expect(Trial.state(firstLaunch: start, now: start) == .active(daysLeft: 7))
        #expect(Trial.state(firstLaunch: start, now: start + 86_400 * 6.5) == .active(daysLeft: 1))
        #expect(Trial.state(firstLaunch: start, now: start + 86_400 * 7) == .ended)
    }

    @Test func settingTheClockBackDoesNotAddDays() {
        #expect(Trial.state(firstLaunch: start, now: start - 86_400 * 30) == .active(daysLeft: 7))
    }
}
