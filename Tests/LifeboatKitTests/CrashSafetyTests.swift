import XCTest
@testable import LifeboatKit

/// Nothing a developer, a server or a damaged device can do should crash the app the kit lives in.
@MainActor
final class CrashSafetyTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() async throws {
        defaults = UserDefaults(suiteName: "lifeboat.safety.\(UUID().uuidString)")
        StubProtocol.queue = []
        StubProtocol.paths = []
        StubProtocol.bodies = []
        StubProtocol.headers = []
        StubProtocol.methods = []
    }

    private func make(key: String = "lb_pub_test_safety") -> Lifeboat {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        let lifeboat = Lifeboat(defaults: defaults, session: URLSession(configuration: config))
        lifeboat.configure(appKey: key)
        return lifeboat
    }

    func testSecretKeyLeavesLifeboatOffInsteadOfCrashing() async {
        let lifeboat = make(key: "lb_sec_live_oops")
        XCTAssertFalse(lifeboat.isConfigured)
        let shown = await lifeboat.askIfDue()
        XCTAssertFalse(shown)
        await lifeboat.screenShown()
        await lifeboat.refresh()
        XCTAssertEqual(StubProtocol.paths, [], "nothing is sent with a secret key")
        do {
            _ = try await lifeboat.subscribe(email: "a@example.com", consentText: Lifeboat.lockedDisclosure)
            XCTFail("should throw")
        } catch let e as LifeboatError {
            XCTAssertEqual(e.code, "not_configured")
        } catch { XCTFail("\(error)") }
    }

    func testMalformedKeysLeaveLifeboatOff() {
        for key in ["", "hello", "lb_pub_", "lb_pub_abc", "LB_PUB_TEST_X"] {
            XCTAssertFalse(make(key: key).isConfigured, key)
        }
    }

    func testDamagedSavedDataIsIgnored() {
        let key = "lb_pub_test_damaged"
        for k in ["lifeboat.state.v1.\(key)", "lifeboat.config.v1.\(key)", "lifeboat.config.\(key)"] {
            defaults.set(Data("{not json".utf8), forKey: k)
        }
        defaults.set("not a list", forKey: "lifeboat.asks.\(key)")
        defaults.set("x", forKey: "lifeboat.firstSeen.\(key)")
        let lifeboat = make(key: key)
        XCTAssertTrue(lifeboat.isConfigured)
        XCTAssertNil(lifeboat.state)
        XCTAssertTrue(lifeboat.shouldPrompt, "damaged data reads as nothing saved")
    }

    func testGarbageFromTheServerNeverCrashes() async {
        let lifeboat = make()
        StubProtocol.queue = [(200, "<html>proxy page</html>")]
        _ = await lifeboat.askIfDue() // config can't be read: carries on with what it has
        StubProtocol.queue = [(200, "[1,2,3]")]
        do {
            _ = try await lifeboat.subscribe(email: "a@example.com", consentText: Lifeboat.lockedDisclosure)
            XCTFail("should throw")
        } catch let e as LifeboatError {
            XCTAssertEqual(e.code, "bad_response")
        } catch { XCTFail("\(error)") }
        StubProtocol.queue = [(200, #"{"id":"x","status":"teleported"}"#)]
        do {
            _ = try await lifeboat.subscribe(email: "a@example.com", consentText: Lifeboat.lockedDisclosure)
            XCTFail("should throw")
        } catch let e as LifeboatError {
            XCTAssertEqual(e.code, "bad_response", "an unknown status is a bad answer, not a crash")
        } catch { XCTFail("\(error)") }
    }

    func testOfflineNeverCrashes() async {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [OfflineProtocol.self]
        let lifeboat = Lifeboat(defaults: defaults, session: URLSession(configuration: config))
        lifeboat.configure(appKey: "lb_pub_test_offline")
        _ = await lifeboat.askIfDue()
        await lifeboat.screenShown()
        await lifeboat.refresh()
        do {
            _ = try await lifeboat.subscribe(email: "a@example.com", consentText: Lifeboat.lockedDisclosure)
            XCTFail("should throw")
        } catch let e as LifeboatError {
            XCTAssertEqual(e.code, "network_error")
        } catch { XCTFail("\(error)") }
    }

    func testTwoAsksAtOnceShowOneSheet() async {
        let lifeboat = make()
        async let a = lifeboat.askIfDue()
        async let b = lifeboat.askIfDue()
        let results = await [a, b]
        XCTAssertEqual(results.filter { $0 }.count, 1)
    }

    func testTimingCallsInAnyOrderAreSafe() async {
        let lifeboat = make()
        lifeboat.sheetAppeared() // nothing asked yet: ignored
        let asked = await lifeboat.askIfDue()
        XCTAssertTrue(asked)
        lifeboat.sheetAppeared()
        lifeboat.sheetAppeared() // twice: still one measurement
        await lifeboat.screenShown()
        await lifeboat.screenShown()
        XCTAssertEqual(StubProtocol.bodies.compactMap { $0["sheetMs"] }.count, 1, "one ask, one time")
    }

    func testTypoCheckHandlesOddInput() {
        for input in ["", "@", "a@", "@b", "a@b", "😀@😀.com", String(repeating: "a", count: 5_000) + "@gmial.com", "a@gmail.com.", "a@@gmail.com"] {
            _ = LifeboatEmailCheck.suggestion(for: input)
        }
        XCTAssertEqual(LifeboatEmailCheck.suggestion(for: "a@gmial.com"), "a@gmail.com")
    }
}

/// Every request fails as if the device were offline.
final class OfflineProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)) }
}
