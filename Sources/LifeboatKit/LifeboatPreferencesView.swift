import SwiftUI

/// Standard, honest email settings: current address and status, change email, email types, unsubscribe.
/// Designed to be pushed from a Settings screen. It is a native Form, so with no `appearance` it looks like
/// iOS Settings. Pass the same `appearance` you give the signup sheet and it takes your colours instead:
/// `background` behind the page, `field` for the rows, `text`, `muted` and `accent` for buttons and switches.
public struct LifeboatPreferencesView: View {
    @ObservedObject private var lifeboat = Lifeboat.shared
    private let appName: String
    private let appearance: LifeboatAppearance?
    private let onAddEmail: (() -> Void)?
    @Environment(\.colorScheme) private var scheme

    @State private var newEmail = ""
    @State private var editing = false
    @State private var busy = false
    @State private var message: String?
    @State private var messageIsError = false
    @State private var confirmUnsubscribe = false

    public init(appName: String, appearance: LifeboatAppearance? = nil, onAddEmail: (() -> Void)? = nil) {
        self.appName = appName
        self.appearance = appearance
        self.onAddEmail = onAddEmail
    }

    /// Your colours, when you passed an appearance. Nil keeps the stock iOS look.
    private var theme: LifeboatTheme? {
        appearance.map { LifeboatTheme.resolve(scheme, layers: [$0]) }
    }
    private var secondary: Color { theme?.muted ?? .secondary }

    public var body: some View {
        if let theme {
            content
                .scrollContentBackground(.hidden)
                .background(theme.background.ignoresSafeArea())
                .foregroundStyle(theme.text)
                .tint(theme.accent)
        } else {
            content
        }
    }

    /// A section's rows, on your `field` colour when themed.
    @ViewBuilder
    private func rows<V: View>(@ViewBuilder _ views: () -> V) -> some View {
        if let theme { views().listRowBackground(theme.field) } else { views() }
    }

    private var content: some View {
        Form {
            if let state = lifeboat.state, state.isActive {
                activeSections(state)
            } else {
                inactiveSection
            }
        }
        .navigationTitle("Email updates")
        .task { await lifeboat.refresh() }
        .confirmationDialog("Unsubscribe from everything?", isPresented: $confirmUnsubscribe, titleVisibility: .visible) {
            Button("Unsubscribe", role: .destructive) { run(nil) { try await lifeboat.unsubscribe() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You won't get any emails from \(appName), including critical ones.")
        }
    }

    @ViewBuilder
    private func activeSections(_ state: LifeboatState) -> some View {
        Section { rows {
            LabeledContent("Email", value: state.email)
            LabeledContent("Status", value: state.status == .confirmed ? "Confirmed" : "Check your inbox to confirm")
            if state.status == .pending {
                Button("Resend link") {
                    run("We sent the link to \(state.email) again.") { try await lifeboat.resendConfirmation() }
                }
                .disabled(busy)
            }
            if let pending = state.pendingEmail {
                Text("Waiting for you to confirm \(pending). Until then, emails still go to \(state.email).")
                    .font(.footnote).foregroundStyle(secondary)
            }
            if editing {
                TextField("New email address", text: $newEmail)
                    .textContentType(.emailAddress)
                    #if os(iOS)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    #endif
                    .autocorrectionDisabled()
                if Self.looksLikeEmail(newEmail), let fix = LifeboatEmailCheck.suggestion(for: newEmail) {
                    Button { newEmail = fix } label: {
                        Text("Did you mean ") + Text(fix).bold() + Text("?")
                    }
                    .font(.footnote)
                    .buttonStyle(.borderless)
                }
                HStack {
                    Button("Cancel") { editing = false; newEmail = "" }
                    Spacer()
                    Button("Send confirmation link") {
                        let target = newEmail.trimmingCharacters(in: .whitespaces)
                        run("We sent a confirmation link to \(target).") {
                            try await lifeboat.changeEmail(to: target)
                            editing = false
                            newEmail = ""
                        }
                    }
                    .disabled(busy || !Self.looksLikeEmail(newEmail))
                }
                .buttonStyle(.borderless)
            } else {
                Button("Change email") { editing = true }
            }
        } } footer: {
            if let message {
                Text(message).foregroundStyle(messageIsError ? (theme?.error ?? .red) : secondary)
            }
        }

        Section { rows {
            Toggle(isOn: .constant(true)) { typeLabel(.critical) }.disabled(true)
            Toggle(isOn: binding(\.updates) { try await lifeboat.setPreferences(updates: $0) }) { typeLabel(.updates) }
            Toggle(isOn: binding(\.promotions) { try await lifeboat.setPreferences(promotions: $0) }) { typeLabel(.promotions) }
        } } header: {
            Text("What you get").foregroundStyle(secondary)
        }

        Section { rows {
            Button(role: .destructive) { confirmUnsubscribe = true } label: {
                Text("Unsubscribe from everything").foregroundStyle(theme?.error ?? .red)
            }
        } } footer: {
            Text(Lifeboat.lockedDisclosure).foregroundStyle(secondary)
        }
    }

    private var inactiveSection: some View {
        Section { rows {
            Text(lifeboat.state.map { "\($0.email) is unsubscribed." } ?? "You haven't added an email.")
            if let onAddEmail {
                Button("Add email", action: onAddEmail)
            }
        } } footer: {
            Text("\(appName) uses email only to reach you about important changes.").foregroundStyle(secondary)
        }
    }

    private func typeLabel(_ c: LifeboatCategory) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(c.label)
            Text(c.detail).font(.footnote).foregroundStyle(secondary)
        }
    }

    private func binding(_ key: KeyPath<LifeboatPreferences, Bool>, set: @escaping (Bool) async throws -> Void) -> Binding<Bool> {
        Binding(
            get: { lifeboat.state?.preferences[keyPath: key] ?? false },
            set: { value in run(nil) { try await set(value) } }
        )
    }

    private func run(_ success: String?, _ work: @escaping () async throws -> Void) {
        busy = true
        message = nil
        Task {
            defer { busy = false }
            do {
                try await work()
                if let success { message = success; messageIsError = false }
            } catch {
                message = (error as? LocalizedError)?.errorDescription ?? "Something went wrong."
                messageIsError = true
            }
        }
    }

    static func looksLikeEmail(_ s: String) -> Bool {
        s.trimmingCharacters(in: .whitespaces).range(of: #"^[^\s@]+@[^\s@]+\.[^\s@]{2,}$"#, options: .regularExpression) != nil
    }
}
