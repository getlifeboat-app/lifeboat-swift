import Foundation
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Lifeboat client. Configure once at launch, then use `Lifeboat.shared` (an ObservableObject) from SwiftUI.
///
///     Lifeboat.shared.configure(appKey: isDebug ? "lb_pub_test_…" : "lb_pub_live_…")
///
/// Use the test key in development: test signups are kept separate and their emails go to the
/// dashboard's test inbox instead of real mailboxes.
@MainActor
public final class Lifeboat: ObservableObject {
    public static let shared = Lifeboat()

    /// Shown under every signup prompt. Not configurable, by design.
    public static let lockedDisclosure = "Unsubscribe anytime in Settings or from any email."
    public static let confirmationNote = "We'll send a link to confirm it's you."

    @Published public private(set) var state: LifeboatState?
    @Published public private(set) var remoteConfig: LifeboatRemoteConfig?
    /// True while the signup sheet from `askIfDue()` is up. `.lifeboatAsk()` presents the sheet from it.
    @Published public var isAsking = false

    private var appKey: String?
    private var apiURL = URL(string: "https://getlifeboat.app")!
    private var appVersion: String?
    private let defaults: UserDefaults
    private let session: URLSession
    private var foregroundObserver: NSObjectProtocol?
    private static let configTTL: TimeInterval = 5 * 60
    /// The ask rule, fixed like the App Store's rating prompt: at most 3 asks in any 365 days, 30 days apart.
    public static let asksPerYear = 3
    public static let daysBetweenAsks = 30
    /// This kit's version, sent with every request as `Lifeboat-Kit: swift/<version>` so Lifeboat knows which
    /// versions are still in use before changing the API. Bump it with each release tag.
    public static let kitVersion = "1.3.0"
    private static let day: TimeInterval = 24 * 3600
    /// The bucketed ask details sent with a signup, set when the screen is shown.
    private var currentAsk: [String: Any] = [:]

    init(defaults: UserDefaults = .standard, session: URLSession = .shared) {
        self.defaults = defaults
        self.session = session
    }

    // MARK: Setup

    public var isConfigured: Bool { appKey != nil }

    /// "test" for lb_pub_test_ keys, otherwise "live".
    public var mode: LifeboatMode { appKey?.hasPrefix("lb_pub_test_") == true ? .test : .live }

    /// - Parameters:
    ///   - appKey: Public key from the Lifeboat dashboard (lb_pub_test_… or lb_pub_live_…). Never a secret key.
    ///   - apiURL: Override for staging or self-hosting, e.g. https://staging.getlifeboat.app
    public func configure(appKey: String, apiURL: URL? = nil, appVersion: String? = nil) {
        precondition(!appKey.hasPrefix("lb_sec_"), "[Lifeboat] That's a SECRET key. Never ship it in an app; use the public key (lb_pub_…).")
        guard appKey.hasPrefix("lb_pub_") else {
            assertionFailure("[Lifeboat] appKey must be a public key (lb_pub_…).")
            return
        }
        self.appKey = appKey
        if let apiURL { self.apiURL = apiURL }
        self.appVersion = appVersion ?? Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        #if DEBUG
        if mode == .live { print("[Lifeboat] Using a LIVE key in a debug build: real subscribers and real email. Use your lb_pub_test_ key in development.") }
        #endif
        state = load(LifeboatState.self, key: stateKey)
        remoteConfig = load(LifeboatRemoteConfig.self, key: configKey)
        if defaults.object(forKey: firstSeenKey) == nil { defaults.set(Date().timeIntervalSince1970, forKey: firstSeenKey) }
        defaults.set(defaults.integer(forKey: launchesKey) + 1, forKey: launchesKey)
        observeForeground()
        // No config fetch here: it is only needed when the signup screen is about to show.
        Task { await refreshIfDue() }
    }

    // MARK: Subscription

    /// Call this at a good moment in your app (something finished, not in the middle of a task).
    /// Lifeboat shows the signup sheet only if an ask is due; most calls do nothing. Needs `.lifeboatAsk()`
    /// on your root view. Returns true if the sheet was shown.
    ///
    /// An ask is due when the person isn't on your list, has been asked fewer than 3 times in the last
    /// 365 days, was last asked 30 or more days ago, and your account is taking signups. Someone who
    /// unsubscribed, bounced or was erased is never asked again; they can still sign up in your settings screen.
    @discardableResult
    public func askIfDue() async -> Bool {
        guard shouldPrompt, !isAsking else { return false }
        await refreshConfigIfStale()
        guard remoteConfig?.accepting != false, state == nil else { return false }
        isAsking = true
        return true
    }

    /// True when an ask is due (the same rule as `askIfDue()`). Use it to decide whether to show
    /// `LifeboatSignupView` as a step in your onboarding; showing it counts as one ask.
    public var shouldPrompt: Bool {
        guard isConfigured, state == nil, !defaults.bool(forKey: stoppedKey), remoteConfig?.accepting != false else { return false }
        let asks = recentAsks
        guard asks.count < Self.asksPerYear else { return false }
        guard let last = asks.max() else { return true }
        return Date().timeIntervalSince1970 - last >= Double(Self.daysBetweenAsks) * Self.day
    }

    /// When the screen was shown in the last 365 days (seconds since 1970).
    private var recentAsks: [Double] {
        let cutoff = Date().timeIntervalSince1970 - 365 * Self.day
        return (defaults.array(forKey: asksKey) as? [Double] ?? []).filter { $0 >= cutoff }
    }

    /// Tell Lifeboat the signup screen was shown: it counts as one ask, and Insights can say how many people
    /// who saw it joined. `LifeboatSignupView` calls this for you; call it yourself only from a custom screen.
    /// Sends counts only, in ranges (which ask, launches so far, days since install): no email, device or user id.
    public func screenShown() async {
        guard isConfigured else { return }
        let asks = recentAsks + [Date().timeIntervalSince1970]
        defaults.set(asks, forKey: asksKey)
        currentAsk = asks.count <= Self.asksPerYear ? ["ask": asks.count, "launches": launchesBucket, "age": ageBucket] : [:]
        struct Ack: Decodable { let ok: Bool? }
        let _: Ack? = try? await request("POST", "/v1/screen-view", body: experimentFields.merging(currentAsk) { a, _ in a })
    }

    private var launchesBucket: String {
        switch defaults.integer(forKey: launchesKey) {
        case ...1: return "1"
        case 2...4: return "2-4"
        case 5...9: return "5-9"
        case 10...24: return "10-24"
        default: return "25+"
        }
    }

    private var ageBucket: String {
        let first = defaults.object(forKey: firstSeenKey) as? Double ?? Date().timeIntervalSince1970
        switch Int((Date().timeIntervalSince1970 - first) / Self.day) {
        case ...0: return "0"
        case 1...6: return "1-6"
        case 7...29: return "7-29"
        default: return "30+"
        }
    }

    /// Adds the email and sends a confirmation link. Safe to call again to resend.
    /// `promotions` must only be true if the user ticked an unticked-by-default box.
    @discardableResult
    /// `consentText` is the exact wording your screen showed. It must include `Lifeboat.lockedDisclosure`,
    /// and the server refuses the signup (`consent_required`) if it does not.
    public func subscribe(email: String, promotions: Bool = false, updates: Bool = true, consentText: String) async throws -> LifeboatState {
        var body: [String: Any] = ["email": email, "platform": platformName, "promotions": promotions, "updates": updates]
        if let appVersion { body["appVersion"] = appVersion }
        body["consentText"] = consentText
        body.merge(experimentFields) { current, _ in current }
        body.merge(currentAsk) { current, _ in current }
        let s: LifeboatState = try await request("POST", "/v1/subscribe", body: body)
        save(s)
        currentAsk = [:]
        defaults.removeObject(forKey: stoppedKey)
        return s
    }

    /// Sends the confirmation link again. Call it only when the person asks ("Resend link").
    /// The server allows one a minute and three per address, and throws `too_soon` or `resend_limit` beyond that.
    public func resendConfirmation() async throws {
        let id = try currentID()
        let s: LifeboatState = try await request("POST", "/v1/subscribers/\(id)/resend")
        save(s)
    }

    /// Opens the phone's Mail app, for a "Check your inbox" step. Does nothing where there isn't one.
    public static func openMail() {
        #if os(iOS)
        if let url = URL(string: "message://") { UIApplication.shared.open(url) }
        #endif
    }

    /// Re-reads the subscriber from the server (status, pending email change, preferences).
    public func refresh() async {
        guard let id = state?.id else { return }
        defaults.set(Date().timeIntervalSince1970, forKey: checkedKey)
        do {
            let s: LifeboatState = try await request("GET", "/v1/subscribers/\(id)")
            save(s)
        } catch let e as LifeboatError where e.code == "not_found" {
            // A signup that never confirmed expired: the person may be asked again, within the ask rule.
            // Anyone else was erased (their request, or the developer's): never ask again on our own.
            if state?.status != .pending { defaults.set(true, forKey: stoppedKey) }
            save(nil)
        } catch {
            // Offline or server error: keep the saved state.
        }
    }

    /// Starts an email change. Mail keeps going to the current address until the user clicks the link
    /// sent to the new one; then the old address gets a notice.
    @discardableResult
    public func changeEmail(to email: String) async throws -> LifeboatState {
        let id = try currentID()
        let s: LifeboatState = try await request("POST", "/v1/subscribers/\(id)/email", body: ["email": email])
        save(s)
        return s
    }

    /// Critical emails can't be turned off on their own (only by unsubscribing).
    @discardableResult
    public func setPreferences(updates: Bool? = nil, promotions: Bool? = nil) async throws -> LifeboatState {
        let id = try currentID()
        var body: [String: Any] = [:]
        if let updates { body["updates"] = updates }
        if let promotions { body["promotions"] = promotions }
        let s: LifeboatState = try await request("POST", "/v1/subscribers/\(id)/preferences", body: body)
        save(s)
        return s
    }

    public func unsubscribe() async throws {
        let id = try currentID()
        let s: LifeboatState = try await request("POST", "/v1/subscribers/\(id)/unsubscribe")
        save(s)
    }

    /// Clears local state (for testing). Doesn't unsubscribe on the server.
    public func reset() {
        for key in [asksKey, stoppedKey, checkedKey] { defaults.removeObject(forKey: key) }
        currentAsk = [:]
        save(nil)
    }

    /// On launch and on return to the app: while a confirmation is pending, check each time (the person
    /// confirms in their mail app and comes back); otherwise at most once a day.
    private func refreshIfDue() async {
        guard let s = state else { return }
        let last = defaults.object(forKey: checkedKey) as? Double ?? 0
        if s.status == .pending || Date().timeIntervalSince1970 - last >= Self.day { await refresh() }
    }

    // MARK: Dashboard config

    public func refreshConfigIfStale() async {
        if let fetched = remoteConfig?.fetchedAt, Date().timeIntervalSince(fetched) < Self.configTTL { return }
        do {
            var c: LifeboatRemoteConfig = try await request("GET", "/v1/config", query: [URLQueryItem(name: "b", value: String(bucket))])
            c.fetchedAt = Date()
            remoteConfig = c
            store(c, key: configKey)
        } catch {
            // Keep cached config (or defaults).
        }
    }

    // MARK: Internals

    private var stateKey: String { "lifeboat.state.v1.\(appKey ?? "")" }
    private var asksKey: String { "lifeboat.asks.\(appKey ?? "")" }
    private var stoppedKey: String { "lifeboat.stopped.\(appKey ?? "")" }
    private var checkedKey: String { "lifeboat.checked.\(appKey ?? "")" }
    private var launchesKey: String { "lifeboat.launches.\(appKey ?? "")" }
    private var firstSeenKey: String { "lifeboat.firstSeen.\(appKey ?? "")" }
    private var configKey: String { "lifeboat.config.v1.\(appKey ?? "")" }

    /// Which side of an A/B test this install is on: picked at random once, then kept.
    /// It is a single 0 or 1, not an identifier.
    private var bucket: Int {
        let key = "lifeboat.bucket.\(appKey ?? "")"
        if let saved = defaults.object(forKey: key) as? Int { return saved }
        let picked = Int.random(in: 0...1)
        defaults.set(picked, forKey: key)
        return picked
    }

    /// Sent with screen views and signups so the dashboard can compare the two versions.
    private var experimentFields: [String: Any] {
        guard let e = remoteConfig?.experiment else { return [:] }
        return ["experiment": e.id, "variant": e.variant]
    }

    private var platformName: String {
        #if os(iOS)
        return "ios"
        #else
        return "macos"
        #endif
    }

    private func currentID() throws -> String {
        guard let id = state?.id else { throw LifeboatError(code: "not_subscribed") }
        return id
    }

    private func save(_ s: LifeboatState?) {
        state = s
        if let s { store(s, key: stateKey) } else { defaults.removeObject(forKey: stateKey) }
    }

    private func store<T: Encodable>(_ value: T, key: String) {
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
    }

    private func load<T: Decodable>(_ type: T.Type, key: String) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private func request<T: Decodable>(_ method: String, _ path: String, body: [String: Any]? = nil, query: [URLQueryItem]? = nil) async throws -> T {
        guard let appKey else { throw LifeboatError(code: "not_configured") }
        var url = apiURL.appendingPathComponent(path)
        if let query, var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            parts.queryItems = query
            url = parts.url ?? url
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = 15
        req.setValue("Bearer \(appKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("swift/\(Self.kitVersion)", forHTTPHeaderField: "Lifeboat-Kit")
        // Lets Lifeboat check that signups for a verified app come from that app's bundle ID.
        if let bundle = Bundle.main.bundleIdentifier { req.setValue(bundle, forHTTPHeaderField: "Lifeboat-Bundle") }
        if let body { req.httpBody = try JSONSerialization.data(withJSONObject: body) }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw LifeboatError(code: "network_error")
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let code = (try? JSONDecoder().decode([String: String].self, from: data))?["error"] ?? "http_\(status)"
            throw LifeboatError(code: code)
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw LifeboatError(code: "bad_response")
        }
    }

    /// Users confirm signups and email changes in their mail app, then come back: refresh on foreground.
    private func observeForeground() {
        #if canImport(UIKit)
        guard foregroundObserver == nil else { return }
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.refreshIfDue() }
        }
        #endif
    }
}
