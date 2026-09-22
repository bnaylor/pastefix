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
    /// overlay's "language" control is an extension control. Reuses the
    /// detector the panel already runs rather than introducing a language table.
    public static func defaultExtension(for text: String) -> String {
        let kinds = ContentDetector.detect(text)
        if kinds.contains(.json) { return "json" }
        if kinds.contains(.markdown) { return "md" }
        return "txt"
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
