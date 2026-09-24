import Foundation

/// Removes tracking query parameters from every http(s) URL in the buffer.
/// Text outside URLs, and URLs with nothing to remove, are left byte-for-byte.
public struct URLCleaner: Transformer {
    public let id = "builtin.urlclean"
    public let name = "Clean URL Tracking"
    public let requiresRichInput = false
    public let source: TransformerSource = .builtin
    public let applicableKinds: Set<ContentKind>? = [.url]
    public let category: String? = TransformCategory.urls
    public var maxInputBytes: Int { URLFinder.maxBytes }

    public init() {}

    public func apply(_ input: TransformInput) async throws -> String {
        Self.clean(input.text)
    }

    static let trackingNames: Set<String> = [
        "fbclid", "gclid", "dclid", "gbraid", "wbraid", "igshid", "si", "mc_cid", "mc_eid",
        "ref", "ref_src", "_hsenc", "_hsmi", "yclid", "vero_id", "mkt_tok", "oly_anon_id", "oly_enc_id",
    ]

    static func isTracking(_ name: String) -> Bool {
        let n = name.lowercased()
        return n.hasPrefix("utm_") || trackingNames.contains(n)
    }

    /// nil when the URL has no tracking parameters (caller keeps the original text).
    static func cleanURL(_ url: URL) -> URL? {
        guard var comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let rawQuery = comps.percentEncodedQuery, !rawQuery.isEmpty else { return nil }
        // Links copied out of HTML/email often carry the entity-escaped "&amp;" separator
        // instead of a literal "&"; treat that escaping itself as part of what cleaning removes.
        let hadEscapedAmpersand = rawQuery.contains("&amp;")
        if hadEscapedAmpersand {
            comps.percentEncodedQuery = rawQuery.replacingOccurrences(of: "&amp;", with: "&")
        }
        guard let items = comps.percentEncodedQueryItems, !items.isEmpty else { return nil }
        let kept = items.filter { !isTracking($0.name.removingPercentEncoding ?? $0.name) }
        guard hadEscapedAmpersand || kept.count != items.count else { return nil }
        comps.percentEncodedQueryItems = kept.isEmpty ? nil : kept
        return comps.url
    }

    static func clean(_ text: String) -> String {
        var out = text
        for found in URLFinder.find(in: text).reversed() {
            guard let cleaned = cleanURL(found.url) else { continue }
            var replacement = cleaned.absoluteString
            if !found.original.contains("://"), let schemeEnd = replacement.range(of: "://") {
                replacement = String(replacement[schemeEnd.upperBound...])   // keep the bare-www form
            }
            out.replaceSubrange(found.range, with: replacement)
        }
        return out
    }
}
