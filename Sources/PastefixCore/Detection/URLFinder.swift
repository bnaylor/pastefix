import Foundation

/// An http(s) link located in a string. `original` is the text as written (may lack a
/// scheme, e.g. `www.example.com`); `url` always has one.
struct FoundURL {
    let range: Range<String.Index>
    let url: URL
    let original: Substring
}

/// The one shared way the engine finds links: NSDataDetector, http/https only, with
/// trailing sentence punctuation excluded so "see https://a.b/c." keeps its full stop.
enum URLFinder {
    /// NSDataDetector costs ~1.75 s per MB (issue #28) and runs from detection, `URLCleaner`
    /// and `MarkdownLink`; bounding it here bounds all three. Matches `SecretDetector.maxBytes`.
    static let maxBytes = 262_144
    private static let detector = try! NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    /// Empty over `maxBytes`. Stops early when the calling task is cancelled — the partial list
    /// is only ever seen by a caller about to discard it.
    static func find(in text: String) -> [FoundURL] {
        guard text.utf8.count <= maxBytes else { return [] }
        let ns = text as NSString
        var out: [FoundURL] = []
        // `.reportProgress` has the block called during long attempts, not only on matches, so
        // cancellation is observable mid-scan (the Plan 12 lesson, applied to the detector).
        detector.enumerateMatches(in: text, options: [.reportProgress], range: NSRange(location: 0, length: ns.length)) { match, _, stop in
            if Task.isCancelled { stop.pointee = true; return }
            guard let match, var range = Range(match.range, in: text) else { return }
            while range.lowerBound < range.upperBound,
                  shouldTrim(text[text.index(before: range.upperBound)], in: text[range]) {
                range = range.lowerBound..<text.index(before: range.upperBound)
            }
            let original = text[range]
            guard !original.isEmpty else { return }
            // Scheme comes from the detector: only it knows that a "://"-free match is a
            // mailto address rather than a bare host.
            guard let detected = match.url,
                  let scheme = detected.scheme?.lowercased(), scheme == "http" || scheme == "https"
            else { return }
            // The URL must describe the trimmed range, not the detector's untrimmed match:
            // callers replace `range` with a rewrite of `url`.
            let candidate = original.contains("://") ? String(original) : scheme + "://" + original
            guard let url = URL(string: candidate) else { return }
            out.append(FoundURL(range: range, url: url, original: original))
        }
        return out
    }

    private static func shouldTrim(_ last: Character, in s: Substring) -> Bool {
        switch last {
        case ".", ",", ";", ":", "!", "?", "'", "\"": return true
        case ")": return s.filter { $0 == "(" }.count < s.filter { $0 == ")" }.count
        default: return false
        }
    }
}
