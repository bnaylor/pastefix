import Foundation

/// Folds characters that look like ASCII into that ASCII, for `SecretDetector`'s scan input only
/// (#102).
///
/// OCR reads a credential's Latin characters as lookalikes — Cyrillic `А В Е Т`, `Ø` for `0`, `×`
/// for `x`, an em-dash for a hyphen (the owner's #19 capture: one of eight planted secrets missed,
/// on a homoglyph) — and a pasted homoglyph is the same trick by hand. The fold never touches the
/// text itself: folding real non-Latin text would corrupt it, so the scanner matches on the folded
/// copy and reports ranges into the original.
///
/// **Length-preserving in UTF-16, by construction.** Every entry maps one BMP code unit to one
/// ASCII code unit, and every other unit (surrogates included) is copied as is, so an `NSRange`
/// found in the folded copy is the same characters' range in the original, and Redact replaces
/// what is actually there. Keep it that way: an entry that expands (`ﬁ` → `fi`) or a skeleton
/// that is not a single ASCII character needs an offset map, which this deliberately avoids.
///
/// The table is the subset of Unicode's `confusables.txt` whose skeleton is one ASCII letter, digit
/// or rule punctuation (`-`, `_`, `=`, `:`), restricted to scripts and symbols OCR and paste
/// actually produce. A digit/letter swap within ASCII (`x0xb-` for `xoxb-`) is not a confusable:
/// folding `0` to `o` would break every real digit, so that stays a miss.
enum Confusables {
    static func fold(_ text: String) -> String {
        // All-ASCII text has nothing to fold, and it is the common case.
        guard text.utf8.count != text.utf16.count else { return text }
        var units = Array(text.utf16)
        var changed = false
        for i in units.indices where units[i] >= 0x80 {
            if let ascii = ascii(for: units[i]) { units[i] = ascii; changed = true }
        }
        return changed ? String(decoding: units, as: UTF16.self) : text
    }

    private static func ascii(for unit: UInt16) -> UInt16? {
        // Fullwidth forms: U+FF01…U+FF5E are ASCII 0x21…0x7E, in order.
        if (0xFF01...0xFF5E).contains(unit) { return unit - 0xFEE0 }
        return table[unit]
    }

    private static let table: [UInt16: UInt16] = {
        let pairs: [(Unicode.Scalar, Character)] = [
            // Cyrillic
            ("А", "A"), ("В", "B"), ("С", "C"), ("Е", "E"), ("Н", "H"), ("І", "I"), ("Ј", "J"),
            ("К", "K"), ("М", "M"), ("О", "O"), ("Р", "P"), ("Ѕ", "S"), ("Т", "T"), ("Х", "X"),
            ("У", "Y"), ("Ү", "Y"), ("З", "3"),
            ("а", "a"), ("с", "c"), ("е", "e"), ("һ", "h"), ("і", "i"), ("ј", "j"), ("ӏ", "l"),
            ("о", "o"), ("р", "p"), ("ԛ", "q"), ("ѕ", "s"), ("ԝ", "w"), ("х", "x"), ("у", "y"),
            // Greek
            ("Α", "A"), ("Β", "B"), ("Ε", "E"), ("Ζ", "Z"), ("Η", "H"), ("Ι", "I"), ("Κ", "K"),
            ("Μ", "M"), ("Ν", "N"), ("Ο", "O"), ("Ρ", "P"), ("Τ", "T"), ("Υ", "Y"), ("Χ", "X"),
            ("α", "a"), ("ο", "o"), ("ρ", "p"), ("ν", "v"),
            // Latin-1 and symbols OCR substitutes
            ("Ø", "0"), ("×", "x"),
            // Dashes and minus signs
            ("\u{2010}", "-"), ("\u{2011}", "-"), ("\u{2012}", "-"), ("\u{2013}", "-"),
            ("\u{2014}", "-"), ("\u{2015}", "-"), ("\u{2212}", "-"), ("\u{FE58}", "-"),
            ("\u{FE63}", "-"),
            // Colon lookalikes
            ("\u{2236}", ":"), ("\u{0589}", ":"), ("\u{FE13}", ":"),
        ]
        var out: [UInt16: UInt16] = [:]
        for (from, to) in pairs {
            precondition(from.value <= 0xFFFF && !(0xD800...0xDFFF).contains(from.value) && to.isASCII,
                         "Confusables must stay one BMP unit → one ASCII unit (see the type)")
            out[UInt16(from.value)] = UInt16(to.asciiValue!)
        }
        return out
    }()
}
