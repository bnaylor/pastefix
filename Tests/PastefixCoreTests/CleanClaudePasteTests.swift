import Testing
@testable import PastefixCore

/// Text copied out of a Claude Code terminal: a 2-space margin, lines hard-wrapped at the terminal's
/// width, and UI chrome. The transform unwraps only what the terminal wrapped.
@Suite struct CleanClaudePasteTests {
    func clean(_ s: String) -> String { CleanClaudePaste.clean(s) }

    /// A slice of a real paste (190-column terminal): a wrapped bullet, a wrapped paragraph, chrome.
    @Test func realPaste() {
        let bullet = "  - Undo: ⌘Z and the toolbar Undo now share one stack with typing, so typing and transforms undo and redo in the order they happened, with or without the editor on screen. AGENTS.md records"
        let input = """
          Things to know for future work:
        \(bullet)
            the macOS undo-grouping rules that caused most of the trouble.
          - Dead-key accents: the stack is cleared first.

        ✔ Goal achieved (13h · 207 turns · 394.5k tokens) (ctrl+o to expand)

        ✻ Cogitated for 7m 34s · done 12:31 PM

        ❯ we're back

        ⏺ Welcome back.
        """
        #expect(clean(input) == """
        Things to know for future work:
        \(bullet.dropFirst(2)) the macOS undo-grouping rules that caused most of the trouble.
        - Dead-key accents: the stack is cleared first.

        > we're back

        Welcome back.

        """)
    }

    /// A real paste whose selection began one column into the 2-space margin: the first line has 1
    /// space, the rest 2. The first line's indent is where the drag started, not structure.
    @Test func selectionStartingInsideTheMargin() {
        let input = """
         What changed. CPython 3.13.16 (released in August) backported a 3.14 change. When you import a submodule whose parent package
          is still initializing, Python now waits for the parent to finish before it consults any import hook. So thread B waits on A,
          never reaches the hook, and the test reports "thread B never reached the hook" every time. It isn't flaky; it fails on every
          3.13.16 runner. GitHub's runner pool is midway through an image rollout from 3.13.15 to 3.13.16, which is why it looked
          random: all 14 failures today were on the new image. Once the rollout finishes, that job goes red on every PR.
        """
        #expect(clean(input) == "What changed. CPython 3.13.16 (released in August) backported a 3.14 change. When you import a submodule whose parent package"
            + " is still initializing, Python now waits for the parent to finish before it consults any import hook. So thread B waits on A,"
            + " never reaches the hook, and the test reports \"thread B never reached the hook\" every time. It isn't flaky; it fails on every"
            + " 3.13.16 runner. GitHub's runner pool is midway through an image rollout from 3.13.15 to 3.13.16, which is why it looked"
            + " random: all 14 failures today were on the new image. Once the rollout finishes, that job goes red on every PR.\n")
    }

    @Test func selectionStartingAtColumnZero() {
        let input = "This paragraph is long enough that the terminal wrapped it\n"
            + "  at sixty columns, and it should come back as one line.\n"
        #expect(clean(input) == "This paragraph is long enough that the terminal wrapped it at sixty columns, and it should come back as one line.\n")
    }

    @Test func paragraphAndNumberedItemWrappedAt60() {
        let input = "⏺ This paragraph is long enough that the terminal wrapped it\n"
            + "  at sixty columns, and it should come back as one line.\n\n"
            + "  1. A numbered item that also runs past the edge of the\n"
            + "     terminal and continues here.\n"
            + "  2. Short item.\n"
        #expect(clean(input) == "This paragraph is long enough that the terminal wrapped it at sixty columns, and it should come back as one line.\n\n"
            + "1. A numbered item that also runs past the edge of the terminal and continues here.\n"
            + "2. Short item.\n")
    }

    @Test func intentionalShortLinesStaySeparate() {
        let input = "  Roses are red\n  Violets are blue\n  This line is here only to make the paste reasonably wide okay\n"
        #expect(clean(input) == "Roses are red\nViolets are blue\nThis line is here only to make the paste reasonably wide okay\n")
    }

    @Test func codeFenceIsNeverJoined() {
        let input = "  Here is some code that we would like to keep exactly as it is written:\n"
            + "  ```\n"
            + "  let x = someFunctionWithAVeryLongName(argumentOne, argumentTwo)\n"
            + "  print(x)\n"
            + "  ```\n"
        #expect(clean(input) == "Here is some code that we would like to keep exactly as it is written:\n```\nlet x = someFunctionWithAVeryLongName(argumentOne, argumentTwo)\nprint(x)\n```\n")
    }

    @Test func tableRowsAreLeftAlone() {
        let input = "  │ Name │ Value that is quite long to make this row the widest line │\n  │ a    │ b │\n"
        #expect(clean(input) == "│ Name │ Value that is quite long to make this row the widest line │\n│ a    │ b │\n")
    }

    @Test func noWrappingMeansNothingJoins() {
        #expect(clean("  First line.\n  Second line.\n") == "First line.\nSecond line.\n")
    }

    @Test func toolOutputMarkerBecomesIndentation() {
        #expect(clean("⏺ Bash(ls)\n  ⎿  a.txt\n     b.txt\n") == "Bash(ls)\n   a.txt\n   b.txt\n")
    }

    /// Known limit, pinned: the widest line followed by a deliberate break at the same indent is
    /// indistinguishable from a wrap, and is joined.
    @Test func knownLimitDeliberateBreakAfterTheWidestLine() {
        #expect(clean("  This is the widest line in the paste, ending in a real line break\n  Next\n")
            == "This is the widest line in the paste, ending in a real line break Next\n")
    }

    @Test func emptyAndBlank() {
        #expect(clean("") == "")
        #expect(clean("\n\n  \n") == "")
    }

    @Test func metadata() {
        let t = CleanClaudePaste()
        #expect(t.id == "builtin.claudepaste")
        #expect(t.name == "Clean Claude Code Paste")
        #expect(t.category == TransformCategory.layout)
        #expect(t.source == .builtin)
    }
}
