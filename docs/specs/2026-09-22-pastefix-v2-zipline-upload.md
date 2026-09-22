---
type: spec
status: approved
id: 2026-09-22-pastefix-v2-zipline-upload
title: Pastefix v2 — Zipline Upload (Plan 13)
description: ⌘⇧U uploads the working text to a self-hosted Zipline v4 instance and replaces the clipboard with the short URL. One overlay owns the flow — expiration, burn-on-read, file extension, and an inline secret-detector verdict with a redact-or-send choice. Token in the Keychain, server URL in settings.
tags: [pastefix, macos, swift, upload, zipline, keychain, secrets]
timestamp: 2026-09-22T16:30:00Z
---

# Pastefix v2 — Zipline Upload (Plan 13)

Source: [issue #14](https://github.com/bnaylor/pastefix/issues/14) ("Post to
Zipline", "Zipline upload controls"), original requirements §5. Scoped to text
and code; image upload is [#48](https://github.com/bnaylor/pastefix/issues/48),
which sits behind #18 (image support) and #20 (EXIF stripping) and must not
hold this up.

This is the first feature that sends the user's clipboard off the machine. Every
decision below that looks over-careful is that fact.

## Corrections to the issue

The issue was written from the original requirements, before anyone read
Zipline v4's source. Three of its assumptions are wrong and the design does not
follow them:

1. **`x-zipline-format` is not syntax highlighting.** It is the *filename*
   format (`random`/`uuid`/`date`/`name`/`gfycat`, validated against `FORMATS`
   in `src/lib/uploader/parseHeaders.ts`). Zipline derives highlighting from the
   file **extension**, so the "language" control sets the uploaded file's
   extension, not a language header.
2. **Burn-on-read is not an expiration value.** It is
   `x-zipline-max-views: 1`, a different header from `x-zipline-deletes-at`.
   The issue lists "1 h / 1 d / 7 d / burn-on-read" as one control; that is two
   controls.
3. **No notification.** The issue asks for one. The repo has no notification
   infrastructure at all (no `UNUserNotificationCenter` anywhere), and the
   overlay that owns the flow is already on screen when the upload lands — so
   it shows the URL itself. Dropped by decision, not oversight: a permission
   prompt to tell you something you are already looking at is a bad trade.

A fourth, from the handoff notes on the issue rather than the issue body:
`SecretDetector.isScannable(_:)` returns **true when the text is under the
256 KB cap**, not when it is over. A gate written from the inverted reading
would let every oversized buffer through unscanned.

## The Zipline v4 contract

Verified against `diced/zipline` at v4.7.0, not from memory.

| Piece | Value |
|---|---|
| Endpoint | `POST <server>/api/upload`, `multipart/form-data` |
| Auth | `authorization: <token>` — raw, no `Bearer` (`src/server/middleware/user.ts`) |
| File field | `file` |
| Response | `{ files: [{ id, name, type, url, … }], deletesAt?, assumedMimetypes? }` — the short URL is `files[0].url` |
| Expiry | `x-zipline-deletes-at`: `never`, `date=<ISO8601>`, or a human string (`1h`, `7d`). Server rejects past dates and anything over its own `maxExpiration`. |
| Burn-on-read | `x-zipline-max-views: 1` |
| Extension | `x-zipline-file-extension`, or the extension of `x-zipline-filename` |
| Filename | `x-zipline-filename` — **the server runs `decodeURIComponent` on it**, so it must be percent-encoded on the way out |
| Header errors | `ApiError(1001, "bad options[<header>]: <message>")` |

## Scope

**In scope:**

- **Settings (Upload tab):** server URL, API token, and the defaults the
  overlay opens with (expiration, burn-on-read, extension).
- **⌘⇧U:** a global, rebindable hotkey that opens the upload overlay. With the
  panel closed it summons from the clipboard exactly as ⌘⇧V does; with the
  panel open it takes the current document.
- **The upload overlay:** the single surface for the flow — expiration,
  burn-on-read, extension, the secret verdict, the upload, the result, and
  every error.
- **The secret gate:** every upload is scanned, with a redact-or-send choice
  when anything is found.
- **On success:** the clipboard becomes the short URL.

**Out of scope:**

- Images (#48), and with them `x-zipline-image-compression-*` and the
  response's `removedGps`.
- Zipline features this flow has no use for: folders, passwords,
  `x-zipline-original-name`, `x-zipline-no-json`, partial/chunked upload.
- Upload history, a "my uploads" browser, or deleting an upload from Pastefix.
  The clipboard gets the URL and the history captures it as an ordinary item;
  that is the whole record.
- Any Zipline version but v4.

## Decisions

| Decision | Choice | Why |
|---|---|---|
| Entry point | ⌘⇧U always opens the overlay; no instant-upload variant | One surface. An instant path would need the secret verdict as a second dialog stacked on it, which is the thing the overlay exists to avoid. |
| Secret gate | Prompt inline: Redact / Send as-is / Cancel | Blocking has no escape hatch for a deliberate share; silent redaction mangles false positives with no way to say no. |
| Redaction target | The uploaded copy only | Uploading must not rewrite your buffer or your clipboard. |
| Scan cap | None — every upload is fully scanned, off the main actor | `SecretDetector.maxBytes` (256 KB) exists because scanning runs on *every summon and capture*. An upload is one deliberate action and can afford the full scan. The upload path calls `SecretDetector.scanIgnoringSizeCap(_:)`, added in Task 2 by splitting the size policy out of the existing `scan(_:)`; `scan(_:)` itself keeps the 256 KB guard unchanged for every main-actor caller. A separate, deliberately awkward name rather than a defaulted parameter, so the one call site that skips the cap reads as the exception it is, and so `scan(_:)` stays provably identical to what every other caller already relies on. |
| Scan placement | Detached task, started as the overlay opens | The overlay's controls stay usable during the wait, and a long scan is visible instead of a frozen hotkey. |
| Loading state | "Checking for secrets…" appears only after ~150 ms | No flicker on ordinary pastes, and no size-threshold constant to justify. |
| Language control | Sets the file extension. The user's `ziplineDefaultExtension` setting wins whenever it has been set; `ContentDetector.detect` fills in only while the setting is still its `txt` default | v4 highlights by extension. Detection existed and was tried first as the seed, then reversed during review: `MarkdownDetector` returns true on a single `^#{1,6} \S` line, so letting the detector win meant every YAML file, Dockerfile, conf file and shebang-less script uploaded as `md`, silently overriding an explicit user choice. The detector is trigger-happy, not confident — fine for *promoting* a transform in the palette, wrong for *overriding* a setting the user deliberately typed. |
| Token storage | Keychain generic password, service `net.scromp.Pastefix.zipline` | A token in `UserDefaults` JSON is world-readable to anything running as the user. |
| Token entry commit | A `SecureField` plus an explicit **Set** button, not the field alone | Submit and blur/tab-switch commit the draft implicitly, but neither covers ⌘Q mid-edit — SwiftUI does not reliably run an open window's `onDisappear` on process termination, so a token typed and never submitted before quitting was silently dropped, not merely unsaved. The button makes the draft's uncommitted state visible instead of implicit, and is also just the normal shape for committing a credential. Not redundant with the implicit paths; it is the one path that covers the one exit they don't. |
| Server URL storage | `SettingsStore` JSON with everything else | It is not a secret, and keeping it out of the Keychain keeps the Keychain wrapper to one value. |
| Private/LAN server URLs | Allowed — `MarkdownLink.isFetchable` is deliberately *not* reused | That guard blocks private IPs because *there* the URL comes from clipboard content an attacker may control. Here the destination is one the user typed into Settings, and a self-hosted Zipline is usually on a LAN or Tailscale address. Applying the guard would break the normal case to prevent an attack that cannot happen. |
| Self-signed certificates | No trust bypass | It is the only transport protection in this feature. A bad cert fails the upload. |
| Token in logs | Never; response bodies logged `.private` | Zipline's header errors quote the request back. |
| Module placement | Client and header mapping in `PastefixCore`; Keychain behind a protocol in `PastefixAppCore`; UI in the app target | Follows `TitleFetcher`/`URLSessionTitleFetcher`, the existing precedent for injectable network work, and keeps everything testable except the Keychain conformer. |

## Architecture

### PastefixCore

```swift
public protocol ZiplineUploading: Sendable {
    func upload(_ request: ZiplineUpload, to server: URL, token: String) async throws -> URL
}

public struct ZiplineUpload: Sendable, Equatable {
    public var text: String
    public var fileExtension: String     // "txt", "json", "swift", …
    public var expiry: ZiplineExpiry
    public var burnOnRead: Bool
}

public enum ZiplineExpiry: Sendable, Equatable {
    case never
    case relative(String)                // "1h", "1d", "7d"
    case absolute(Date)                  // emitted as "date=<ISO8601>"
}

/// The only place a v4 header spelling appears. Pure, so every mapping is
/// testable without a socket, and a v5 is a sibling type rather than a rewrite.
public enum ZiplineV4Headers {
    public static func headers(for upload: ZiplineUpload) -> [String: String]
}

public enum ZiplineUploadError: Error, Equatable {
    case unauthorized
    case badOption(header: String, message: String)   // Zipline ApiError 1001
    case server(status: Int, message: String?)
    case malformedResponse
    case transport(String)
}

public struct URLSessionZiplineClient: ZiplineUploading { … }
```

`URLSessionZiplineClient` builds the multipart body, sets `authorization` and
the mapped `x-zipline-*` headers, and reads `files[0].url`. Ephemeral session,
60 s timeout — not `TitleFetcher`'s 3 s, because this is a body being sent
rather than a `<head>` being skimmed.

The client takes the server and token as parameters and has no opinion about
where they came from, so "not configured" is not one of its errors: the app
layer checks for both before the overlay opens (see Data flow step 2) and the
client is never called without them.

**No `x-zipline-filename` is sent.** The stored name is left to the server's
own format; only `x-zipline-file-extension` is set, since the extension is all
Zipline needs to pick highlighting. The multipart part carries a filename of
`paste.<ext>` because `multipart/form-data` requires one — that is a form
field, not the Zipline header. Recorded for whoever adds a filename control
later: v4 runs `decodeURIComponent` on `x-zipline-filename`, so that header
must be percent-encoded, and an unencoded space or `#` corrupts the name.

### PastefixAppCore

```swift
public protocol ZiplineTokenStore: Sendable {
    func token() throws -> String?
    func setToken(_ token: String) throws
    func clearToken() throws
}

public struct KeychainTokenStore: ZiplineTokenStore { … }   // SecItem*, untested
public final class InMemoryTokenStore: ZiplineTokenStore { … }  // tests
```

`SettingsStore` gains the server URL and the overlay's defaults, in the same
JSON-backed shape as every other setting.

### App target

- `HotkeyName.uploadToZipline` — default ⌘⇧U, rebindable. No dots in the name
  (the `KeyboardShortcuts` constraint recorded in AGENTS.md).
- `UploadOverlayView` — the third overlay inside `PanelView`, built like
  `HistoryOverlayView`: same card metrics, same one-shot `AppModel` request
  flag, same rule that every handler reads `@State` at call time.
- `UploadSettingsView` — the Upload tab.

## Data flow

1. ⌘⇧U fires. Panel closed → summon from the clipboard, then raise the
   overlay; panel open → take the current document.
2. **Configuration is checked before anything else.** No server URL or no
   token → the overlay opens in a configure state with a button into Settings,
   rather than letting you make choices and then failing.
3. The overlay opens with expiration, burn-on-read, and extension live. The
   extension defaults to the `ziplineDefaultExtension` setting if the user has
   set one away from `txt`; only while that setting is still at its `txt`
   default does `ContentDetector.detect` fill in instead (`.json` for JSON,
   `.md` for Markdown, `.txt` otherwise) — see the "Language control" decision
   above for why the precedence runs that direction.
4. The scan starts in a detached task in the same turn. Upload is disabled
   until it resolves. After ~150 ms an in-progress row appears.
5. Verdict lands. Clean → a quiet confirmation row. Findings → the kinds named
   (`SecretMatch.kind.displayName`), with Redact / Send as-is. **Redact is
   preselected**: the safe choice is the one you get by pressing Return.
6. Upload builds a `ZiplineUpload` from the controls and the chosen text —
   redacted via `SecretRedactor.redact(_:matches:)` if that was the choice,
   the original otherwise.
7. Success → `ClipboardBridge.writePlain(url)`, and the overlay shows the URL
   with Copy and Open before dismissing. The pasteboard monitor captures the
   URL as an ordinary history item.
8. Failure → the overlay stays open, error shown, controls still live, retry
   in place.

## Error handling

| Failure | Behaviour |
|---|---|
| Not configured | Configure state before the scan; button into Settings |
| 401 | "Token rejected", pointing at Settings — distinct from transport failure |
| `1001 bad options[…]` | Surfaced against the control that caused it; the server enforces its own `maxExpiration` and only the user can pick a legal value |
| Other non-2xx | Status plus the server's message if it parses |
| `files[0].url` missing | `malformedResponse`. A 2xx with an unreadable body is never treated as success |
| Transport / timeout | Retry in place |
| Empty document | Upload disabled; nothing to send |

**Cancellation, stated honestly:** `SecretDetector` has no cancellation point,
so dismissing the overlay mid-scan abandons the work rather than stopping it —
the same shape as the TIFF decode in #32/#46, and the same rule applies: do not
describe it as a bound. The scan is linear tokenisation since the PR #42
rewrite.

**Dismissing mid-upload is also cancellation, and it is lossier.** The
overlay's `onDisappear` cancels the in-flight upload `Task`, which cancels the
underlying `URLSession` request if it is still on the wire — but cancelling
the client side recalls nothing the server has already accepted. A dismissal
timed to land after Zipline has written the file but before the response
reaches the overlay leaves a paste on the server whose short URL nobody ever
saw or copied. This was a deliberate choice over the alternative — letting the
request run to completion and writing the clipboard from a view that is no
longer on screen — because a clipboard write landing seconds after the panel
is gone would silently replace whatever the user copied in the meantime, which
is worse: it corrupts a live value instead of leaving an inert one. The orphan
this trades for is a file on the user's own self-hosted instance, visible and
deletable from Zipline's own file manager — not a leak to a third party. Known
behaviour, not a bug to fix by making dismissal wait for the response.

Measured on Apple M4 Max, Swift 6.3, debug build via `swift test`
(Task 2, `SecretDetectorScaleTests`, one uncapped
`SecretDetector.scanIgnoringSizeCap` call per size — see the "Scan cap"
decision above): 256 KB in 0.058s, 1 MB in 0.222s, 4 MB in 0.854s — linear
(each ~4x step in size costs ~3.8-3.9x the time). 4 MB stays under the 2s
gate, so the overlay uses an indeterminate spinner and `SecretDetector` keeps
no cancellation point, as with the TIFF decode in #46.

Task 1's first pass at this measurement chunked the corpus into ≤256 KB
pieces and summed `scan()` calls over them, because at the time no uncapped
entry point existed. That approach was replaced, not merely re-run: chunking
every call at the design point makes the total mechanically
`chunks x constant`, which cannot detect superlinear cost — the one thing
this measurement exists to catch (`NSRegularExpression` over a multi-MB
`NSString` need not behave like N calls over 1/N-sized ones). The numbers
above are the single-call replacement; the chunked figures do not appear
here because they describe a measurement that no longer exists.

## Testing

- `ZiplineV4Headers` as a pure mapping: every `ZiplineExpiry` case including
  `never` and `date=`, burn-on-read as `max-views: 1`, and extension
  defaulting. A `never` expiry must emit the literal `never`, not an absent
  header — the two mean different things to a server whose own default
  expiration is set.
- `URLSessionZiplineClient` against a stubbed `URLProtocol`: success,
  malformed body, a `1001` body → `badOption`, 401 → `unauthorized`, timeout.
- Multipart construction: boundary, `file` field name, content type.
- The gate's contract: **the redacted text reaches the request while the
  source string is unchanged.** Redaction itself is Plan 11's; this test is
  about which copy goes out.
- `ZiplineTokenStore` via `InMemoryTokenStore`. `KeychainTokenStore` stays
  untested rather than writing to a real login keychain from CI.

No UI tests for the overlay; the app target has none today and this is not the
change that starts that. Baseline was 438 tests / 51 suites after PR #46;
shipped at 481 / 58 — +43 tests, +7 suites.

## Project layout delta

```
Sources/PastefixCore/Upload/ZiplineUpload.swift        # request value, expiry, errors
Sources/PastefixCore/Upload/ZiplineV4Headers.swift     # the only v4 header spellings
Sources/PastefixCore/Upload/ZiplineClient.swift        # protocol + URLSession client
Sources/PastefixAppCore/Upload/ZiplineTokenStore.swift # protocol, Keychain, in-memory
Sources/PastefixAppCore/SettingsStore.swift            # server URL + overlay defaults
Pastefix/Pastefix/HotkeyName.swift                     # uploadToZipline (⌘⇧U)
Pastefix/Pastefix/ZiplineServerURL.swift               # shared server-URL parse/validate, added in review (#14)
Pastefix/Pastefix/UploadOverlayView.swift              # the one surface
Pastefix/Pastefix/UploadSettingsView.swift             # Upload tab
Pastefix/Pastefix/AppModel.swift                       # uploadOverlayRequested
Pastefix/Pastefix/PanelView.swift                      # third overlay
Pastefix/Pastefix/PastefixApp.swift                    # hotkey registration
Pastefix/Pastefix/SettingsView.swift                   # Upload tab wired into the Settings TabView
```
