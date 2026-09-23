import SwiftUI
import Security
import PastefixAppCore

/// The Upload tab: the Zipline server address, the API token, and the defaults ⌘⇧U opens with.
///
/// The token is the one piece of this tab's state that never reaches `SettingsStore`. It is
/// typed into a `SecureField`, written straight to `KeychainTokenStore` the moment it commits,
/// and the field is emptied again immediately afterwards — nothing here ever calls
/// `tokenStore.token()` to put the secret back on screen. Whether *something* is stored is shown
/// as a caption beside the buttons, and needs only a `Bool` out of the Keychain, never the string
/// itself — the field's own placeholder says what to type, not what is held. `SettingsStore`'s own
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
    /// Whether *a* token is stored — never the token itself. Starts `false` and is corrected in
    /// `onAppear` rather than in `init`: `init` runs on every re-render of this struct (every
    /// keystroke in *this tab's own* extension field included, since `settings` is `@ObservedObject`
    /// and any of its publishes re-renders the whole tab), so a Keychain read there would fire far
    /// more often than the tab is actually opened. `onAppear` fires once per appearance instead.
    @State private var tokenIsStored = false
    /// A Keychain failure's message. `TokenStoreError` carries only an `OSStatus`, never the
    /// token, so this is always safe to render — see `message(for:)`.
    @State private var tokenError: String?
    @FocusState private var focus: Field?

    private enum Field: Hashable { case serverURL, token }

    init(settings: SettingsStore, tokenStore: any ZiplineTokenStore = KeychainTokenStore()) {
        _settings = ObservedObject(wrappedValue: settings)
        self.tokenStore = tokenStore
        _serverURLDraft = State(initialValue: settings.ziplineServerURL)
    }

    var body: some View {
        Form {
            Section("Zipline Server") {
                // Label above, field full width. The example is the `prompt:` — a real
                // placeholder, so it is greyed out, sits *in* the field, and disappears the
                // moment there is a value. Passed as the label instead (as it was) it renders in
                // the Form's leading gutter and stays there for ever, so a configured server read
                // as "https://your.zipline.instance   https://real.host" side by side.
                VStack(alignment: .leading, spacing: 4) {
                    Text("Server URL").font(.caption).foregroundStyle(.secondary)
                    TextField("Server URL",
                              text: $serverURLDraft,
                              prompt: Text(verbatim: "https://your.zipline.instance"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .focused($focus, equals: .serverURL)
                        .onSubmit { commitServerURL() }
                    if let message = serverURLValidationMessage {
                        Text(message).font(.caption).foregroundStyle(.orange)
                    }
                }
                // One field with its buttons underneath, rather than a field with an inline Set
                // and a Clear stranded on a separate row below a status line — two rows that
                // looked like two unrelated controls. The status moves to the caption on the
                // button row, where it is still visible and is no longer doing double duty as the
                // field's placeholder.
                //
                // The placeholder says what to type, never what is stored: this view never reads
                // a token back out of the Keychain (`refreshTokenStatus` keeps only the Bool), so
                // there is nothing here that could echo the secret even by accident.
                VStack(alignment: .leading, spacing: 6) {
                    Text("API Token").font(.caption).foregroundStyle(.secondary)
                    SecureField("API Token",
                                text: $tokenDraft,
                                prompt: Text(tokenIsStored ? "Enter a new token to replace the stored one"
                                                           : "Paste your Zipline API token"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .focused($focus, equals: .token)
                        .onSubmit { commitToken() }
                    HStack(spacing: 8) {
                        // Submit and blur/teardown commit implicitly (see `onChange(of: focus)`
                        // and `onDisappear` below), but neither covers ⌘Q: SwiftUI does not
                        // reliably run an open window's `onDisappear` on process termination, so
                        // a token typed and never submitted before quitting would be silently
                        // lost — not leaked, just gone, and gone silently is the wrong failure
                        // mode for something the user just typed. The button makes the draft's
                        // uncommitted state visible instead of implicit, which is also just the
                        // normal shape for committing a credential.
                        Button("Set Token") { commitToken() }
                            .disabled(tokenDraft.isEmpty)
                        Button("Clear Token") { clearToken() }
                            .disabled(!tokenIsStored && tokenDraft.isEmpty)
                        Spacer()
                        // Two text buttons and a short caption, not four buttons: a 460pt
                        // settings pane does not hold four (AGENTS.md, Plan 7).
                        Text(tokenIsStored ? "Stored in the Keychain" : "No token stored")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let tokenError {
                        Text(tokenError).font(.caption).foregroundStyle(.red)
                    }
                }
                // App Transport Security decides which of these actually work over plain `http`,
                // and it is not the same set the previous wording promised. Measured on
                // macOS 26.3.1 against a signed app bundle: http to an IP literal (192.168.x,
                // 10.x, a Tailscale 100.x, 127.0.0.1) and to a `.local` name is permitted by the
                // stock default; http to a dotted public-looking FQDN is refused with -1022 —
                // and a MagicDNS name, `box.tailnet.ts.net`, is exactly that shape. Adding
                // `NSAllowsLocalNetworking` (see Info.plist) does not change that verdict.
                //
                // So the caption tells the truth about which addresses work unencrypted rather
                // than sending someone to configure everything and discover it at Upload. The
                // remedy for the MagicDNS case is `https`, which Tailscale issues a real
                // certificate for — and this feature has no cert-trust bypass, so it must be a
                // real one.
                Text("The API token lives in the Keychain, never in Settings. Private and LAN addresses are expected here — that's the normal way to reach a self-hosted Zipline. Plain http works for an IP address (a Tailscale 100.x one included) and for a .local name; a named host such as box.tailnet.ts.net needs https, which Tailscale can issue a certificate for.")
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
        .onAppear { refreshTokenStatus() }
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
        guard !trimmed.isEmpty, ZiplineServerURL.parse(trimmed) == nil else { return nil }
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
}
