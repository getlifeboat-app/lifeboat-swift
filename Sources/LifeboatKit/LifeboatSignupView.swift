import SwiftUI

/// Ready-made signup screen ("Where can we reach you?"). Copy, restyle or replace it freely:
/// the honesty rules that matter are enforced by the server (double opt-in, unticked news & offers,
/// unsubscribe in every email). If you build your own, keep `Lifeboat.lockedDisclosure` visible.
///
/// It shows the kinds of email before the field (Critical always on, Product updates on, News & offers off),
/// so people agree to something they can see. Present it as a sheet with `.lifeboatSignupSheet(isPresented:)`,
/// which sizes the sheet to the content, or full screen (for example in onboarding).
public struct LifeboatSignupView: View {
    public enum Result { case subscribed, skipped }
    /// How the screen is shown. A sheet gets less top padding and no vertical centring.
    ///
    /// It also decides what happens while your account isn't taking signups. A sheet is something the person
    /// opened (for example "Add email" in your settings), so it tells them signup is closed for now. A full
    /// screen step in your onboarding closes without showing anything.
    public enum Presentation: Sendable { case fullScreen, sheet }

    @ObservedObject private var lifeboat = Lifeboat.shared
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let appName: String?
    private let appearance: LifeboatAppearance?
    private let allowSkip: Bool
    private let icon: String?
    private let presentation: Presentation
    private let onDone: (Result) -> Void

    @State private var email = ""
    @State private var promotions = false
    @State private var updates = true
    /// "How it works": Lifeboat's promises, in place of the email types.
    @State private var showHow = false
    @FocusState private var typing: Bool
    @State private var busy = false
    @State private var error: String?
    /// "Did you mean …?" for a likely typo, asked once per address before it is sent.
    @State private var suggestion: String?
    @State private var askedAbout: String?
    /// The address just submitted: set once the confirmation email is on its way.
    @State private var sentTo: String?
    @State private var note: String?
    /// The server said signups are closed when the form was sent.
    @State private var turnedAway = false

    public init(appName: String? = nil, appearance: LifeboatAppearance? = nil,
                allowSkip: Bool = true, icon: String? = "🛟", presentation: Presentation = .fullScreen,
                onDone: @escaping (Result) -> Void) {
        self.appName = appName
        self.appearance = appearance
        self.allowSkip = allowSkip
        self.icon = icon
        self.presentation = presentation
        self.onDone = onDone
    }

    private var screen: LifeboatRemoteConfig.Screen? { lifeboat.remoteConfig?.screen }
    private var name: String { appName ?? lifeboat.remoteConfig?.appName ?? "This app" }
    private var message: String {
        screen?.message ?? "\(name) will only email you about important changes, like a new version, a critical fix, or if the app ever moves."
    }

    public var body: some View {
        let t = LifeboatTheme.resolve(scheme, layers: [screen?.appearance, appearance])
        Group {
            if closed { closedNotice(t) } else if let sentTo { checkInbox(sentTo, t) } else { form(t) }
        }
        .padding(.horizontal, 24).padding(.top, presentation == .sheet ? 28 : 60).padding(.bottom, 24)
        .background(t.background.ignoresSafeArea())
        // config first, so the view is counted against the version this install was given
        .onAppear { lifeboat.sheetAppeared() }
        .task {
            await lifeboat.refreshConfigIfStale()
            // Not taking signups right now: no ask is counted, so the screen comes back once the developer's
            // account is open again. A sheet says so (see `closedNotice`); an onboarding step just moves on.
            if lifeboat.remoteConfig?.accepting == false {
                if presentation == .fullScreen { onDone(.skipped) }
                return
            }
            await lifeboat.screenShown()
        }
    }

    /// A sheet the person opened while signups are closed shows this in place of the form.
    private var closed: Bool {
        presentation == .sheet && sentTo == nil && (turnedAway || lifeboat.remoteConfig?.accepting == false)
    }

    private func closedNotice(_ t: LifeboatTheme) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                if let icon { Text(icon).font(.system(size: 18)) }
                Text("Email updates from \(name)").font(.footnote).foregroundStyle(t.muted)
            }
            .padding(.bottom, 10)
            Text("Email signup is closed for now")
                .font(t.titleFont(.title2)).foregroundStyle(t.text).fixedSize(horizontal: false, vertical: true)
            Text("\(name) isn't taking new email signups at the moment. Please check back later.")
                .foregroundStyle(t.muted).padding(.top, 6).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 24)
            Button { onDone(.skipped) } label: {
                Text("Close").bold()
                    .frame(maxWidth: .infinity, minHeight: 54)
                    .foregroundStyle(t.onAccent)
                    .background(t.accent, in: RoundedRectangle(cornerRadius: t.radius + 2))
            }
        }
    }

    /// Shown right after signing up, while the person still has the app open: the address they typed,
    /// a way to fix a typo, and a shortcut to their inbox.
    private func checkInbox(_ address: String, _ t: LifeboatTheme) -> some View {
        VStack(spacing: 0) {
            VStack(spacing: 12) {
                if let symbol = t.inboxSymbol {
                    Image(systemName: symbol).font(.system(size: 30, weight: .regular)).foregroundStyle(t.text)
                        .frame(width: 64, height: 64)
                        .background(t.field, in: RoundedRectangle(cornerRadius: 18))
                        .padding(.bottom, 8).accessibilityHidden(true)
                } else if icon != nil { Text("✉️").font(.system(size: 44)).padding(.bottom, 8) }
                Text("Check your inbox").font(t.titleFont(.title)).multilineTextAlignment(.center).foregroundStyle(t.text)
                Text("We sent a link to \(address). Tap it to confirm your email.")
                    .multilineTextAlignment(.center).foregroundStyle(t.muted)
                if let note { Text(note).font(.footnote).multilineTextAlignment(.center).foregroundStyle(t.muted) }
                Button("Wrong address? Change it") { note = nil; sentTo = nil }
                    .font(.subheadline).foregroundStyle(t.text).padding(.top, 8)
                Button("Resend link") { resend() }
                    .font(.subheadline).foregroundStyle(t.muted).disabled(busy)
            }
            Spacer(minLength: 24)
            #if os(iOS)
            Button(action: Lifeboat.openMail) {
                Text("Open Mail").bold()
                    .frame(maxWidth: .infinity, minHeight: 54)
                    .foregroundStyle(t.onAccent)
                    .background(t.accent, in: RoundedRectangle(cornerRadius: t.radius + 2))
            }
            #endif
            Button("Continue") { onDone(.subscribed) }
                .foregroundStyle(t.muted).frame(height: 44)
        }
    }

    private func resend() {
        guard !busy else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                try await lifeboat.resendConfirmation()
                note = "Sent again. It can take a minute to arrive."
            } catch {
                note = (error as? LocalizedError)?.errorDescription ?? "Something went wrong."
            }
        }
    }

    // News & offers is always listed and always starts off: only the person can switch it on.

    private func form(_ t: LifeboatTheme) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if presentation == .fullScreen { Spacer(minLength: 0) }
            HStack(spacing: 8) {
                if let icon { Text(icon).font(.system(size: 18)) }
                Text("Email updates from \(name)").font(.footnote).foregroundStyle(t.muted)
            }
            .padding(.bottom, 10)
            Text(screen?.title ?? "Where can we reach you?")
                .font(t.titleFont(.title2)).foregroundStyle(t.text).fixedSize(horizontal: false, vertical: true)
            Text(message).foregroundStyle(t.muted).padding(.top, 6).fixedSize(horizontal: false, vertical: true)
            // While typing, the choices fold away so the field, the typo check and Continue stay above the keyboard.
            if !typing {
                Group { if showHow { howItWorks(t) } else { choices(t) } }
                    .padding(.top, 14)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
            }
            Text(Lifeboat.lockedDisclosure)
                .font(.footnote).foregroundStyle(t.text).padding(.top, 10).fixedSize(horizontal: false, vertical: true)
            TextField("Email address", text: $email)
                .textContentType(.emailAddress)
                #if os(iOS)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                #endif
                .autocorrectionDisabled()
                .submitLabel(.done)
                .focused($typing)
                .onSubmit(submit)
                .onChange(of: email) { if email != askedAbout { suggestion = nil } }
                .padding(.horizontal, 16).frame(height: 50)
                .background(t.field, in: RoundedRectangle(cornerRadius: t.radius))
                .overlay(RoundedRectangle(cornerRadius: t.radius).stroke(error != nil ? t.error : typing ? t.text : t.muted.opacity(0.25), lineWidth: 1))
                .foregroundStyle(t.text)
                .padding(.top, 14)
            if let suggestion {
                Button { email = suggestion; self.suggestion = nil } label: {
                    (Text("Did you mean ") + Text(suggestion).bold() + Text("?")).font(.footnote)
                }
                .foregroundStyle(t.text).padding(.top, 8)
                .accessibilityHint("Replaces the address you typed")
            }
            Text(error ?? "✓ \(Lifeboat.confirmationNote)")
                .font(.footnote).foregroundStyle(error == nil ? t.muted : t.error).padding(.top, 8)
                .fixedSize(horizontal: false, vertical: true)
            if presentation == .fullScreen { Spacer(minLength: 24) }
            Button(action: submit) {
                ZStack {
                    if busy { ProgressView().tint(t.onAccent) } else { Text(screen?.continueLabel ?? "Continue").bold() }
                }
                .frame(maxWidth: .infinity, minHeight: 52)
                .foregroundStyle(t.onAccent)
                .background(t.accent, in: Capsule())
            }
            .disabled(busy || !LifeboatPreferencesView.looksLikeEmail(email))
            .opacity(LifeboatPreferencesView.looksLikeEmail(email) ? 1 : 0.4)
            .padding(.top, 16)
            if allowSkip && !typing {
                Button(screen?.skipLabel ?? "Not now") {
                    onDone(.skipped)
                }
                .foregroundStyle(t.muted).frame(maxWidth: .infinity).frame(height: 44)
            }
            if !typing { handledBy(t) }
        }
        .animation(.easeOut(duration: 0.2), value: typing)
        .animation(.easeOut(duration: 0.2), value: showHow)
    }

    /// The kinds of email, before the field: Critical locked on, Product updates on, News & offers off.
    private func choices(_ t: LifeboatTheme) -> some View {
        VStack(spacing: 0) {
            choiceRow(.critical, t) { Text("Always on").font(.caption).foregroundStyle(t.muted) }
            Divider().overlay(t.muted.opacity(0.2))
            choiceRow(.updates, t) { Toggle("", isOn: $updates).labelsHidden().tint(t.accent) }
            Divider().overlay(t.muted.opacity(0.2))
            choiceRow(.promotions, t) { Toggle("", isOn: $promotions).labelsHidden().tint(t.accent) }
        }
        .background(t.field, in: RoundedRectangle(cornerRadius: t.radius))
        .overlay(RoundedRectangle(cornerRadius: t.radius).stroke(t.muted.opacity(0.25), lineWidth: 1))
    }

    private func choiceRow<Trailing: View>(_ c: LifeboatCategory, _ t: LifeboatTheme, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(c.label).font(.subheadline.weight(.semibold)).foregroundStyle(t.text)
                Text(c.detail.replacingOccurrences(of: " Always on.", with: ""))
                    .font(.caption).foregroundStyle(t.muted).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }

    /// Lifeboat's promises, all enforced by the server, so a copy of this screen cannot make them.
    private func howItWorks(_ t: LifeboatTheme) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("How Lifeboat handles your email").font(.subheadline.weight(.semibold)).foregroundStyle(t.text)
            promise(1, "One email", "with a link to confirm. More only if you ask.", t)
            promise(2, "\(name) doesn't get your address", "until you confirm it.", t)
            promise(3, "Leave anytime", "from any email or Settings, even if the app is gone.", t)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(t.field, in: RoundedRectangle(cornerRadius: t.radius))
        .overlay(RoundedRectangle(cornerRadius: t.radius).stroke(t.muted.opacity(0.25), lineWidth: 1))
    }

    private func promise(_ n: Int, _ head: String, _ rest: String, _ t: LifeboatTheme) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(n)").font(.caption.weight(.semibold)).foregroundStyle(t.muted)
            (Text(head).bold() + Text(" " + rest)).font(.footnote).foregroundStyle(t.text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// "Powered by lifeboat | How it works  Terms  Privacy": who runs the email step, and what that means.
    /// Shown only once the server sends Lifeboat's links (Terms and Privacy published), so it appears without an app update.
    @ViewBuilder
    private func handledBy(_ t: LifeboatTheme) -> some View {
        if let links = lifeboat.remoteConfig?.links,
           let terms = links.terms.flatMap(URL.init(string:)), let privacy = links.privacy.flatMap(URL.init(string:)) {
            HStack(spacing: 10) {
                HStack(spacing: 5) {
                    LifeboatMark().stroke(t.muted, lineWidth: 1.6).frame(width: 13, height: 13)
                    Text("Powered by ") + Text("lifeboat").fontWeight(.bold)
                }
                .accessibilityElement(children: .combine)
                Rectangle().fill(t.muted.opacity(0.35)).frame(width: 1, height: 14).accessibilityHidden(true)
                Button(showHow ? "Hide" : "How it works") { showHow.toggle() }
                Link("Terms", destination: terms)
                Link("Privacy", destination: privacy)
            }
            .lineLimit(1).minimumScaleFactor(0.8)
            .foregroundStyle(t.muted).tint(t.muted)
            .font(.caption)
            .frame(maxWidth: .infinity)
            .padding(.top, 14)
        }
    }

    private func submit() {
        guard !busy, LifeboatPreferencesView.looksLikeEmail(email) else { return }
        // A likely typo is pointed out once; pressing Continue again sends the address as typed.
        if askedAbout != email, let fix = LifeboatEmailCheck.suggestion(for: email) {
            askedAbout = email
            suggestion = fix
            return
        }
        suggestion = nil
        busy = true
        error = nil
        let wantsPromotions = promotions
        let wantsUpdates = updates
        Task {
            defer { busy = false }
            do {
                let address = email.trimmingCharacters(in: .whitespaces)
                let state = try await lifeboat.subscribe(email: address,
                                                         promotions: wantsPromotions,
                                                         updates: wantsUpdates,
                                                         consentText: "\(message) \(Lifeboat.lockedDisclosure)")
                // Already confirmed (signed up before): nothing to check. Otherwise show the inbox step.
                if state.status == .confirmed { onDone(.subscribed) } else { note = nil; sentTo = address }
            } catch let e as LifeboatError where (e.code == "signups_closed" || e.code == "verification_required") && presentation == .sheet {
                turnedAway = true
            } catch {
                self.error = (error as? LocalizedError)?.errorDescription ?? "Something went wrong."
            }
        }
    }
}

/// The lifebuoy mark: two rings and four spokes on a 24-point grid.
struct LifeboatMark: Shape {
    func path(in rect: CGRect) -> Path {
        let k = min(rect.width, rect.height) / 24
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * k, y: rect.minY + y * k) }
        var path = Path()
        path.addEllipse(in: CGRect(origin: p(3, 3), size: CGSize(width: 18 * k, height: 18 * k)))
        path.addEllipse(in: CGRect(origin: p(8.5, 8.5), size: CGSize(width: 7 * k, height: 7 * k)))
        for (a, b) in [((5.6, 5.6), (9.5, 9.5)), ((14.5, 14.5), (18.4, 18.4)), ((18.4, 5.6), (14.5, 9.5)), ((9.5, 14.5), (5.6, 18.4))] {
            path.move(to: p(a.0, a.1)); path.addLine(to: p(b.0, b.1))
        }
        return path
    }
}

/// Presents the signup screen as a sheet sized to its content. Swiping it away counts as "Not now".
struct LifeboatSignupSheetModifier: ViewModifier {
    @Binding var isPresented: Bool
    let appName: String?
    let appearance: LifeboatAppearance?
    let icon: String?
    /// Forces light or dark inside the sheet (a sheet doesn't take a colour scheme forced on your app). nil follows the system.
    var colorScheme: ColorScheme? = nil
    let onDone: (LifeboatSignupView.Result) -> Void
    @State private var height: CGFloat = 560
    @State private var finished = false

    func body(content: Content) -> some View {
        content.sheet(isPresented: $isPresented, onDismiss: {
            if !finished { onDone(.skipped) }
            finished = false
        }) {
            LifeboatSignupView(appName: appName, appearance: appearance, icon: icon, presentation: .sheet) { result in
                finished = true
                isPresented = false
                onDone(result)
            }
            .fixedSize(horizontal: false, vertical: true)
            .preferredColorScheme(colorScheme)
            .background(GeometryReader { g in Color.clear.preference(key: SheetHeightKey.self, value: g.size.height) })
            .onPreferenceChange(SheetHeightKey.self) { if $0 > 0 { height = $0 } }
            #if os(iOS)
            .presentationDetents([.height(height)])
            .presentationDragIndicator(.visible)
            #endif
        }
    }
}

private struct SheetHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// Presents the signup sheet whenever `Lifeboat.shared.askIfDue()` decides an ask is due.
struct LifeboatAskModifier: ViewModifier {
    @ObservedObject private var lifeboat = Lifeboat.shared
    let appName: String?
    let appearance: LifeboatAppearance?
    let icon: String?
    var colorScheme: ColorScheme? = nil
    let onDone: (LifeboatSignupView.Result) -> Void

    func body(content: Content) -> some View {
        content.modifier(LifeboatSignupSheetModifier(isPresented: $lifeboat.isAsking, appName: appName, appearance: appearance,
                                                     icon: icon, colorScheme: colorScheme, onDone: onDone))
    }
}

public extension View {
    /// Put this once on your root view. Then call `Lifeboat.shared.askIfDue()` at good moments in your app:
    /// the signup sheet appears here when an ask is due, at most 3 times a year for each person.
    func lifeboatAsk(appName: String? = nil, appearance: LifeboatAppearance? = nil,
                     icon: String? = nil, colorScheme: ColorScheme? = nil,
                     onDone: @escaping (LifeboatSignupView.Result) -> Void = { _ in }) -> some View {
        modifier(LifeboatAskModifier(appName: appName, appearance: appearance, icon: icon,
                                     colorScheme: colorScheme, onDone: onDone))
    }

    /// Shows Lifeboat's signup screen as a sheet sized to its content, over your app.
    /// Swiping the sheet away counts as "Not now".
    func lifeboatSignupSheet(isPresented: Binding<Bool>, appName: String? = nil, appearance: LifeboatAppearance? = nil,
                             icon: String? = nil, colorScheme: ColorScheme? = nil,
                             onDone: @escaping (LifeboatSignupView.Result) -> Void = { _ in }) -> some View {
        modifier(LifeboatSignupSheetModifier(isPresented: isPresented, appName: appName, appearance: appearance,
                                             icon: icon, colorScheme: colorScheme, onDone: onDone))
    }
}
