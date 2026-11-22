import SwiftUI

/// Appearance tokens. Same shape as the dashboard's signup screen editor and the React Native SDK.
/// Resolution order (later wins): Lifeboat defaults → dashboard config → `appearance` passed in code.
public struct LifeboatAppearance: Codable, Equatable, Sendable {
    public struct Colors: Codable, Equatable, Sendable {
        public var accent: String?
        public var onAccent: String?
        public var background: String?
        public var text: String?
        public var muted: String?
        public var field: String?
        /// Error text, the email field's error border and destructive actions. Default: the system red.
        public var error: String?

        public init(accent: String? = nil, onAccent: String? = nil, background: String? = nil,
                    text: String? = nil, muted: String? = nil, field: String? = nil, error: String? = nil) {
            self.accent = accent; self.onAccent = onAccent; self.background = background
            self.text = text; self.muted = muted; self.field = field; self.error = error
        }
    }

    public var colors: Colors?
    public var colorsDark: Colors?
    /// Corner radius for inputs and buttons, 0–28.
    public var radius: Double?
    /// Typeface for the screen titles ("Where can we reach you?", "Check your inbox"): "default", "serif" or "rounded".
    public var titleDesign: String?
    /// Weight of the titles with `titleDesign`: "regular", "medium", "semibold" or "bold" (default).
    public var titleWeight: String?
    /// A custom font registered in your app, for the titles. Wins over `titleDesign`; its own weight is used.
    public var titleFontName: String?
    /// SF Symbol shown on the "Check your inbox" screen in a soft tile, e.g. "envelope". Default: ✉️ when the screen has an icon.
    public var inboxSymbol: String?

    public init(colors: Colors? = nil, colorsDark: Colors? = nil, radius: Double? = nil,
                titleDesign: String? = nil, titleWeight: String? = nil, titleFontName: String? = nil, inboxSymbol: String? = nil) {
        self.colors = colors; self.colorsDark = colorsDark; self.radius = radius
        self.titleDesign = titleDesign; self.titleWeight = titleWeight; self.titleFontName = titleFontName; self.inboxSymbol = inboxSymbol
    }
}

/// Resolved colors for one color scheme.
public struct LifeboatTheme: Sendable {
    public var accent: Color
    public var onAccent: Color
    public var background: Color
    public var text: Color
    public var muted: Color
    public var field: Color
    public var radius: CGFloat
    public var error: Color = .red
    public var titleDesign: Font.Design = .default
    public var titleWeight: Font.Weight = .bold
    public var titleFontName: String?
    public var inboxSymbol: String?

    /// The title font at a text style's size, in your title typeface.
    public func titleFont(_ style: Font.TextStyle) -> Font {
        if let titleFontName {
            let size: CGFloat = style == .title ? 28 : style == .title2 ? 22 : 20
            return .custom(titleFontName, size: size, relativeTo: style)
        }
        return .system(style, design: titleDesign).weight(titleWeight)
    }

    static let lightDefaults = LifeboatAppearance.Colors(
        accent: "#111111", onAccent: "#ffffff", background: "#ffffff", text: "#111111", muted: "#6b7076", field: "#f1f2f4")
    static let darkDefaults = LifeboatAppearance.Colors(
        accent: "#f2f3f5", onAccent: "#111111", background: "#0e0f11", text: "#f2f3f5", muted: "#9aa0a6", field: "#1c1e22")

    public static func resolve(_ scheme: ColorScheme, layers: [LifeboatAppearance?]) -> LifeboatTheme {
        let dark = scheme == .dark
        var c = dark ? darkDefaults : lightDefaults
        var radius: Double = 14
        var error: Color = .red
        var design: Font.Design = .default
        var weight: Font.Weight = .bold
        var fontName: String?
        var symbol: String?
        for layer in layers.compactMap({ $0 }) {
            if let l = dark ? layer.colorsDark : layer.colors {
                if let v = l.accent, Color(lifeboatHex: v) != nil { c.accent = v }
                if let v = l.onAccent, Color(lifeboatHex: v) != nil { c.onAccent = v }
                if let v = l.background, Color(lifeboatHex: v) != nil { c.background = v }
                if let v = l.text, Color(lifeboatHex: v) != nil { c.text = v }
                if let v = l.muted, Color(lifeboatHex: v) != nil { c.muted = v }
                if let v = l.field, Color(lifeboatHex: v) != nil { c.field = v }
                if let v = l.error, let col = Color(lifeboatHex: v) { error = col }
            }
            if let r = layer.radius, r.isFinite { radius = min(28, max(0, r)) }
            switch layer.titleDesign { case "serif": design = .serif; case "rounded": design = .rounded; case "default": design = .default; default: break }
            switch layer.titleWeight { case "regular": weight = .regular; case "medium": weight = .medium; case "semibold": weight = .semibold; case "bold": weight = .bold; default: break }
            if let n = layer.titleFontName, !n.isEmpty { fontName = n }
            if let s = layer.inboxSymbol, !s.isEmpty { symbol = s }
        }
        func color(_ hex: String?) -> Color { Color(lifeboatHex: hex ?? "") ?? .primary }
        return LifeboatTheme(accent: color(c.accent), onAccent: color(c.onAccent), background: color(c.background),
                             text: color(c.text), muted: color(c.muted), field: color(c.field), radius: radius,
                             error: error, titleDesign: design, titleWeight: weight, titleFontName: fontName, inboxSymbol: symbol)
    }
}

extension Color {
    /// "#rrggbb" only; anything else returns nil.
    init?(lifeboatHex hex: String) {
        let s = hex.trimmingCharacters(in: .whitespaces)
        guard s.count == 7, s.hasPrefix("#"), let v = UInt32(s.dropFirst(), radix: 16) else { return nil }
        self.init(red: Double((v >> 16) & 0xff) / 255, green: Double((v >> 8) & 0xff) / 255, blue: Double(v & 0xff) / 255)
    }
}
