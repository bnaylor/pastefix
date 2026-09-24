import Testing
@testable import PastefixCore

@Suite struct MarkdownDetectorTests {
    // Signal density (#50): a signal counts when its lines are >= 10% of the non-empty lines, a
    // proportion rather than an absolute minimum, so short snippets with one link or one bold
    // line next to a list or quote stay Markdown while long prose with stray dashes does not.
    @Test(arguments: [
        "# Title\nbody", "text\n\n```swift\nlet x = 1\n```",
        "- one [docs](https://x.y)\n- two [more](https://x.y)", "- one\n- two\nsee [docs](https://x.y)",
        "> quoted\n> more\nand **strong**\nalso **bold**", "> quoted\nand **strong**",
        "| a | b |\n|---|---|\n| 1 | 2 |\nwith `code`\nand `more code`",
        "1. first\n2. second\n\n> note\n> more",
        // CRLF: Swift reads "\r\n" as one Character, so the split has to normalize first.
        "body\r\n# Title\r\n", "- a\r\n- b\r\n> q\r\n> r",
    ])
    func positives(_ s: String) { #expect(MarkdownDetector.looksLikeMarkdown(s)) }

    @Test(arguments: [
        "Just a sentence with a * star * in it.", "https://example.com/path", "a * b * c = d", "{\"k\": [1,2]}",
        "- a single list line", "Call me **maybe**", "email me at a@b.co\nthanks", "",
    ])
    func negatives(_ s: String) { #expect(!MarkdownDetector.looksLikeMarkdown(s)) }

    @Test func shebangSuppressesDetection() {
        // A script's `# comment` lines look like ATX headings; the shebang says otherwise.
        #expect(!MarkdownDetector.looksLikeMarkdown("#!/bin/sh\n# install deps\nset -e\n- not a list either"))
        #expect(!MarkdownDetector.looksLikeMarkdown("\n  #!/usr/bin/env python3\n# Title\n"))
        // Without the shebang the same comment line still counts as a heading (documented limit).
        #expect(MarkdownDetector.looksLikeMarkdown("# install deps\nset -e"))
        // A shebang later in the text is just a line.
        #expect(MarkdownDetector.looksLikeMarkdown("# Notes\n\n#!/bin/sh is how scripts start"))
    }

    @Test func lowDensityWeakSignalsInLongProseAreNotMarkdown() {
        // The fortunes-file bug (#50): a 427 KB quotes file has a handful of dialogue-dash list
        // lines and "> "-prefixed lines scattered across it, and the old rule fired on the mere
        // presence of two distinct weak signals anywhere in the scanned 400-line head, however
        // rare. Reproduced at the same ~4% / ~1% densities as the real file: 16 of 400 lines
        // (4%) start "- ", 4 of 400 (1%) start "> ", the rest are plain sentences. Neither clears
        // the 10% density floor, so this must stay unclassified as Markdown.
        var lines: [String] = []
        for i in 0..<400 {
            if i % 25 == 0 {
                lines.append("- item \(i)")
            } else if i % 100 == 60 {
                lines.append("> quoted \(i)")
            } else {
                lines.append("Just an ordinary sentence about the day, number \(i).")
            }
        }
        #expect(!MarkdownDetector.looksLikeMarkdown(lines.joined(separator: "\n")))
    }

    @Test func denseWeakSignalsAreMarkdown() {
        // A headingless README-style snippet: 6 of 10 lines are list items (60% >= 10%) and 2 of
        // those also carry a link (20% >= 10%) — two signals genuinely recur, so this is Markdown
        // even though nothing here trips the immediate heading/fence return.
        let text = """
        - item one
        - item two with [link](https://x.y)
        - item three with [link](https://x.y)
        - item four
        - item five
        - item six
        **bold** line here
        plain sentence
        another plain sentence
        final plain sentence
        """
        #expect(MarkdownDetector.looksLikeMarkdown(text))
    }

    @Test func twoRecurringSignalsInAShortSnippetAreStillMarkdown() {
        // The density rule must not raise the bar for genuinely short, dense Markdown: two list
        // lines and two quote lines in a four-line snippet both clear >= 2 matches and >= 10%.
        #expect(MarkdownDetector.looksLikeMarkdown("- a\n- b\n> quoted\n> more"))
    }

    @Test func aSingleSignalAloneIsNotMarkdown() {
        // 20 list lines and nothing else: one signal, however dense, is still only one signal.
        let text = (0..<20).map { "- item \($0)" }.joined(separator: "\n")
        #expect(!MarkdownDetector.looksLikeMarkdown(text))
    }

    @Test func scanIsBounded() {
        let big = String(repeating: "plain line\n", count: 100_000) + "# heading far below the cap\n"
        #expect(!MarkdownDetector.looksLikeMarkdown(big))   // heading is beyond 64 KB / 400 lines
    }

    @Test func unclosedBracketLineDoesNotBacktrackQuadratically() {
        // A single 64 KB line of unclosed "[" defeats the unbounded link/inline
        // quantifiers via O(n^2) backtracking unless both are bounded and the
        // per-line scan cap skips them outright on a line this long.
        let big = String(repeating: "[", count: 65_536) + "(x)"
        let clock = ContinuousClock()
        var result = false
        let elapsed = clock.measure { result = MarkdownDetector.looksLikeMarkdown(big) }
        #expect(!result)
        #expect(elapsed < .milliseconds(100))
    }
}
