# Legacy Pastefix reference material

Historical source and notes from the two previous incarnations of Pastefix,
vendored here so v2's specs and plans do not depend on files that live only on
one developer's machine. **Read-only reference — nothing here is built.**

Originally copied from `~/Source/pastefix-save` (2007) and `~/Source/Pastefix`
(2019, `github.com/bnaylor/Pastefix`).

## What's here

| File | Era | Why it's kept |
|---|---|---|
| `README-2019.md` | 2019 | The best prose description of v1's behavior — the feature list, the Split/Refresh/Autohide semantics, and the preference set. Cited by `docs/specs/2026-08-11-pastefix-v2-foundation-pipeline.md`. |
| `TextProc-2007.h/.m` | 2007 | The classic transform algorithms. Also cited by the foundation spec. |
| `TODO-2019.txt` | 2019 | Where the "user-defined transform pipeline" idea originates. Cited by `../initial_requirements.md`. |
| `TODO-2007.txt` | 2007 | The original wishlist; most of it shipped by v0.9.3. |
| `BUGS-2007.txt` | 2007 | One entry, a deliberate WONTFIX about splitting lines with no spaces. |
| `Interpreter-2019.h/.m`, `PerlInterpreter-2019.h/.m` | 2019 | The abandoned scripting attempt — see below. |

## The two algorithms v2 inherited

`TextProc-2007.m` is the direct ancestor of `PastefixCore/Native/`:

- **Transliteration** (`convertUTF8ToASCII:`) — fast-path returns input unchanged
  when it's already ASCII-convertible; otherwise `iconv_open("ASCII//TRANSLIT",
  "UTF-8")`, over-allocating the output buffer because transliteration can
  *grow* the string. On iconv failure it falls back to a destructive
  `allowLossyConversion:YES`. A preference (`PFUseIconvKey`) let the user skip
  iconv entirely and take the lossy path. v2's `Transliterate.swift` does this
  with Foundation instead, and has no lossy/strict toggle.
- **Line splitting** (`splitLines:maxLength:` / `doSplit:onString:maxLength:`) —
  splits on word boundaries at a max column count. v2's `WrapReflow.swift` is
  the paragraph-aware successor. Note the 2007 WONTFIX: a line with no spaces
  was left over-long rather than hard-split.

## Why the 2019 rewrite matters

The 2019 attempt died trying to add a scripting pipeline, which is exactly the
feature v2 builds on. It first tried to embed Python, gave up ("Giving up on
embedding Python, very basic steps now towards just forking interpreters"), and
pivoted to forking an interpreter and shuttling text through a temp file —
`Interpreter.m` / `PerlInterpreter.m` are as far as it got before the project
stalled. `PythonScripts/` was left empty.

v2 deliberately avoids that hole: no embedded language runtime, no temp-file
handoff. Scripts are either JavaScriptCore (in-process, no bindings to maintain)
or a plain `stdin` → `stdout` subprocess, per invariants 5 and 6 in
[`AGENTS.md`](../../../AGENTS.md).
