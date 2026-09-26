import Foundation

/// The only place a Zipline v4 header spelling appears.
///
/// Verified against diced/zipline v4.7.0 (`src/lib/uploader/parseHeaders.ts`).
/// Note what is NOT here: `x-zipline-format` is the server's *filename* format,
/// not syntax highlighting, and `x-zipline-filename` is never sent — v4 runs
/// `decodeURIComponent` on it, and letting the server name the file avoids the
/// encoding question entirely.
public enum ZiplineV4Headers {
    // A fresh instance per call, not a cached static: ISO8601DateFormatter is
    // not Sendable, and this mapper is meant to be callable off the main actor
    // (the upload path runs alongside an uncapped scan). Matches the pattern
    // in JWTDecode.swift rather than introducing a locking wrapper for one date.
    private static func makeISO8601Formatter() -> ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone(secondsFromGMT: 0)
        return f
    }

    public static func headers(for upload: ZiplineUpload) -> [String: String] {
        var headers: [String: String] = [:]
        switch upload.expiry {
        case .never:
            // Explicit, not omitted: a server with its own default expiration
            // would otherwise apply it to something the user asked to keep.
            headers["x-zipline-deletes-at"] = "never"
        case .relative(let value):
            headers["x-zipline-deletes-at"] = value
        case .absolute(let date):
            headers["x-zipline-deletes-at"] = "date=" + makeISO8601Formatter().string(from: date)
        }
        if upload.burnOnRead { headers["x-zipline-max-views"] = "1" }
        // Sent verbatim, and deliberately neither re-normalised nor re-checked here: a
        // `ZiplineUpload` cannot exist holding an extension that is not already canonical
        // (`ZiplineFileExtension`), which is the one place that decides it. A header *value*
        // is framing — a CR LF in one splits the request's header block — so this must stay a
        // single choke point rather than two guards that can drift apart. Non-empty by the
        // same construction, so there is no "omit it" case left to write.
        headers["x-zipline-file-extension"] = upload.fileExtension
        return headers
    }
}
