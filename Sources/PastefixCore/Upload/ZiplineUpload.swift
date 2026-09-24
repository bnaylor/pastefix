import Foundation

/// One text upload, as the caller describes it. Deliberately free of any
/// Zipline header spelling: `ZiplineV4Headers` owns that, so a future v5 is a
/// sibling mapper rather than a rewrite of everything that builds a request.
public struct ZiplineUpload: Sendable, Equatable {
    public var text: String
    /// Without a leading dot; the mapper strips one if it is there anyway.
    public var fileExtension: String
    public var expiry: ZiplineExpiry
    public var burnOnRead: Bool

    public init(text: String, fileExtension: String, expiry: ZiplineExpiry, burnOnRead: Bool) {
        self.text = text
        self.fileExtension = fileExtension
        self.expiry = expiry
        self.burnOnRead = burnOnRead
    }

    /// Zipline v4 picks syntax highlighting from the file extension, so the
    /// overlay's "language" control is an extension control. Takes the kinds the
    /// caller already has rather than text, so the one place that decides this is
    /// also the place that runs on the hot path — the overlay holds
    /// `PasteDocument.detectedKinds` and must not pay a second `ContentDetector`
    /// pass (a capped secret scan included) to ask this question.
    ///
    /// **`json` or `txt`, and nothing else.** Markdown used to be in here and was
    /// removed: `MarkdownDetector` answers yes on two weak signals, and a 427 KB
    /// file of fortunes — 391 lines opening `- `, 125 opening `> `, not one
    /// heading or fence — uploaded as `.md`. The asymmetry is the argument. `.md`
    /// against `.txt` changes almost nothing about how Zipline renders a paste,
    /// while a wrong `.md` on ordinary prose is visible and wrong; JSON is worth
    /// highlighting and is the one kind detected by actually parsing the thing.
    /// `MarkdownDetector` is deliberately left alone — it still drives the
    /// Detected badge and palette ordering, where a generous guess costs nothing.
    ///
    /// nil kinds (no document) means "nothing detected", not "detect it for me".
    public static func defaultExtension(for kinds: Set<ContentKind>?) -> String {
        guard let kinds, kinds.contains(.json) else { return "txt" }
        return "json"
    }

    /// What the upload overlay's "File type" field should hold, or nil for "leave it exactly as
    /// it is".
    ///
    /// One function because the question is asked twice, and the two answers have to agree.
    /// Detection is off the main actor (`DetectionScheduler`), so `PasteDocument.detectedKinds`
    /// is `[]` at the instant the overlay is constructed — ⌘⇧U re-snapshots the clipboard
    /// immediately before the overlay appears, which restarts detection — and the real kinds
    /// arrive a moment later. Seeding only in `init` therefore defaulted *every* JSON upload to
    /// `txt`. The overlay asks again when detection completes, with the same rule and the kinds
    /// filled in.
    ///
    /// The precedence is deliberate and is the one thing not to invert:
    ///
    /// 1. **A hand-typed value always wins.** `userHasEditedField` is the only nil case, and it
    ///    is what stops a detection result landing a second after someone typed `yml` from
    ///    overwriting it. A control the user has touched is theirs.
    /// 2. **Then the user's `ziplineDefaultExtension` setting**, whenever they have set one —
    ///    i.e. anything but empty or the `txt` default. This lost to the detector once and was
    ///    reversed: `MarkdownDetector` fires on a single `^#{1,6} \S` line, so YAML files,
    ///    Dockerfiles and conf files were uploaded as `md` over an explicit choice. (`md` is no
    ///    longer in `defaultExtension` either — see its comment — but the ordering is the part
    ///    that has to hold regardless of what the detector can currently answer.)
    /// 3. **Then the detector**, which fills in only when the user has expressed no preference
    ///    at all.
    ///
    /// Idempotent by construction: when the setting wins, every later call returns that same
    /// setting, so a completed detection re-asking the question cannot move the field.
    public static func extensionSeed(setting: String,
                                     detectedKinds: Set<ContentKind>?,
                                     userHasEditedField: Bool) -> String? {
        guard !userHasEditedField else { return nil }
        let configured = setting.trimmingCharacters(in: .whitespacesAndNewlines)
        if !configured.isEmpty, configured != "txt" { return configured }
        return defaultExtension(for: detectedKinds)
    }
}

public enum ZiplineExpiry: Sendable, Equatable {
    case never
    /// A human string v4's `humanTime` accepts: "1h", "1d", "7d".
    case relative(String)
    case absolute(Date)
}

/// Whether a found secret is removed from the uploaded copy or sent anyway.
public enum SecretDisposition: Sendable, Equatable {
    case redact
    case sendAsIs
}

/// The single place that decides which bytes leave the machine.
///
/// It takes the source and returns a new string: nothing here can rewrite the
/// user's document or clipboard, which is the property the overlay depends on.
public enum UploadPayload {
    public static func text(_ source: String,
                            matches: [SecretMatch],
                            disposition: SecretDisposition) -> String {
        guard disposition == .redact, !matches.isEmpty else { return source }
        return SecretRedactor.redact(source, matches: matches)
    }
}

public enum ZiplineUploadError: Error, Equatable {
    case unauthorized
    /// Zipline's ApiError 1001 — the user picked an option the server refuses
    /// (most often an expiry beyond its `maxExpiration`), so it is fixable in
    /// the overlay rather than fatal.
    case badOption(header: String, message: String)
    case server(status: Int, message: String?)
    /// A 2xx whose body did not yield `files[0].url`. Never treated as success.
    case malformedResponse
    case transport(String)
}
