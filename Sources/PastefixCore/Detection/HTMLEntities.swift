import Foundation

/// Shared HTML entity decoder (used by HTML Decode and by the Markdown-link title parser).
enum HTMLEntities {
    static func decode(_ s: String) -> String {
        var out = s
        // Numeric references first so "&amp;#39;"-style double-encoding isn't mis-decoded.
        for (pattern, radix) in [("&#[xX]([0-9A-Fa-f]+);", 16), ("&#([0-9]+);", 10)] {
            guard let re = try? NSRegularExpression(pattern: pattern) else { continue }
            let ns = out as NSString
            // Splice on an NSMutableString, indexed by the same UTF-16 offsets the regex reports.
            // Converting each NSRange to a String.Index range instead is O(offset) per match, i.e.
            // quadratic in the buffer: a 1 MB paste of numeric references took ~25 s.
            let ms = NSMutableString(string: out)
            for m in re.matches(in: out, range: NSRange(location: 0, length: ns.length)).reversed() {
                let digits = ns.substring(with: m.range(at: 1))
                guard let code = UInt32(digits, radix: radix), let scalar = Unicode.Scalar(code),
                      !isDisallowedControl(scalar) else { continue }
                ms.replaceCharacters(in: m.range, with: String(Character(scalar)))
            }
            out = ms as String
        }
        // Named references in a fixed order with "&amp;" LAST so "&amp;lt;" → "&lt;".
        for (name, value) in named { out = out.replacingOccurrences(of: "&\(name);", with: value) }
        return out
    }

    /// C0 controls other than tab/LF/CR are left as entity text: decoding "&#0;" would splice a
    /// NUL into the buffer, which truncates the value for anything downstream that speaks C
    /// strings, and the rest of the range is invisible rather than useful.
    private static func isDisallowedControl(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value < 0x20 && scalar != "\t" && scalar != "\n" && scalar != "\r"
    }

    /// HTML4 Latin-1 (U+00A0…U+00FF, in code-point order), common typographic names, then the
    /// five XML names with amp last.
    private static let named: [(String, String)] = {
        let latin1 = ["nbsp","iexcl","cent","pound","curren","yen","brvbar","sect","uml","copy","ordf","laquo","not","shy","reg","macr",
                      "deg","plusmn","sup2","sup3","acute","micro","para","middot","cedil","sup1","ordm","raquo","frac14","frac12","frac34","iquest",
                      "Agrave","Aacute","Acirc","Atilde","Auml","Aring","AElig","Ccedil","Egrave","Eacute","Ecirc","Euml","Igrave","Iacute","Icirc","Iuml",
                      "ETH","Ntilde","Ograve","Oacute","Ocirc","Otilde","Ouml","times","Oslash","Ugrave","Uacute","Ucirc","Uuml","Yacute","THORN","szlig",
                      "agrave","aacute","acirc","atilde","auml","aring","aelig","ccedil","egrave","eacute","ecirc","euml","igrave","iacute","icirc","iuml",
                      "eth","ntilde","ograve","oacute","ocirc","otilde","ouml","divide","oslash","ugrave","uacute","ucirc","uuml","yacute","thorn","yuml"]
        var table: [(String, String)] = latin1.enumerated().map { ($1, String(Character(Unicode.Scalar(0xA0 + UInt32($0))!))) }
        table += [("mdash","—"),("ndash","–"),("hellip","…"),("lsquo","‘"),("rsquo","’"),("ldquo","“"),("rdquo","”"),
                  ("bull","•"),("trade","™"),("euro","€"),("lt","<"),("gt",">"),("quot","\""),("apos","'")]
        table.append(("amp", "&"))
        return table
    }()
}
