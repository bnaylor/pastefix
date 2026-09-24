import Foundation

/// One text upload, as the caller describes it. Deliberately free of any
/// Zipline header spelling: `ZiplineV4Headers` owns that, so a future v5 is a
/// sibling mapper rather than a rewrite of everything that builds a request.
///
/// **This type is the choke point for the file extension**, because the extension is the
/// only free-text field on this path whose value reaches protocol framing: it is
/// interpolated into the multipart part's `Content-Disposition` filename *and* sent as the
/// `x-zipline-file-extension` header value. `init` therefore refuses anything
/// `ZiplineFileExtension.canonical(_:)` will not accept, and `fileExtension` is a `let`, so
/// no code path can hold a `ZiplineUpload` whose extension is unsendable — the two framing
/// sites (`ZiplineV4Headers.headers(for:)` and `URLSessionZiplineClient.multipartBody`)
/// consequently do not re-check or re-normalise it, and must not start.
///
/// The check lives here rather than in the client because the client owns only one of those
/// two sites: `ZiplineV4Headers` is public API with its own tests, and validating inside
/// `upload(_:to:token:)` would leave it free to emit a header value with a CR LF in it.
public struct ZiplineUpload: Sendable, Equatable {
    public var text: String
    /// Canonical by construction: lowercase, no leading dot, `[a-z0-9._+-]{1,16}`. A `let`,
    /// and validated only in `init`, which is what makes that a property of the type rather
    /// than a habit of its callers.
    public let fileExtension: String
    public var expiry: ZiplineExpiry
    public var burnOnRead: Bool

    /// Throws `ZiplineUploadError.invalidFileExtension` for an extension that cannot be
    /// framed. Nothing is sent and nothing is substituted: a value the user typed is either
    /// what goes on the wire or it is reported back to them (see `ZiplineFileExtension`).
    public init(text: String, fileExtension: String, expiry: ZiplineExpiry, burnOnRead: Bool) throws {
        guard let ext = ZiplineFileExtension.canonical(fileExtension) else {
            throw ZiplineUploadError.invalidFileExtension
        }
        self.text = text
        self.fileExtension = ext
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
    /// **`json` or `txt`, and nothing else.** This function never reads
    /// `.markdown`, so nothing about `MarkdownDetector` can move its answer.
    ///
    /// Markdown used to be in here and was removed over a 427 KB file of fortunes
    /// — 391 lines opening `- `, 125 opening `> `, not one heading or fence —
    /// which the then presence-only weak-signal rule called Markdown, so it
    /// uploaded as `.md`. #50 has since fixed that at the source: weak signals now
    /// need 10% density, and that file's ~4% and ~1% no longer qualify. Markdown
    /// still does not belong here, and the reason was never only that one file:
    /// the asymmetry is the argument. `.md` against `.txt` changes almost nothing
    /// about how Zipline renders a paste, while a wrong `.md` on ordinary prose is
    /// visible and wrong — and a single `^#{1,6} \S` line is still decisive on its
    /// own, so a shell-comment-heavy config is still one heading away from `.md`.
    /// JSON is worth highlighting and is the one kind detected by actually parsing
    /// the thing. `MarkdownDetector` keeps driving the Detected badge and palette
    /// ordering, where a generous guess costs nothing.
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

/// What a Zipline file extension is allowed to be, and the one function that decides it.
///
/// The extension is not cosmetic: `URLSessionZiplineClient` interpolates it into
/// `Content-Disposition: form-data; name="file"; filename="paste.<ext>"` and
/// `ZiplineV4Headers` sends it as an HTTP header value. Both are *framing*, not payload —
/// a `"` ends the quoted filename early, a CR LF in either position injects a new header
/// into the multipart block or the request's own header block, and `/`, `;` or a space
/// corrupt the part in quieter ways. It was the only free-text field on this path with no
/// constraint at all beyond a whitespace trim and a leading-dot strip.
///
/// **Refused, never sanitised.** A silent substitution here would upload a file named
/// something other than what the field said, on the one surface in this app whose whole job
/// is letting someone check what is about to leave their machine — the same argument that
/// makes an unscanned buffer "refused" rather than "clean" (Critical Invariant 13). The
/// overlay and the Upload settings tab both show `requirement` inline for a rejected value,
/// and the overlay's Upload button stays disabled while one is in the field.
///
/// Canonicalising *is* allowed, and is deliberately limited to three things that cannot
/// change which file the server produces: a whitespace trim, leading dots (`.swift` and
/// `swift` name the same type — Zipline wants it without the dot), and lowercasing (a Zipline
/// extension is matched case-insensitively for highlighting, and `TXT` vs `txt` is not a
/// distinction worth refusing over).
public enum ZiplineFileExtension {
    /// Long enough for the real compound cases (`tar.gz`, `sqlite3`, `dockerfile`); short
    /// enough that a paste into the field is a refusal rather than a 400-character filename.
    public static let maxLength = 16

    /// Shown inline by both call sites. States the rule rather than echoing the rejected
    /// value back: the rejected value is exactly the thing that might carry a CR LF.
    public static let requirement =
        "Use letters, digits, dot, dash, plus or underscore — at most \(maxLength) characters."

    /// The canonical form, or nil when `raw` is not a usable extension.
    ///
    /// Empty is nil, not `txt`: "no preference" is a question for the UI layer that owns the
    /// field (it seeds `txt` into a blank one), and answering it here would turn every
    /// rejected value into a silent `paste.txt`.
    public static func canonical(_ raw: String) -> String? {
        var ext = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while ext.hasPrefix(".") { ext.removeFirst() }
        // Lowercased before the character check, not after, so the check is the thing that
        // decides — a case-folding that produced a disallowed scalar could not slip past it.
        ext = ext.lowercased()
        guard !ext.isEmpty, ext.count <= maxLength, ext.allSatisfy(isAllowed) else { return nil }
        return ext
    }

    /// ASCII only, by asking for the ASCII value first: `allSatisfy` over a Swift `Character`
    /// would otherwise let a grapheme cluster whose first scalar is `a` through, and a
    /// non-ASCII byte in a header value is its own problem.
    private static func isAllowed(_ character: Character) -> Bool {
        guard let ascii = character.asciiValue else { return false }
        switch ascii {
        case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "0")...UInt8(ascii: "9"):
            return true
        default:
            return character == "." || character == "_" || character == "+" || character == "-"
        }
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
    /// Refused by `ZiplineUpload.init` before anything was sent: the "File type" field held
    /// something that cannot go into a `Content-Disposition` filename or an HTTP header value.
    /// Carries no payload on purpose — the rejected string is untrusted framing bytes, and
    /// `ZiplineFileExtension.requirement` is what a user needs to read instead.
    case invalidFileExtension
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
