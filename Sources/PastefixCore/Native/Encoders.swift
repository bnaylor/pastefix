import Foundation

public enum Codec: Sendable { case base64, url, html }

enum Base64Codec {
    static func encode(_ s: String) -> String { Data(s.utf8).base64EncodedString() }

    /// Lenient decode to text: ignores whitespace, accepts the url-safe alphabet, repairs
    /// padding. nil when it isn't Base64, decodes to invalid UTF-8, or contains NUL.
    static func decodeText(_ s: String) -> String? {
        let compact = s.filter { !$0.isWhitespace }
            .replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        var core = compact
        while core.hasSuffix("=") { core.removeLast() }
        guard !core.isEmpty, core.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "+" || $0 == "/" }), core.allSatisfy(\.isASCII) else { return nil }
        let padded = core + String(repeating: "=", count: (4 - core.count % 4) % 4)
        guard let data = Data(base64Encoded: padded), !data.contains(0), let text = String(data: data, encoding: .utf8) else { return nil }
        return text
    }

    /// Detection heuristic: ≥ 16 alphabet chars and decodes to printable text (tab/newline/CR allowed).
    static func looksLikeBase64(_ s: String) -> Bool {
        let compact = s.filter { !$0.isWhitespace }
        guard compact.count >= 16, let text = decodeText(compact) else { return false }
        return text.unicodeScalars.allSatisfy {
            $0 == "\t" || $0 == "\n" || $0 == "\r" || ($0.value >= 0x20 && $0.value != 0x7F && !(0x80...0x9F).contains($0.value))
        }
    }
}

enum URLCodec {
    static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
    // Every % must introduce two hex digits.
    private static let malformedPercentPattern = try! NSRegularExpression(pattern: "%(?![0-9A-Fa-f]{2})")
    static func encode(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: unreserved) ?? s }
    static func decode(_ s: String) throws -> String {
        if malformedPercentPattern.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)) != nil {
            throw TransformError.invalidInput("Malformed percent-encoding")
        }
        guard let out = s.removingPercentEncoding else { throw TransformError.invalidInput("Malformed percent-encoding") }
        return out
    }
}

enum HTMLCodec {
    static func encode(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for ch in s {
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&#39;"
            default: out.append(ch)
            }
        }
        return out
    }
}

public struct Encode: Transformer {
    public let codec: Codec
    public let id: String, name: String
    public let requiresRichInput = false
    public let source: TransformerSource = .builtin
    public let applicableKinds: Set<ContentKind>? = nil
    public let category: String? = TransformCategory.data
    public init(codec: Codec) {
        self.codec = codec
        switch codec {
        case .base64: id = "builtin.base64.encode"; name = "Base64 Encode"
        case .url:    id = "builtin.url.encode";    name = "URL Encode"
        case .html:   id = "builtin.html.encode";   name = "HTML Encode"
        }
    }
    public func apply(_ input: TransformInput) async throws -> String {
        switch codec {
        case .base64: return Base64Codec.encode(input.text)
        case .url: return URLCodec.encode(input.text)
        case .html: return HTMLCodec.encode(input.text)
        }
    }
}

public struct Decode: Transformer {
    public let codec: Codec
    public let id: String, name: String
    public let requiresRichInput = false
    public let source: TransformerSource = .builtin
    public let applicableKinds: Set<ContentKind>?
    public let category: String? = TransformCategory.data
    public init(codec: Codec) {
        self.codec = codec
        switch codec {
        case .base64: id = "builtin.base64.decode"; name = "Base64 Decode"; applicableKinds = [.base64]
        case .url:    id = "builtin.url.decode";    name = "URL Decode";    applicableKinds = [.percentEncoded]
        case .html:   id = "builtin.html.decode";   name = "HTML Decode";   applicableKinds = [.htmlEntities]
        }
    }
    public func apply(_ input: TransformInput) async throws -> String {
        switch codec {
        case .base64:
            guard let text = Base64Codec.decodeText(input.text) else { throw TransformError.invalidInput("Not valid Base64 text") }
            return text
        case .url: return try URLCodec.decode(input.text)
        case .html: return HTMLEntities.decode(input.text)
        }
    }
}
