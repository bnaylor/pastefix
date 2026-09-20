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
            let candidate = original.contains("://") ? String(original) : "http://" + original
            // Prefer NSDataDetector's own resolved URL: it already carries the correct
            // scheme for bare hosts (www.example.com -> http://www.example.com) and,
            // crucially, for non-http matches (mailto:, ftp:) whose original text lacks
            // "://" and would otherwise be misparsed as an http(s) URL by `candidate`.
            guard let url = match.url ?? URL(string: candidate),
                  let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https"
            else { continue }
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
