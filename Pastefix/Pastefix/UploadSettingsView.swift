import SwiftUI
import Security
import PastefixAppCore

/// The Upload tab: the Zipline server address, the API token, and the defaults ⌘⇧U opens with.
///
/// The token is the one piece of this tab's state that never reaches `SettingsStore`. It is
/// typed into a `SecureField`, written straight to `KeychainTokenStore` the moment it commits,
/// and the field is emptied again immediately afterwards — nothing here ever calls
/// `tokenStore.token()` to put the secret back on screen. What the field shows instead is
/// whether *something* is stored, via its own placeholder text ("Stored" / "None"), which only
/// needs a `Bool` out of the Keychain, never the string itself. `SettingsStore`'s own
/// `tokenIsNotInDefaults` test guards the other half of this promise — that no persisted
/// setting is ever the token — and this view is why that guard has to hold.
struct UploadSettingsView: View {
    @ObservedObject var settings: SettingsStore
    let tokenStore: any ZiplineTokenStore

    /// The URL field's working copy, not a live `$settings.ziplineServerURL` binding: commit
    /// trims whitespace, and a binding that writes on every keystroke would fight a user typing
    /// a trailing character across the trim point.
    @State private var serverURLDraft: String
    /// Never anything but what the user is actively typing. Emptied the instant it reaches the
    /// Keychain (`commitToken`) — successfully or not, see that method — so there is never a
    /// moment after a commit attempt where a rendered field still holds the plaintext token.
    @State private var tokenDraft = ""
    /// Whether *a* token is stored — never the token itself. Refreshed after every write attempt.
    @State private var tokenIsStored: Bool
    /// A Keychain failure's message. `TokenStoreError` carries only an `OSStatus`, never the
    /// token, so this is always safe to render — see `message(for:)`.
    @State private var tokenError: String?
    @FocusState private var focus: Field?

    private enum Field: Hashable { case serverURL, token }

    init(settings: SettingsStore, tokenStore: any ZiplineTokenStore = KeychainTokenStore()) {
        _settings = ObservedObject(wrappedValue: settings)
        self.tokenStore = tokenStore
        _serverURLDraft = State(initialValue: settings.ziplineServerURL)
        // The read result is reduced to a Bool before it ever touches @State — the string itself
        // is discarded on this line, not carried anywhere a view could render it.
        _tokenIsStored = State(initialValue: ((try? tokenStore.token()) ?? nil) != nil)
    }

    var body: some View {
        Form {
            Section("Zipline Server") {
                TextField("https://your.zipline.instance", text: $serverURLDraft)
                    .focused($focus, equals: .serverURL)
                    .onSubmit { commitServerURL() }
                if let message = serverURLValidationMessage {
                    Text(message).font(.caption).foregroundStyle(.orange)
                }
                SecureField(tokenIsStored ? "Stored" : "None", text: $tokenDraft)
                    .focused($focus, equals: .token)
                    .onSubmit { commitToken() }
                if let tokenError {
                    Text(tokenError).font(.caption).foregroundStyle(.red)
                }
                HStack {
                    Text(tokenIsStored ? "A token is stored in the Keychain." : "No token stored.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Clear Token") { clearToken() }
                        .disabled(!tokenIsStored && tokenDraft.isEmpty)
                }
                Text("The API token lives in the Keychain, never in Settings. Private, LAN and Tailscale addresses are expected here — that's the normal way to reach a self-hosted Zipline.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Upload Defaults") {
                // A titled Picker suffers the same Form leading-gutter problem a titled Stepper
                // does (AGENTS.md, Plan 7) — label it by hand and hide the control's own label.
                HStack {
                    Text("Expires")
                    Spacer()
                    Picker("Expires", selection: $settings.ziplineDefaultExpiry) {
                        Text("Never").tag("never")
                        Text("1 hour").tag("1h")
                        Text("1 day").tag("1d")
                        Text("7 days").tag("7d")
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 280)
                }
                Toggle("Burn after reading", isOn: $settings.ziplineDefaultBurnOnRead)
                HStack {
                    Text("File extension")
                    Spacer()
                    TextField("txt", text: $settings.ziplineDefaultExtension)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 100)
                }
                Text("What ⌘⇧U opens with. Any of these can still be changed in the overlay itself before uploading.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .onChange(of: focus) { old, new in
            guard old != new else { return }
            if old == .serverURL { commitServerURL() }
            if old == .token { commitToken() }
        }
        .onDisappear {
            // The tab is torn down on every Settings tab switch (`TabView`), same as Presets. A
            // server-URL edit with no Return and no blur (a ⌘W straight out of the field) commits
            // here instead of vanishing. A token draft has no "keep or lose" question to answer:
            // it is either written to the Keychain now or it never existed anywhere else.
            commitServerURL()
            commitToken()
        }
    }

    private var serverURLValidationMessage: String? {
        let trimmed = serverURLDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !Self.isHTTPURL(trimmed) else { return nil }
        return "Doesn't look like an http or https URL."
    }

    private func commitServerURL() {
        let trimmed = serverURLDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        serverURLDraft = trimmed
        guard trimmed != settings.ziplineServerURL else { return }
        settings.ziplineServerURL = trimmed
    }

    private func commitToken() {
        // A blur or Return on an untouched field must not clear a stored token: Clear is its own
        // button. Only a non-empty draft is ever a write.
        guard !tokenDraft.isEmpty else { return }
        do {
            try tokenStore.setToken(tokenDraft)
            tokenError = nil
        } catch {
            tokenError = Self.message(for: error)
        }
        // Cleared whether the write succeeded or failed: the field never echoes a token back
        // either way, so there is nothing to gain by leaving a failed attempt sitting in it.
        tokenDraft = ""
        refreshTokenStatus()
    }

    private func clearToken() {
        tokenDraft = ""
        do {
            try tokenStore.clearToken()
            tokenError = nil
        } catch {
            tokenError = Self.message(for: error)
        }
        refreshTokenStatus()
    }

    /// Reduces a Keychain read to the one bit this view is allowed to keep: whether a token
    /// exists. The string itself goes out of scope at the end of this line.
    private func refreshTokenStatus() {
        tokenIsStored = ((try? tokenStore.token()) ?? nil) != nil
    }

    /// `TokenStoreError` carries only an `OSStatus` — never the token — so every message this
    /// produces is safe to show. Nothing else in this view builds an error message at all.
    private static func message(for error: any Error) -> String {
        guard let tokenStoreError = error as? TokenStoreError else {
            return "Couldn't reach the Keychain."
        }
        switch tokenStoreError {
        case .keychain(let status):
            let detail = SecCopyErrorMessageString(status, nil) as String? ?? "status \(status)"
            return "Couldn't reach the Keychain (\(detail))."
        }
    }

    /// Parses as `http`/`https` with a non-empty host — nothing more. Deliberately **not**
    /// `MarkdownLink.isFetchable`: that guard exists to stop a transform from probing a network
    /// address that arrived in someone else's clipboard text, where a private-range host is
    /// suspicious. Here the address is the user's own server, typed by the user into their own
    /// settings — a private, LAN or Tailscale host is the ordinary case for a self-hosted
    /// Zipline, not an attack, and must not be rejected.
    private static func isHTTPURL(_ raw: String) -> Bool {
        guard let url = URL(string: raw), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", let host = url.host, !host.isEmpty else {
            return false
        }
        return true
    }
}
