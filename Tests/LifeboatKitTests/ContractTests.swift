import XCTest
@testable import LifeboatKit

/// The kit against a real Lifeboat server, so a change on either side that breaks the other fails here.
/// Run with scripts/contract-test.sh, which starts a fresh local server and sets LIFEBOAT_CONTRACT_URL and
/// LIFEBOAT_CONTRACT_KEY (a test-mode public key). Skipped otherwise.
@MainActor
final class ContractTests: XCTestCase {
    private var url: URL!
    private var key: String!

    override func setUp() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let u = env["LIFEBOAT_CONTRACT_URL"].flatMap(URL.init(string:)), let k = env["LIFEBOAT_CONTRACT_KEY"] else {
            throw XCTSkip("set by scripts/contract-test.sh")
        }
        url = u
        key = k
    }

    private func make(key: String? = nil) -> Lifeboat {
        let lifeboat = Lifeboat(defaults: UserDefaults(suiteName: "lifeboat.contract.\(UUID().uuidString)")!, session: .shared)
        lifeboat.configure(appKey: key ?? self.key, apiURL: url)
        return lifeboat
    }

    private let consent = "Contract App will only email you about important changes. \(Lifeboat.lockedDisclosure)"
    private func address() -> String { "contract+\(UUID().uuidString.prefix(8).lowercased())@example.com" }

    func testConfigDecodes() async throws {
        let lifeboat = make()
        await lifeboat.refreshConfigIfStale()
        let config = try XCTUnwrap(lifeboat.remoteConfig, "the server's config decodes into the kit's model")
        XCTAssertEqual(config.accepting, true)
    }

    func testAskFlowIsAccepted() async throws {
        let lifeboat = make()
        let shown = await lifeboat.askIfDue()
        XCTAssertTrue(shown)
        lifeboat.sheetAppeared()
        try await Task.sleep(nanoseconds: 50_000_000)
        await lifeboat.screenShown() // ask ranges and sheetMs; the server answers ok or the kit ignores it
        XCTAssertFalse(lifeboat.shouldPrompt)
    }

    func testSubscriberLifecycle() async throws {
        let lifeboat = make()
        let email = address()
        let created = try await lifeboat.subscribe(email: email, consentText: consent)
        XCTAssertEqual(created.email, email)
        XCTAssertEqual(created.status, .pending)
        XCTAssertTrue(created.preferences.updates)
        XCTAssertFalse(created.preferences.promotions)

        await lifeboat.refresh()
        XCTAssertEqual(lifeboat.state?.id, created.id, "reading the subscriber back decodes")

        let prefs = try await lifeboat.setPreferences(updates: false, promotions: true)
        XCTAssertFalse(prefs.preferences.updates)
        XCTAssertTrue(prefs.preferences.promotions)

        let newEmail = address()
        let changed = try await lifeboat.changeEmail(to: newEmail)
        XCTAssertEqual(changed.email, newEmail, "not confirmed yet: the address is simply replaced and a new link sent")
        XCTAssertNil(changed.pendingEmail)

        try await lifeboat.unsubscribe()
        await lifeboat.refresh()
        XCTAssertEqual(lifeboat.state?.status, .unsubscribed)
    }

    func testErrorCodesTheKitHandles() async throws {
        let lifeboat = make()
        await assertCode("consent_required") { _ = try await lifeboat.subscribe(email: self.address(), consentText: "No unsubscribe line") }
        await assertCode("invalid_email") { _ = try await lifeboat.subscribe(email: "not-an-email", consentText: self.consent) }
        let wrongKey = make(key: "lb_pub_test_doesnotexist")
        await assertCode("invalid_key") { _ = try await wrongKey.subscribe(email: self.address(), consentText: self.consent) }
    }

    private func assertCode(_ code: String, _ call: () async throws -> Void, line: UInt = #line) async {
        do {
            try await call()
            XCTFail("expected \(code)", line: line)
        } catch let e as LifeboatError {
            XCTAssertEqual(e.code, code, line: line)
            XCTAssertNotNil(e.errorDescription, line: line)
        } catch {
            XCTFail("\(error)", line: line)
        }
    }
}
