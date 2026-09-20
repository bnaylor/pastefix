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
    private static let detector = try! NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    static func find(in text: String) -> [FoundURL] {
        let ns = text as NSString
        var out: [FoundURL] = []
        for match in detector.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            guard var range = Range(match.range, in: text) else { continue }
            while range.lowerBound < range.upperBound,
                  shouldTrim(text[text.index(before: range.upperBound)], in: text[range]) {
                range = range.lowerBound..<text.index(before: range.upperBound)
            }
            let original = text[range]
            guard !original.isEmpty else { continue }
            // Scheme comes from the detector: only it knows that a "://"-free match is a
            // mailto address rather than a bare host.
            guard let detected = match.url,
                  let scheme = detected.scheme?.lowercased(), scheme == "http" || scheme == "https"
            else { continue }
            // The URL must describe the trimmed range, not the detector's untrimmed match:
            // callers replace `range` with a rewrite of `url`.
            let candidate = original.contains("://") ? String(original) : scheme + "://" + original
            guard let url = URL(string: candidate) else { continue }
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
