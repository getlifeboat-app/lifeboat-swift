import Foundation

public enum LifeboatStatus: String, Codable, Sendable {
    case pending, confirmed, unsubscribed, bounced
}

public enum LifeboatMode: String, Codable, Sendable {
    case live, test
}

/// Standard email types, defined by Lifeboat (not the app) so users get the same honest choices everywhere.
public struct LifeboatPreferences: Codable, Equatable, Sendable {
    /// App moved, security issue, data-loss bug. Always on while subscribed.
    public var critical: Bool
    /// New versions and major features. On by default.
    public var updates: Bool
    /// News & offers. Off unless the user turns it on.
    public var promotions: Bool
}

public struct LifeboatState: Codable, Equatable, Sendable {
    public let id: String
    public let email: String
    public let status: LifeboatStatus
    /// New address waiting for the user to click the confirmation link.
    public let pendingEmail: String?
    public let preferences: LifeboatPreferences

    public var isActive: Bool { status == .pending || status == .confirmed }
}

public struct LifeboatError: LocalizedError, Equatable, Sendable {
    public let code: String

    public var errorDescription: String? {
        switch code {
        case "invalid_email": return "That email doesn't look right."
        case "same_email": return "That's already your email."
        case "email_taken": return "That email is already subscribed."
        case "too_soon": return "We just sent a link to that address. Check your inbox."
        case "consent_required": return "This screen is missing the unsubscribe line, so the signup was not sent. Please update the app."
        case "signups_paused": return "Email signup is paused for this app right now. Please try again later."
        case "signups_closed", "verification_required": return "Email signup isn't open for this app right now. Please try again later."
        case "bundle_mismatch": return "Email signup isn't set up correctly for this app."
        case "resend_limit": return "We've sent the link a few times already. Check your spam folder, or use a different address."
        case "undeliverable": return "We can't deliver email to that address. Try another one."
        case "disposable_email": return "Please use an address you'll keep. Temporary inboxes can't receive our emails later."
        case "domain_cannot_receive": return "That email domain can't receive email. Check the spelling."
        case "rate_limited": return "Too many tries. Wait a minute and try again."
        case "network_error": return "You're offline. Try again in a moment."
        case "not_configured": return "Lifeboat isn't configured."
        default: return "Something went wrong. Please try again."
        }
    }
}

/// Signup screen settings from the Lifeboat dashboard (GET /v1/config).
public struct LifeboatRemoteConfig: Codable, Sendable {
    public struct Screen: Codable, Sendable {
        public var title: String?
        public var message: String?
        public var continueLabel: String?
        public var skipLabel: String?
        public var offerPromotions: Bool?
        public var appearance: LifeboatAppearance?
    }

    /// Present while the dashboard is running an A/B test and this install is taking part.
    public struct Experiment: Codable, Sendable {
        public let id: String
        public let variant: String
    }

    /// Lifeboat's own pages, sent once they are published. The signup screen shows them as a small footer.
    public struct Links: Codable, Sendable {
        public let home: String?
        public let terms: String?
        public let privacy: String?
    }

    public let appName: String
    public let version: Double
    /// false while the app can't take new signups (the developer's plan is past its limit, or signups are
    /// paused). The kit then doesn't show the signup screen. Missing from older servers: treated as true.
    public var accepting: Bool?
    public var links: Links?
    public let screen: Screen
    public var experiment: Experiment?
    public var fetchedAt: Date?
}

/// Labels and descriptions for the standard email types (same wording as the hosted pages).
public enum LifeboatCategory: String, CaseIterable, Sendable {
    case critical, updates, promotions

    public var label: String {
        switch self {
        case .critical: return "Critical"
        case .updates: return "Product updates"
        case .promotions: return "News & offers"
        }
    }

    public var detail: String {
        switch self {
        case .critical: return "If the app moves, a security issue, or a bug that could lose your data. Always on."
        case .updates: return "New versions and major features."
        case .promotions: return "Promotions, surveys and other apps from the developer."
        }
    }
}

/// Spots likely typos in the common email providers ("gmial.com", "hotmail.con") so the screen can ask
/// "Did you mean …?" before sending. It only suggests; the person can always keep what they typed.
public enum LifeboatEmailCheck {
    static let common = ["gmail.com", "googlemail.com", "yahoo.com", "yahoo.co.in", "yahoo.co.uk", "hotmail.com",
                         "outlook.com", "live.com", "msn.com", "icloud.com", "me.com", "mac.com", "aol.com",
                         "proton.me", "protonmail.com", "gmx.com", "mail.com", "zoho.com", "yandex.com", "rediffmail.com"]

    /// The corrected address, or nil when the domain is a common one already or nothing is close enough.
    public static func suggestion(for raw: String) -> String? {
        let email = raw.trimmingCharacters(in: .whitespaces).lowercased()
        guard let at = email.lastIndex(of: "@") else { return nil }
        let local = email[..<at], domain = String(email[email.index(after: at)...])
        guard !local.isEmpty, domain.contains("."), !common.contains(domain) else { return nil }
        var best: (String, Int)?
        for candidate in common {
            let d = distance(domain, candidate)
            if d < (best?.1 ?? Int.max) { best = (candidate, d) }
        }
        guard let (match, d) = best, d > 0, d <= (domain.count < 8 ? 1 : 2) else { return nil }
        return "\(local)@\(match)"
    }

    /// Edit distance where swapping two neighbouring letters counts as one edit.
    static func distance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var d = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in 0...a.count { d[i][0] = i }
        for j in 0...b.count { d[0][j] = j }
        for i in 1...a.count {
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                d[i][j] = min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + cost)
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] { d[i][j] = min(d[i][j], d[i - 2][j - 2] + 1) }
            }
        }
        return d[a.count][b.count]
    }
}
