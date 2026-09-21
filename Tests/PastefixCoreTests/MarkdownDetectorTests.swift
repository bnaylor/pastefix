import Testing
@testable import PastefixCore

@Suite struct MarkdownDetectorTests {
    @Test(arguments: [
        "# Title\nbody", "text\n\n```swift\nlet x = 1\n```", "- one\n- two\nsee [docs](https://x.y)",
        "> quoted\nand **strong**", "| a | b |\n|---|---|\n| 1 | 2 |\nwith `code`", "1. first\n2. second\n\n> note",
        // CRLF: Swift reads "\r\n" as one Character, so the split has to normalize first.
        "body\r\n# Title\r\n", "- a\r\n- b\r\n> q",
    ])
    func positives(_ s: String) { #expect(MarkdownDetector.looksLikeMarkdown(s)) }

    @Test(arguments: [
        "Just a sentence with a * star * in it.", "https://example.com/path", "a * b * c = d", "{\"k\": [1,2]}",
        "- a single list line", "Call me **maybe**", "email me at a@b.co\nthanks", "",
    ])
    func negatives(_ s: String) { #expect(!MarkdownDetector.looksLikeMarkdown(s)) }

    @Test func scanIsBounded() {
        let big = String(repeating: "plain line\n", count: 100_000) + "# heading far below the cap\n"
        #expect(!MarkdownDetector.looksLikeMarkdown(big))   // heading is beyond 64 KB / 400 lines
    }
}
