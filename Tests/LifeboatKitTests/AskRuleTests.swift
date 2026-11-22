import XCTest
@testable import LifeboatKit

/// Answers every request from a queue of (status, JSON) pairs; `{"ok":true}` once the queue is empty.
final class StubProtocol: URLProtocol {
    nonisolated(unsafe) static var queue: [(Int, String)] = []
    nonisolated(unsafe) static var paths: [String] = []
    nonisolated(unsafe) static var bodies: [[String: Any]] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        Self.paths.append(request.url?.path ?? "")
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                data.append(buffer, count: n)
            }
        }
        Self.bodies.append((try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:])
        let (status, json) = Self.queue.isEmpty ? (200, #"{"ok":true}"#) : Self.queue.removeFirst()
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(json.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

@MainActor
final class AskRuleTests: XCTestCase {
    private var defaults: UserDefaults!
    private let key = "lb_pub_test_askrule"
    private let day = 86_400.0

    private func make() -> Lifeboat {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        let lifeboat = Lifeboat(defaults: defaults, session: URLSession(configuration: config))
        lifeboat.configure(appKey: key)
        return lifeboat
    }

    override func setUp() async throws {
        defaults = UserDefaults(suiteName: "lifeboat.askrule.\(UUID().uuidString)")
        StubProtocol.queue = []
        StubProtocol.paths = []
        StubProtocol.bodies = []
    }

    private func setAsks(daysAgo: [Double]) {
        defaults.set(daysAgo.map { Date().timeIntervalSince1970 - $0 * day }, forKey: "lifeboat.asks.\(key)")
    }

    func testFirstAskIsDueAndLaunchFetchesNothing() async {
        let lifeboat = make()
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(StubProtocol.paths, [], "launch makes no request for someone never asked")
        XCTAssertTrue(lifeboat.shouldPrompt)
        let shown = await lifeboat.askIfDue()
        XCTAssertTrue(shown)
        XCTAssertTrue(lifeboat.isAsking)
        XCTAssertEqual(StubProtocol.paths, ["/v1/config"])
    }

    func testShowingTheScreenCountsAnAskAndSendsRangesOnly() async {
        let lifeboat = make()
        await lifeboat.screenShown()
        XCTAssertFalse(lifeboat.shouldPrompt, "asked just now: wait 30 days")
        let body = StubProtocol.bodies.last ?? [:]
        XCTAssertEqual(body["ask"] as? Int, 1)
        XCTAssertEqual(body["launches"] as? String, "1")
        XCTAssertEqual(body["age"] as? String, "0")
        XCTAssertEqual(Set(body.keys), ["ask", "launches", "age"])
    }

    func testThirtyDayGapAndThreeAYear() {
        let lifeboat = make()
        setAsks(daysAgo: [29])
        XCTAssertFalse(lifeboat.shouldPrompt)
        setAsks(daysAgo: [31])
        XCTAssertTrue(lifeboat.shouldPrompt)
        setAsks(daysAgo: [200, 100, 31])
        XCTAssertFalse(lifeboat.shouldPrompt, "three asks in the last 365 days")
        setAsks(daysAgo: [370, 100, 31])
        XCTAssertTrue(lifeboat.shouldPrompt, "the oldest ask is over a year old")
    }

    func testClosedSignupsShowNothingAndCountNoAsk() async {
        StubProtocol.queue = [(200, #"{"appName":"A","version":0,"screen":{},"mode":"live","accepting":false}"#)]
        let lifeboat = make()
        let shown = await lifeboat.askIfDue()
        XCTAssertFalse(shown)
        XCTAssertFalse(lifeboat.isAsking)
        XCTAssertNil(defaults.array(forKey: "lifeboat.asks.\(key)"))
    }

    private func state(_ status: String) -> String {
        #"{"id":"sub_1","email":"a@b.co","status":"\#(status)","pendingEmail":null,"preferences":{"critical":true,"updates":true,"promotions":false}}"#
    }

    func testUnsubscribedIsNeverAsked() async throws {
        let lifeboat = make()
        StubProtocol.queue = [(200, state("confirmed")), (200, state("unsubscribed"))]
        _ = try await lifeboat.subscribe(email: "a@b.co", consentText: Lifeboat.lockedDisclosure)
        await lifeboat.refresh()
        XCTAssertEqual(lifeboat.state?.status, .unsubscribed)
        XCTAssertFalse(lifeboat.shouldPrompt)
    }

    func testErasedIsNeverAskedButExpiredSignupIs() async throws {
        var lifeboat = make()
        StubProtocol.queue = [(200, state("confirmed")), (404, #"{"error":"not_found"}"#)]
        _ = try await lifeboat.subscribe(email: "a@b.co", consentText: Lifeboat.lockedDisclosure)
        await lifeboat.refresh()
        XCTAssertNil(lifeboat.state)
        XCTAssertFalse(lifeboat.shouldPrompt, "erased: never asked again")

        defaults = UserDefaults(suiteName: "lifeboat.askrule.\(UUID().uuidString)")
        lifeboat = make()
        StubProtocol.queue = [(200, state("pending")), (404, #"{"error":"not_found"}"#)]
        _ = try await lifeboat.subscribe(email: "a@b.co", consentText: Lifeboat.lockedDisclosure)
        await lifeboat.refresh()
        XCTAssertNil(lifeboat.state)
        XCTAssertTrue(lifeboat.shouldPrompt, "never confirmed and expired: may be asked again")
    }
}
