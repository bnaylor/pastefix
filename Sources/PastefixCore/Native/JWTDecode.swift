import Foundation

enum JWTDecoder {
    /// Splits and base64url-decodes header and payload. nil unless there are exactly three
    /// dot-separated segments, the first two non-empty, and the header is a JSON object with "alg".
    static func split(_ text: String) -> (header: Data, payload: Data)? {
        let parts = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, !parts[0].isEmpty, !parts[1].isEmpty,
              let header = decodeSegment(parts[0]), let payload = decodeSegment(parts[1]),
              let obj = try? JSONSerialization.jsonObject(with: header) as? [String: Any], obj["alg"] != nil
        else { return nil }
        return (header, payload)
    }

    static func decodeSegment(_ s: Substring) -> Data? {
        guard s.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else { return nil }
        let std = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        return Data(base64Encoded: std + String(repeating: "=", count: (4 - std.count % 4) % 4))
    }
}

/// Shows a JWT's header and payload. Never verifies the signature and says so.
public struct JWTDecode: Transformer {
    public let id = "builtin.jwt.decode"
    public let name = "Decode JWT"
    public let requiresRichInput = false
    public let source: TransformerSource = .builtin
    public let applicableKinds: Set<ContentKind>? = [.jwt]
    public let category: String? = TransformCategory.data
    public init() {}

    public func apply(_ input: TransformInput) async throws -> String {
        guard let (h, p) = JWTDecoder.split(input.text),
              let header = try? JSONSerialization.jsonObject(with: h, options: [.fragmentsAllowed]),
              let payload = try? JSONSerialization.jsonObject(with: p, options: [.fragmentsAllowed])
        else { throw TransformError.invalidInput("Not a decodable JWT") }
        let json = try JSONReformat.render(["header": header, "payload": payload], pretty: true)
        var lines = [json]
        if let dict = payload as? [String: Any] {
            let fmt = ISO8601DateFormatter(); fmt.timeZone = TimeZone(identifier: "UTC")
            for key in ["exp", "iat", "nbf"] {
                guard let n = dict[key] as? NSNumber else { continue }
                let date = Date(timeIntervalSince1970: n.doubleValue)
                var line = "// \(key): \(fmt.string(from: date))"
                if key == "exp" { line += date < Date() ? " (expired)" : " (valid)" }
                lines.append(line)
            }
        }
        lines.append("// signature not verified")
        return lines.joined(separator: "\n")
    }
}
