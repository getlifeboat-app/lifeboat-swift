import XCTest
@testable import LifeboatKit

/// What the kit sends and how it reads answers. These pin the kit's side of the API contract;
/// ContractTests checks the same calls against a real server.
@MainActor
final class RequestTests: XCTestCase {
    private var defaults: UserDefaults!
    private let key = "lb_pub_test_requests"
    private let stateJSON = #"{"id":"sub_1","email":"a@example.com","status":"pending","pendingEmail":null,"preferences":{"critical":true,"updates":true,"promotions":false}}"#

    private func make() -> Lifeboat {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        let lifeboat = Lifeboat(defaults: defaults, session: URLSession(configuration: config))
        lifeboat.configure(appKey: key)
        return lifeboat
    }

    override func setUp() async throws {
        defaults = UserDefaults(suiteName: "lifeboat.requests.\(UUID().uuidString)")
        StubProtocol.queue = []
        StubProtocol.paths = []
        StubProtocol.bodies = []
        StubProtocol.headers = []
        StubProtocol.methods = []
    }

    func testEveryRequestCarriesKeyKitVersionAndBundle() async {
        let lifeboat = make()
        await lifeboat.screenShown()
        let h = StubProtocol.headers.last ?? [:]
        XCTAssertEqual(h["Authorization"], "Bearer \(key)")
        XCTAssertEqual(h["Content-Type"], "application/json")
        XCTAssertEqual(h["Lifeboat-Kit"], "swift/\(Lifeboat.kitVersion)")
        XCTAssertEqual(h["Lifeboat-Bundle"], Bundle.main.bundleIdentifier)
    }

    func testKitVersionIsSemver() {
        XCTAssertNotNil(Lifeboat.kitVersion.range(of: #"^\d+\.\d+\.\d+$"#, options: .regularExpression),
                        "the server only records name/x.y.z")
    }

    func testSubscribeSendsTheAgreedFieldsAndSavesTheState() async throws {
        let lifeboat = make()
        StubProtocol.queue = [(200, stateJSON)]
        let wording = "My App will only email you about important changes. \(Lifeboat.lockedDisclosure)"
        let state = try await lifeboat.subscribe(email: " a@example.com ", consentText: wording)
        XCTAssertEqual(StubProtocol.methods.last, "POST")
        XCTAssertEqual(StubProtocol.paths.last, "/v1/subscribe")
        let body = StubProtocol.bodies.last ?? [:]
        XCTAssertEqual(body["consentText"] as? String, wording)
        XCTAssertEqual(body["promotions"] as? Bool, false, "News & offers only ever true when the person switched it on")
        XCTAssertEqual(body["updates"] as? Bool, true)
        XCTAssertNotNil(body["email"] as? String)
        XCTAssertEqual(state.status, .pending)
        XCTAssertEqual(lifeboat.state, state, "the state is kept after a signup")
    }

    func testServerErrorsBecomeTheirCodeAndReadableText() async {
        let lifeboat = make()
        for (code, phrase) in [("signups_closed", "isn't open"), ("verification_required", "isn't open"),
                               ("bundle_mismatch", "set up correctly"), ("disposable_email", "address you'll keep")] {
            StubProtocol.queue = [(403, #"{"error":"\#(code)"}"#)]
            do {
                _ = try await lifeboat.subscribe(email: "a@example.com", consentText: Lifeboat.lockedDisclosure)
                XCTFail("\(code) should throw")
            } catch let e as LifeboatError {
                XCTAssertEqual(e.code, code)
                XCTAssertTrue(e.errorDescription?.contains(phrase) == true, "\(code): \(e.errorDescription ?? "")")
            } catch { XCTFail("\(error)") }
        }
    }

    func testAnswerWithoutAnErrorFieldIsHttpStatus() async {
        let lifeboat = make()
        StubProtocol.queue = [(500, "<html>oops</html>")]
        do {
            _ = try await lifeboat.subscribe(email: "a@example.com", consentText: Lifeboat.lockedDisclosure)
            XCTFail("should throw")
        } catch let e as LifeboatError {
            XCTAssertEqual(e.code, "http_500")
        } catch { XCTFail("\(error)") }
    }

    func testCallsWithoutConfigureFailClearly() async {
        let lifeboat = Lifeboat(defaults: defaults, session: .shared)
        do {
            _ = try await lifeboat.subscribe(email: "a@example.com", consentText: Lifeboat.lockedDisclosure)
            XCTFail("should throw")
        } catch let e as LifeboatError {
            XCTAssertEqual(e.code, "not_configured")
        } catch { XCTFail("\(error)") }
    }

    func testTimeToSheetIsSentOnceWithTheScreenView() async throws {
        let lifeboat = make()
        let shown = await lifeboat.askIfDue()
        XCTAssertTrue(shown)
        lifeboat.sheetAppeared()
        try await Task.sleep(nanoseconds: 50_000_000) // the clock stops on the next frame
        await lifeboat.screenShown()
        let first = StubProtocol.bodies.last ?? [:]
        let ms = try XCTUnwrap(first["sheetMs"] as? Int, "time to sheet goes with the screen view")
        XCTAssertGreaterThanOrEqual(ms, 0)
        await lifeboat.screenShown()
        XCTAssertNil((StubProtocol.bodies.last ?? [:])["sheetMs"], "sent once")
    }

    func testScreenOpenedOutsideAskIfDueIsNotTimed() async {
        let lifeboat = make()
        lifeboat.sheetAppeared()
        await lifeboat.screenShown()
        XCTAssertNil((StubProtocol.bodies.last ?? [:])["sheetMs"])
    }

    func testPreferencesAndUnsubscribeUseTheSavedSubscriber() async throws {
        let lifeboat = make()
        StubProtocol.queue = [(200, stateJSON)]
        _ = try await lifeboat.subscribe(email: "a@example.com", consentText: Lifeboat.lockedDisclosure)
        StubProtocol.queue = [(200, stateJSON.replacingOccurrences(of: #""promotions":false"#, with: #""promotions":true"#))]
        let updated = try await lifeboat.setPreferences(promotions: true)
        XCTAssertEqual(StubProtocol.paths.last, "/v1/subscribers/sub_1/preferences")
        XCTAssertEqual(StubProtocol.bodies.last?["promotions"] as? Bool, true)
        XCTAssertTrue(updated.preferences.promotions)
        StubProtocol.queue = [(200, stateJSON.replacingOccurrences(of: #""status":"pending""#, with: #""status":"unsubscribed""#))]
        try await lifeboat.unsubscribe()
        XCTAssertEqual(StubProtocol.paths.last, "/v1/subscribers/sub_1/unsubscribe")
    }
}
