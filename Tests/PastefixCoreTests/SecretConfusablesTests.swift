import Testing
@testable import PastefixCore

/// #102: OCR reads Latin characters as lookalikes (Cyrillic А В Е Т, `Ø` for `0`, `×` for `x`,
/// an em-dash for a hyphen), and a credential read that way scanned clean. The scanner folds its
/// *input*; the text, and every range it reports, stay the original.
@Suite struct SecretConfusablesTests {
    func texts(_ s: String) -> [String] { SecretDetector.scan(s).map { String(s[$0.range]) } }

    @Test func cyrillicLettersInAnAWSKey() {
        let key = "\u{0410}KI\u{0410}IOSFODNN7EX\u{0410}MPLE"   // Cyrillic А ×3
        #expect(SecretDetector.scan("key \(key) here").map(\.kind) == [.awsAccessKey])
        #expect(texts("key \(key) here") == [key], "the range is the original characters")
    }

    @Test func dashesInASlackToken() {
        let token = "xoxb\u{2014}1234567890\u{2013}abcdefghij"   // em-dash, en-dash
        #expect(texts("t \(token)") == [token])
    }

    @Test func emDashesInAPrivateKeyHeader() {
        let dashes = String(repeating: "\u{2014}", count: 5)
        let pem = "\(dashes)BEGIN RSA PRIVATE KEY\(dashes)\nMIIEow\n\(dashes)END RSA PRIVATE KEY\(dashes)"
        #expect(texts(pem) == [pem])
    }

    @Test func greekAndFullwidth() {
        let key = "\u{0391}KIA\u{FF29}OSFODNN7EXAMPLE"   // Greek Α, fullwidth Ｉ
        #expect(texts(key) == [key])
    }

    @Test func slashedZeroAndMultiplicationSign() {
        let token = "\u{00D7}oxb-12345678\u{00D8}0-abcdefghij"   // ×, Ø
        #expect(texts(token) == [token])
    }

    /// The fold keeps UTF-16 offsets, so a range after an astral character (two code units) and
    /// after a folded one still lands on the secret.
    @Test func rangesAfterAstralAndFoldedCharacters() {
        let key = "AKIAIOSFODNN7EXAMPLE"
        let s = "😀 \u{0410}б \(key)"
        #expect(texts(s) == [key])
    }

    @Test func redactionReplacesTheOriginalCharacters() {
        let key = "\u{0410}KIAIOSFODNN7EXAMPLE"
        let s = "key \(key) here"
        #expect(SecretRedactor.redact(s, matches: SecretDetector.scan(s)) == "key [REDACTED aws-access-key] here")
    }

    @Test func ordinaryRussianIsNotASecret() {
        #expect(SecretDetector.scan("Привет, это обычный текст. АВС ЕКМ НОР СТХ ауео рсух").isEmpty)
    }

    @Test func foldIsLengthPreservingInUTF16() {
        let s = "\u{0410}\u{2014}\u{FF21}😀é\u{00D8}"
        #expect(Confusables.fold(s).utf16.count == s.utf16.count)
        #expect(Confusables.fold(s) == "A-A😀é0")
        #expect(Confusables.fold("plain ascii") == "plain ascii")
    }
}
