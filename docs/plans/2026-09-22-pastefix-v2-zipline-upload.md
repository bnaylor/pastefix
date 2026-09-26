# Pastefix v2 Zipline Upload (Plan 13) — Implementation Plan

> ## ✅ STATUS: COMPLETE — merged to `main` via PR #59 (`c353f9e`, 2026-09-26)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> **Swift specifics:** tests → `swift-testing-pro`; concurrency (Tasks 1, 3, 6) → `swift-concurrency-pro`; SwiftUI (Tasks 6, 7) → `swiftui-pro`. **TDD is required** for every package task (1–5). **One implementer at a time on the branch.** GUI passes are the controller's, with the user's permission.

**Goal:** ⌘⇧U uploads the working text to a self-hosted Zipline v4 instance and replaces the clipboard with the short URL, through one overlay that owns expiration, burn-on-read, file extension, an inline secret verdict, the upload, the result, and every error.

**Architecture:** `PastefixCore` gains an `Upload/` directory — the request value types, the v4 header mapping (the only place a header spelling appears), and a `ZiplineUploading` protocol with a `URLSession` client, following the `TitleFetcher`/`URLSessionTitleFetcher` precedent. `PastefixAppCore` gains a `ZiplineTokenStore` protocol with a Keychain conformer and an in-memory fake, plus the server URL and overlay defaults in `SettingsStore`. The app target adds the ⌘⇧U hotkey, an `UploadOverlayView` built as the third overlay inside `PanelView`, and an Upload settings tab.

**Tech Stack:** Swift 6 SwiftPM (packages macOS 14+, app target macOS 15+), `URLSession` + `multipart/form-data`, Security.framework (`SecItem*`), Swift Testing, SwiftUI, `KeyboardShortcuts`.

**Spec:** `docs/specs/2026-09-22-pastefix-v2-zipline-upload.md` — read it first. It records the verified Zipline v4 contract and three corrections to issue #14 that this plan follows instead of the issue.

## Global Constraints

- **Endpoint:** `POST <server>/api/upload`, `multipart/form-data`, file field name `file`, multipart part filename `paste.<ext>`.
- **Auth header:** `authorization: <token>` — raw value, **no `Bearer` prefix**.
- **Headers emitted:** `x-zipline-deletes-at` (`never` | `date=<ISO8601>` | `1h`/`1d`/`7d`), `x-zipline-max-views: 1` **only** when burn-on-read is on, `x-zipline-file-extension: <ext>` (no leading dot). **`x-zipline-filename` is never sent** — the stored name is the server's business.
- **Response:** short URL is `files[0].url`. A 2xx whose body does not yield that string is `malformedResponse`, never success.
- **Zipline errors:** `{"code": 1001, "message": "bad options[<header>]: <detail>"}` → `.badOption(header:message:)`. 401 → `.unauthorized`.
- **Timeout:** 60 s, request and resource, on an ephemeral `URLSessionConfiguration`.
- **Security, non-negotiable:** no certificate-trust bypass (no `URLSessionDelegate` auth handling at all); the token is never logged, and any response body logged is `privacy: .private`; `MarkdownLink.isFetchable` is **not** reused — private/LAN/Tailscale server URLs are allowed by design (spec, Decisions).
- **Secret gate:** every upload is scanned, in full, off the main actor. Redact is the preselected choice. Redaction applies **only to the uploaded copy**; the document and clipboard are never rewritten by the gate.
- **Settings keys:** `pastefix.zipline.serverURL`, `pastefix.zipline.defaultExpiry`, `pastefix.zipline.defaultBurnOnRead`, `pastefix.zipline.defaultExtension`. The token is **not** a settings key — Keychain only, service `net.scromp.Pastefix.zipline`.
- **Hotkey:** `KeyboardShortcuts.Name("uploadToZipline")` — no dots in the name (AGENTS.md, Plan 9 lesson) — default ⌘⇧U, rebindable.
- **Baseline:** `swift test` → `438 tests in 51 suites passed` before Task 1.
- **Branch:** `feat/zipline-upload`. Conventional commits + `Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>`. PR closes #14. `main` is protected.

---

### Task 0: Branch and baseline

- [ ] **Step 1: Confirm the branch and baseline**

```bash
git rev-parse --abbrev-ref HEAD    # expect: feat/zipline-upload
swift test 2>&1 | tail -1          # expect: 438 tests in 51 suites passed
```

The spec is already committed on this branch (`c120ad8`). Nothing to commit here.

---

### Task 1: Measure `SecretDetector` above its design point

**This task gates the overlay's design and must be done first.** The spec commits to scanning every upload in full, with no 256 KB cap. `SecretDetector.maxBytes` exists because scanning runs on *every summon and capture*; nobody has measured it above that. If a megabyte costs seconds, the overlay needs a progress bar rather than a spinner and `SecretDetector` needs a cancellation check — both design changes, and both cheaper to find now than after Task 6.

**Files:**
- Create: `Tests/PastefixCoreTests/SecretDetectorScaleTests.swift`
- Modify: `docs/specs/2026-09-22-pastefix-v2-zipline-upload.md` (record the measurement)

**Interfaces:**
- Consumes: `SecretDetector.scan(_:) -> [SecretMatch]`, `SecretDetector.maxBytes` (262_144)
- Produces: a recorded cost curve and a go/no-go on cancellation. No source changes if the numbers are good.

- [ ] **Step 1: Write the measurement test**

Realistic shapes, not `String(repeating:)` of one character — Plan 11's lesson was that a timing test with unrealistic input tests nothing (`"sk-abc "` repeated caps every run at 7 characters).

```swift
import Testing
import Foundation
@testable import PastefixCore

/// Identifier-heavy text with occasional real secrets, which is what a log or a
/// config dump actually looks like — and the shape that exhausted the JWT
/// candidate budget in Plan 11.
private func realisticCorpus(bytes: Int) -> String {
    let unit = """
    2026-09-22T10:15:03Z service=api region=us-east-1 request_id=7f3a9c21-4b0e-4a31-9d77-2c1e8f0b5a63
    user_id=48211 path=/v1/accounts/48211/settings status=200 duration_ms=37 cache=miss
    aws_access_key_id=AKIAIOSFODNN7EXAMPLE bucket=prod-assets-us-east-1 etag=d41d8cd98f00b204e9800998
    authorization=Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiI0ODIxMSIsIm5hbWUiOiJKb2huIn0.abc123
    """
    var out = ""
    out.reserveCapacity(bytes + unit.utf8.count)
    while out.utf8.count < bytes { out += unit + "\n" }
    return out
}

@Suite("SecretDetector scale (Plan 13 measurement)")
struct SecretDetectorScaleTests {
    /// Not a benchmark assertion so much as a tripwire: the upload path scans
    /// without a cap, so a regression into superlinear cost must fail here
    /// rather than freeze an overlay.
    @Test("scan cost stays linear well past maxBytes", .timeLimit(.minutes(1)))
    func scaleCurve() {
        var measurements: [(bytes: Int, seconds: Double)] = []
        for multiple in [1, 4, 16] {
            let text = realisticCorpus(bytes: SecretDetector.maxBytes * multiple)
            let start = ContinuousClock.now
            let matches = SecretDetector.scan(text)
            let elapsed = ContinuousClock.now - start
            let seconds = Double(elapsed.components.seconds)
                + Double(elapsed.components.attoseconds) / 1e18
            measurements.append((text.utf8.count, seconds))
            #expect(!matches.isEmpty, "the corpus is supposed to contain secrets")
        }
        for m in measurements {
            print("SecretDetector.scan: \(m.bytes) bytes in \(String(format: "%.3f", m.seconds)) s")
        }
        // 4 MB is the largest paste this flow should ever meet without the user
        // noticing they did something unusual. Two seconds is the point past
        // which a spinner is a lie and the overlay needs real progress.
        let largest = measurements.last!
        #expect(largest.seconds < 2.0,
                "scan of \(largest.bytes) bytes took \(largest.seconds)s — see Task 1 decision gate")
    }
}
```

- [ ] **Step 2: Run it and read the printed curve**

```bash
swift test --filter SecretDetectorScaleTests 2>&1 | grep -E "SecretDetector.scan:|passed|failed"
```

- [ ] **Step 3: Decision gate — record the numbers in the spec**

Append the measured figures to the spec's "Error handling" section, replacing the sentence that currently promises this measurement. Write the actual numbers, not "fast".

- **If 4 MB completes under ~2 s:** a spinner is honest. Proceed to Task 2 unchanged. Record: "Measured on <machine>: 256 KB in Xs, 1 MB in Ys, 4 MB in Zs — linear; the overlay uses an indeterminate spinner and the detector keeps no cancellation point, as with the TIFF decode in #46."
- **If it does not:** stop and report before writing any more code. The overlay grows a determinate progress bar, and `SecretDetector.scan` needs a deadline/cancellation hook of the kind `RegexPresetTransformer` already uses (`enumerateMatches` with `.reportProgress` — see AGENTS.md, Plan 12 lessons). That is a spec amendment, not an implementation detail, and it changes Tasks 2 and 6.

- [ ] **Step 4: Commit**

```bash
git add Tests/PastefixCoreTests/SecretDetectorScaleTests.swift docs/specs/2026-09-22-pastefix-v2-zipline-upload.md
git commit -m "test(core): measure SecretDetector cost above its 256 KB design point (#14)

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 2: Request values, header mapping, and the gate's payload rule (Core, TDD)

**Files:**
- Create: `Sources/PastefixCore/Upload/ZiplineUpload.swift`
- Create: `Sources/PastefixCore/Upload/ZiplineV4Headers.swift`
- Create: `Tests/PastefixCoreTests/ZiplineHeadersTests.swift`

**Interfaces:**
- Consumes: `SecretMatch` and `SecretRedactor.redact(_:matches:)` from `PastefixCore/Detection/SecretDetector.swift`; `ContentDetector.detect(_:) -> Set<ContentKind>`.
- Produces: `ZiplineUpload`, `ZiplineExpiry`, `ZiplineUploadError`, `SecretDisposition`, `ZiplineV4Headers.headers(for:)`, `ZiplineUpload.defaultExtension(for:)`, `UploadPayload.text(_:matches:disposition:)`. Tasks 3, 5, 6 and 7 all use these names.

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
import Foundation
@testable import PastefixCore

@Suite("Zipline v4 header mapping")
struct ZiplineHeadersTests {
    private func upload(expiry: ZiplineExpiry = .never,
                        burn: Bool = false,
                        ext: String = "txt") -> ZiplineUpload {
        ZiplineUpload(text: "hello", fileExtension: ext, expiry: expiry, burnOnRead: burn)
    }

    @Test("never emits the literal, not an absent header")
    func neverIsExplicit() {
        // A server with its own default expiration would apply it if the header
        // were simply omitted. "Never" has to say so.
        #expect(ZiplineV4Headers.headers(for: upload(expiry: .never))["x-zipline-deletes-at"] == "never")
    }

    @Test("relative expiry passes through verbatim")
    func relativeExpiry() {
        #expect(ZiplineV4Headers.headers(for: upload(expiry: .relative("7d")))["x-zipline-deletes-at"] == "7d")
    }

    @Test("absolute expiry is date= plus ISO8601")
    func absoluteExpiry() {
        let when = Date(timeIntervalSince1970: 1_800_000_000)
        let value = ZiplineV4Headers.headers(for: upload(expiry: .absolute(when)))["x-zipline-deletes-at"]
        #expect(value == "date=2027-01-15T08:00:00Z")
    }

    @Test("burn-on-read is max-views 1, and is absent when off")
    func burnOnRead() {
        #expect(ZiplineV4Headers.headers(for: upload(burn: true))["x-zipline-max-views"] == "1")
        #expect(ZiplineV4Headers.headers(for: upload(burn: false))["x-zipline-max-views"] == nil)
    }

    @Test("extension is sent without a leading dot")
    func fileExtension() {
        #expect(ZiplineV4Headers.headers(for: upload(ext: "swift"))["x-zipline-file-extension"] == "swift")
        #expect(ZiplineV4Headers.headers(for: upload(ext: ".swift"))["x-zipline-file-extension"] == "swift")
    }

    @Test("the filename header is never sent")
    func noFilenameHeader() {
        // v4 runs decodeURIComponent on x-zipline-filename. We avoid the whole
        // encoding question by letting the server name the file.
        #expect(ZiplineV4Headers.headers(for: upload())["x-zipline-filename"] == nil)
    }
}

@Suite("Upload extension defaulting")
struct UploadExtensionTests {
    @Test("JSON content defaults to json")
    func json() {
        #expect(ZiplineUpload.defaultExtension(for: #"{"a": 1, "b": [2, 3]}"#) == "json")
    }

    @Test("Markdown content defaults to md")
    func markdown() {
        #expect(ZiplineUpload.defaultExtension(for: "# Title\n\n- one\n- two\n") == "md")
    }

    @Test("anything else defaults to txt")
    func fallback() {
        #expect(ZiplineUpload.defaultExtension(for: "just some prose, nothing special") == "txt")
    }
}

@Suite("Which copy gets uploaded")
struct UploadPayloadTests {
    private let source = "token is AKIAIOSFODNN7EXAMPLE ok"

    @Test("redact sends the redacted copy")
    func redacts() {
        let matches = SecretDetector.scan(source)
        #expect(!matches.isEmpty)
        let out = UploadPayload.text(source, matches: matches, disposition: .redact)
        #expect(out != source)
        #expect(!out.contains("AKIAIOSFODNN7EXAMPLE"))
        // The gate must not be defeatable by its own output.
        #expect(SecretDetector.scan(out).isEmpty)
    }

    @Test("send-as-is sends the source byte for byte")
    func sendsAsIs() {
        let matches = SecretDetector.scan(source)
        #expect(UploadPayload.text(source, matches: matches, disposition: .sendAsIs) == source)
    }

    @Test("no matches is a no-op under either disposition")
    func cleanText() {
        let clean = "nothing to see here"
        #expect(UploadPayload.text(clean, matches: [], disposition: .redact) == clean)
        #expect(UploadPayload.text(clean, matches: [], disposition: .sendAsIs) == clean)
    }
}
```

> **Historical — the extension rule shipped differently.** `defaultExtension`
> takes `Set<ContentKind>?`, not text, and answers `json` or `txt` only: the
> Markdown case above was removed over a 427 KB file of fortunes that a
> presence-only weak signal called Markdown. The spec carries the current rule,
> and `ZiplineUpload.defaultExtension(for:)` carries the reasoning. This plan is
> kept as written.

- [ ] **Step 2: Run to verify they fail**

```bash
swift test --filter "ZiplineHeadersTests|UploadExtensionTests|UploadPayloadTests" 2>&1 | tail -5
```
Expected: FAIL — `cannot find 'ZiplineV4Headers' in scope`.

- [ ] **Step 3: Write the implementation**

`Sources/PastefixCore/Upload/ZiplineUpload.swift`:

```swift
import Foundation

/// One text upload, as the caller describes it. Deliberately free of any
/// Zipline header spelling: `ZiplineV4Headers` owns that, so a future v5 is a
/// sibling mapper rather than a rewrite of everything that builds a request.
public struct ZiplineUpload: Sendable, Equatable {
    public var text: String
    /// Without a leading dot; the mapper strips one if it is there anyway.
    public var fileExtension: String
    public var expiry: ZiplineExpiry
    public var burnOnRead: Bool

    public init(text: String, fileExtension: String, expiry: ZiplineExpiry, burnOnRead: Bool) {
        self.text = text
        self.fileExtension = fileExtension
        self.expiry = expiry
        self.burnOnRead = burnOnRead
    }

    /// Zipline v4 picks syntax highlighting from the file extension, so the
    /// overlay's "language" control is an extension control. Reuses the
    /// detector the panel already runs rather than introducing a language table.
    public static func defaultExtension(for text: String) -> String {
        let kinds = ContentDetector.detect(text)
        if kinds.contains(.json) { return "json" }
        if kinds.contains(.markdown) { return "md" }
        return "txt"
    }
}

public enum ZiplineExpiry: Sendable, Equatable {
    case never
    /// A human string v4's `humanTime` accepts: "1h", "1d", "7d".
    case relative(String)
    case absolute(Date)
}

/// Whether a found secret is removed from the uploaded copy or sent anyway.
public enum SecretDisposition: Sendable, Equatable {
    case redact
    case sendAsIs
}

/// The single place that decides which bytes leave the machine.
///
/// It takes the source and returns a new string: nothing here can rewrite the
/// user's document or clipboard, which is the property the overlay depends on.
public enum UploadPayload {
    public static func text(_ source: String,
                            matches: [SecretMatch],
                            disposition: SecretDisposition) -> String {
        guard disposition == .redact, !matches.isEmpty else { return source }
        return SecretRedactor.redact(source, matches: matches)
    }
}

public enum ZiplineUploadError: Error, Equatable {
    case unauthorized
    /// Zipline's ApiError 1001 — the user picked an option the server refuses
    /// (most often an expiry beyond its `maxExpiration`), so it is fixable in
    /// the overlay rather than fatal.
    case badOption(header: String, message: String)
    case server(status: Int, message: String?)
    /// A 2xx whose body did not yield `files[0].url`. Never treated as success.
    case malformedResponse
    case transport(String)
}
```

`Sources/PastefixCore/Upload/ZiplineV4Headers.swift`:

```swift
import Foundation

/// The only place a Zipline v4 header spelling appears.
///
/// Verified against diced/zipline v4.7.0 (`src/lib/uploader/parseHeaders.ts`).
/// Note what is NOT here: `x-zipline-format` is the server's *filename* format,
/// not syntax highlighting, and `x-zipline-filename` is never sent — v4 runs
/// `decodeURIComponent` on it, and letting the server name the file avoids the
/// encoding question entirely.
public enum ZiplineV4Headers {
    private static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone(secondsFromGMT: 0)
        return f
    }()

    public static func headers(for upload: ZiplineUpload) -> [String: String] {
        var headers: [String: String] = [:]
        switch upload.expiry {
        case .never:
            // Explicit, not omitted: a server with its own default expiration
            // would otherwise apply it to something the user asked to keep.
            headers["x-zipline-deletes-at"] = "never"
        case .relative(let value):
            headers["x-zipline-deletes-at"] = value
        case .absolute(let date):
            headers["x-zipline-deletes-at"] = "date=" + iso8601.string(from: date)
        }
        if upload.burnOnRead { headers["x-zipline-max-views"] = "1" }
        let ext = upload.fileExtension.hasPrefix(".")
            ? String(upload.fileExtension.dropFirst())
            : upload.fileExtension
        if !ext.isEmpty { headers["x-zipline-file-extension"] = ext }
        return headers
    }
}
```

- [ ] **Step 4: Run to verify they pass**

```bash
swift test --filter "ZiplineHeadersTests|UploadExtensionTests|UploadPayloadTests" 2>&1 | tail -5
```
Expected: PASS.

If `absoluteExpiry` fails on the literal string, print the produced value and fix the *expectation* to match `ISO8601DateFormatter` — do not loosen the assertion to a `contains`.

- [ ] **Step 5: Commit**

```bash
git add Sources/PastefixCore/Upload Tests/PastefixCoreTests/ZiplineHeadersTests.swift
git commit -m "feat(core): Zipline upload request values and v4 header mapping (#14)

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 3: The upload client (Core, TDD)

**Files:**
- Create: `Sources/PastefixCore/Upload/ZiplineClient.swift`
- Create: `Tests/PastefixCoreTests/ZiplineClientTests.swift`

**Interfaces:**
- Consumes: `ZiplineUpload`, `ZiplineV4Headers.headers(for:)`, `ZiplineUploadError` (Task 2).
- Produces: `ZiplineUploading` protocol with `upload(_:to:token:) async throws -> URL`, and `URLSessionZiplineClient(timeout:)`. Task 6 injects the protocol.

This task introduces the repo's first `URLProtocol` stub. `MarkdownLinkTests` fakes at the protocol boundary (`StubTitleFetcher`), which is right for *consumers* — but the whole risk here is in the HTTP handling itself: multipart framing, header emission, and error mapping. Those need a real `URLSession` with a fake transport underneath.

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
import Foundation
@testable import PastefixCore

/// Fake transport. Records the request (headers and body) and replies with a
/// canned response, so the client's own framing is what is under test.
private final class StubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var body = Data()
    nonisolated(unsafe) static var capturedHeaders: [String: String] = [:]
    nonisolated(unsafe) static var capturedBody = Data()
    nonisolated(unsafe) static var failWith: Error?

    static func reset() {
        status = 200; body = Data(); capturedHeaders = [:]; capturedBody = Data(); failWith = nil
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.capturedHeaders = request.allHTTPHeaderFields ?? [:]
        // URLSession moves an upload body to `httpBodyStream`.
        if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while case let read = stream.read(&buffer, maxLength: buffer.count), read > 0 {
                Self.capturedBody.append(contentsOf: buffer[0..<read])
            }
        } else if let body = request.httpBody {
            Self.capturedBody = body
        }
        if let error = Self.failWith {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status,
                                       httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite("Zipline client", .serialized)
struct ZiplineClientTests {
    private let server = URL(string: "https://zip.example.test")!
    private let upload = ZiplineUpload(text: "hello world", fileExtension: "txt",
                                       expiry: .relative("1d"), burnOnRead: true)

    private func client() -> URLSessionZiplineClient {
        StubProtocol.reset()
        return URLSessionZiplineClient(timeout: 5, protocolClasses: [StubProtocol.self])
    }

    @Test("a successful upload returns files[0].url")
    func success() async throws {
        let c = client()
        StubProtocol.body = #"{"files":[{"id":"a","name":"x.txt","type":"text/plain","url":"https://zip.example.test/u/abc"}]}"#.data(using: .utf8)!
        let url = try await c.upload(upload, to: server, token: "tok_123")
        #expect(url == URL(string: "https://zip.example.test/u/abc"))
    }

    @Test("the token goes in a raw authorization header, with no Bearer prefix")
    func auth() async throws {
        let c = client()
        StubProtocol.body = #"{"files":[{"url":"https://zip.example.test/u/abc"}]}"#.data(using: .utf8)!
        _ = try await c.upload(upload, to: server, token: "tok_123")
        let auth = StubProtocol.capturedHeaders.first { $0.key.lowercased() == "authorization" }?.value
        #expect(auth == "tok_123")
    }

    @Test("the mapped zipline headers are sent")
    func headers() async throws {
        let c = client()
        StubProtocol.body = #"{"files":[{"url":"https://zip.example.test/u/abc"}]}"#.data(using: .utf8)!
        _ = try await c.upload(upload, to: server, token: "tok_123")
        let sent = Dictionary(uniqueKeysWithValues:
            StubProtocol.capturedHeaders.map { ($0.key.lowercased(), $0.value) })
        #expect(sent["x-zipline-deletes-at"] == "1d")
        #expect(sent["x-zipline-max-views"] == "1")
        #expect(sent["x-zipline-file-extension"] == "txt")
    }

    @Test("the body is multipart with a file field and the text")
    func multipart() async throws {
        let c = client()
        StubProtocol.body = #"{"files":[{"url":"https://zip.example.test/u/abc"}]}"#.data(using: .utf8)!
        _ = try await c.upload(upload, to: server, token: "tok_123")
        let body = String(decoding: StubProtocol.capturedBody, as: UTF8.self)
        let contentType = StubProtocol.capturedHeaders.first { $0.key.lowercased() == "content-type" }?.value ?? ""
        #expect(contentType.hasPrefix("multipart/form-data; boundary="))
        let boundary = String(contentType.split(separator: "=").last!)
        #expect(body.contains("--\(boundary)"))
        #expect(body.contains(#"name="file""#))
        #expect(body.contains(#"filename="paste.txt""#))
        #expect(body.contains("hello world"))
        #expect(body.hasSuffix("--\(boundary)--\r\n"))
    }

    @Test("401 is unauthorized, not a generic server error")
    func unauthorized() async throws {
        let c = client()
        StubProtocol.status = 401
        StubProtocol.body = #"{"code":401,"message":"unauthorized"}"#.data(using: .utf8)!
        await #expect(throws: ZiplineUploadError.unauthorized) {
            try await c.upload(upload, to: server, token: "bad")
        }
    }

    @Test("a 1001 body becomes badOption naming the header")
    func badOption() async throws {
        let c = client()
        StubProtocol.status = 400
        StubProtocol.body = #"{"code":1001,"message":"bad options[x-zipline-deletes-at]: Expiry exceeds maximum allowed expiration of 7d"}"#.data(using: .utf8)!
        let thrown = await #expect(throws: ZiplineUploadError.self) {
            try await c.upload(upload, to: server, token: "tok_123")
        }
        guard let thrown, case .badOption(let header, let message) = thrown else {
            Issue.record("expected badOption, got \(String(describing: thrown))"); return
        }
        #expect(header == "x-zipline-deletes-at")
        #expect(message.contains("maximum allowed expiration"))
    }

    @Test("a 2xx without files[0].url is malformed, never success")
    func malformed() async throws {
        let c = client()
        StubProtocol.body = #"{"files":[]}"#.data(using: .utf8)!
        await #expect(throws: ZiplineUploadError.malformedResponse) {
            try await c.upload(upload, to: server, token: "tok_123")
        }
    }

    @Test("a transport failure is reported as transport")
    func transport() async throws {
        let c = client()
        StubProtocol.failWith = URLError(.notConnectedToInternet)
        let thrown = await #expect(throws: ZiplineUploadError.self) {
            try await c.upload(upload, to: server, token: "tok_123")
        }
        guard let thrown, case .transport = thrown else {
            Issue.record("expected transport, got \(String(describing: thrown))"); return
        }
    }
}
```

- [ ] **Step 2: Run to verify they fail**

```bash
swift test --filter ZiplineClientTests 2>&1 | tail -5
```
Expected: FAIL — `cannot find 'URLSessionZiplineClient' in scope`.

- [ ] **Step 3: Write the implementation**

`Sources/PastefixCore/Upload/ZiplineClient.swift`:

```swift
import Foundation

public protocol ZiplineUploading: Sendable {
    /// Returns the short URL. The server and token are parameters because this
    /// type has no opinion about where they are stored — "not configured" is
    /// the app layer's check, made before the overlay opens, so this is never
    /// called without both.
    func upload(_ request: ZiplineUpload, to server: URL, token: String) async throws -> URL
}

/// Shaped after `URLSessionTitleFetcher`: ephemeral session, explicit timeout,
/// injectable so consumers can fake it.
///
/// Deliberately has NO `URLSessionDelegate`. A self-hosted Zipline with a
/// self-signed certificate fails, and that is the intended behaviour: TLS is
/// the only transport protection this feature has, and an exception here would
/// remove it for everyone to spare one person a certificate fix.
public struct URLSessionZiplineClient: ZiplineUploading {
    public let timeout: TimeInterval
    private let protocolClasses: [AnyClass]?

    public init(timeout: TimeInterval = 60, protocolClasses: [AnyClass]? = nil) {
        self.timeout = timeout
        self.protocolClasses = protocolClasses
    }

    public func upload(_ request: ZiplineUpload, to server: URL, token: String) async throws -> URL {
        let endpoint = server.appendingPathComponent("api/upload")
        let boundary = "PastefixBoundary-\(UUID().uuidString)"

        var req = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData,
                             timeoutInterval: timeout)
        req.httpMethod = "POST"
        req.setValue(token, forHTTPHeaderField: "authorization")
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "content-type")
        for (name, value) in ZiplineV4Headers.headers(for: request) {
            req.setValue(value, forHTTPHeaderField: name)
        }
        req.httpBody = Self.multipartBody(text: request.text,
                                          fileExtension: request.fileExtension,
                                          boundary: boundary)

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        if let protocolClasses { config.protocolClasses = protocolClasses }
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw ZiplineUploadError.transport(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else { throw ZiplineUploadError.malformedResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw Self.error(status: http.statusCode, body: data)
        }
        guard let url = Self.shortURL(from: data) else { throw ZiplineUploadError.malformedResponse }
        return url
    }

    /// `multipart/form-data` requires a filename on the part; it is a form
    /// field, not `x-zipline-filename`, which is deliberately never sent.
    static func multipartBody(text: String, fileExtension: String, boundary: String) -> Data {
        let ext = fileExtension.hasPrefix(".") ? String(fileExtension.dropFirst()) : fileExtension
        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"paste.\(ext)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: text/plain; charset=utf-8\r\n\r\n".data(using: .utf8)!)
        body.append(Data(text.utf8))
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        return body
    }

    private static func shortURL(from data: Data) -> URL? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let files = object["files"] as? [[String: Any]],
              let first = files.first,
              let string = first["url"] as? String else { return nil }
        return URL(string: string)
    }

    /// Zipline replies `{"code":1001,"message":"bad options[<header>]: <detail>"}`
    /// for a header the user can fix in the overlay, which is why it does not
    /// collapse into the generic server case.
    private static func error(status: Int, body: Data) -> ZiplineUploadError {
        if status == 401 { return .unauthorized }
        let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        let message = object?["message"] as? String
        if let message, let parsed = parseBadOption(message) {
            return .badOption(header: parsed.header, message: parsed.detail)
        }
        return .server(status: status, message: message)
    }

    static func parseBadOption(_ message: String) -> (header: String, detail: String)? {
        guard message.hasPrefix("bad options["),
              let close = message.firstIndex(of: "]") else { return nil }
        let start = message.index(message.startIndex, offsetBy: "bad options[".count)
        let header = String(message[start..<close])
        var detail = String(message[message.index(after: close)...])
        if detail.hasPrefix(":") { detail.removeFirst() }
        return (header, detail.trimmingCharacters(in: .whitespaces))
    }
}
```

- [ ] **Step 4: Run to verify they pass**

```bash
swift test --filter ZiplineClientTests 2>&1 | tail -5
```
Expected: PASS, 8 tests.

If `multipart` fails because the body arrived on `httpBodyStream` rather than `httpBody`, the stub already handles both — check the boundary parsing in the test before touching the client.

- [ ] **Step 5: Commit**

```bash
git add Sources/PastefixCore/Upload/ZiplineClient.swift Tests/PastefixCoreTests/ZiplineClientTests.swift
git commit -m "feat(core): URLSession Zipline v4 upload client (#14)

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 4: Token storage (AppCore, TDD)

**Files:**
- Create: `Sources/PastefixAppCore/Upload/ZiplineTokenStore.swift`
- Create: `Tests/PastefixAppCoreTests/ZiplineTokenStoreTests.swift`

**Interfaces:**
- Produces: `ZiplineTokenStore` protocol (`token() throws -> String?`, `setToken(_:) throws`, `clearToken() throws`), `KeychainTokenStore`, `InMemoryTokenStore`. Tasks 6 and 7 use the protocol.

- [ ] **Step 1: Write the failing tests**

Only the contract and the fake are tested. `KeychainTokenStore` writes to the real login keychain, which a test suite must not do — the same judgement the repo already applies to GUI code.

```swift
import Testing
@testable import PastefixAppCore

@Suite("Zipline token store contract")
struct ZiplineTokenStoreTests {
    @Test("a fresh store has no token")
    func empty() throws {
        #expect(try InMemoryTokenStore().token() == nil)
    }

    @Test("set then read round-trips")
    func roundTrip() throws {
        let store = InMemoryTokenStore()
        try store.setToken("tok_abc")
        #expect(try store.token() == "tok_abc")
    }

    @Test("set replaces rather than accumulating")
    func replace() throws {
        let store = InMemoryTokenStore()
        try store.setToken("first")
        try store.setToken("second")
        #expect(try store.token() == "second")
    }

    @Test("clear removes it")
    func clear() throws {
        let store = InMemoryTokenStore()
        try store.setToken("tok_abc")
        try store.clearToken()
        #expect(try store.token() == nil)
    }

    @Test("an empty string is stored as no token")
    func emptyStringIsNil() throws {
        // The Settings field is a text field; blanking it must mean "remove",
        // not "the token is the empty string", which would fail as a 401 later.
        let store = InMemoryTokenStore()
        try store.setToken("tok_abc")
        try store.setToken("")
        #expect(try store.token() == nil)
    }
}
```

- [ ] **Step 2: Run to verify they fail**

```bash
swift test --filter ZiplineTokenStoreTests 2>&1 | tail -5
```
Expected: FAIL — `cannot find 'InMemoryTokenStore' in scope`.

- [ ] **Step 3: Write the implementation**

```swift
import Foundation
import Security

/// Where the Zipline API token lives. A protocol because the Keychain
/// conformer cannot be unit-tested without writing to a real login keychain.
public protocol ZiplineTokenStore: Sendable {
    func token() throws -> String?
    func setToken(_ token: String) throws
    func clearToken() throws
}

public enum TokenStoreError: Error, Equatable {
    case keychain(OSStatus)
}

/// Generic-password item under a fixed service. The token is the one piece of
/// Pastefix's configuration that must not sit in `UserDefaults` JSON, which is
/// readable by anything running as this user.
public struct KeychainTokenStore: ZiplineTokenStore {
    public static let service = "net.scromp.Pastefix.zipline"
    private let account = "api-token"

    public init() {}

    private var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: Self.service,
         kSecAttrAccount as String: account]
    }

    public func token() throws -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw TokenStoreError.keychain(status) }
        guard let data = item as? Data, let string = String(data: data, encoding: .utf8),
              !string.isEmpty else { return nil }
        return string
    }

    public func setToken(_ token: String) throws {
        guard !token.isEmpty else { return try clearToken() }
        let data = Data(token.utf8)
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(baseQuery as CFDictionary, update as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw TokenStoreError.keychain(status) }
        var insert = baseQuery
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        let added = SecItemAdd(insert as CFDictionary, nil)
        guard added == errSecSuccess else { throw TokenStoreError.keychain(added) }
    }

    public func clearToken() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw TokenStoreError.keychain(status)
        }
    }
}

/// Tests, and any context that must not touch the real keychain.
public final class InMemoryTokenStore: ZiplineTokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: String?

    public init() {}

    public func token() throws -> String? {
        lock.lock(); defer { lock.unlock() }
        return stored
    }

    public func setToken(_ token: String) throws {
        lock.lock(); defer { lock.unlock() }
        stored = token.isEmpty ? nil : token
    }

    public func clearToken() throws {
        lock.lock(); defer { lock.unlock() }
        stored = nil
    }
}
```

> **Historical — `kSecAttrAccessible` is not set in the shipped store.** The
> attribute is honoured only by the data-protection keychain, and this query
> targets the legacy login keychain, so setting it stated an intent the item does
> not carry. `KeychainTokenStore`'s doc comment records the measurements behind
> dropping it and what the item does carry instead (an ACL bound to the signing
> identity). This plan is kept as written.

- [ ] **Step 4: Run to verify they pass**

```bash
swift test --filter ZiplineTokenStoreTests 2>&1 | tail -5
```
Expected: PASS, 5 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/PastefixAppCore/Upload Tests/PastefixAppCoreTests/ZiplineTokenStoreTests.swift
git commit -m "feat(appcore): Keychain-backed Zipline token store behind a protocol (#14)

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 5: Settings (AppCore, TDD)

**Files:**
- Modify: `Sources/PastefixAppCore/SettingsStore.swift` (properties, `Key` cases, `init`)
- Create: `Tests/PastefixAppCoreTests/ZiplineSettingsTests.swift`

**Interfaces:**
- Consumes: `ZiplineExpiry` (Task 2) — stored as its raw string form, not the enum, so a settings file stays readable and a future case cannot break decoding.
- Produces: `SettingsStore.ziplineServerURL: String`, `.ziplineDefaultExpiry: String`, `.ziplineDefaultBurnOnRead: Bool`, `.ziplineDefaultExtension: String`, and `SettingsStore.expiry(fromRaw:) -> ZiplineExpiry`.

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
import Foundation
@testable import PastefixAppCore
@testable import PastefixCore

@Suite("Zipline settings")
struct ZiplineSettingsTests {
    private func store() -> SettingsStore {
        let suite = "net.scromp.Pastefix.tests.\(UUID().uuidString)"
        return SettingsStore(defaults: UserDefaults(suiteName: suite)!)
    }

    @Test("defaults are empty server, 1d expiry, no burn, txt")
    func defaults() {
        let s = store()
        #expect(s.ziplineServerURL.isEmpty)
        #expect(s.ziplineDefaultExpiry == "1d")
        #expect(s.ziplineDefaultBurnOnRead == false)
        #expect(s.ziplineDefaultExtension == "txt")
    }

    @Test("values persist across instances")
    func persists() {
        let suite = "net.scromp.Pastefix.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let first = SettingsStore(defaults: defaults)
        first.ziplineServerURL = "https://zip.example.test"
        first.ziplineDefaultExpiry = "7d"
        first.ziplineDefaultBurnOnRead = true
        first.ziplineDefaultExtension = "md"

        let second = SettingsStore(defaults: defaults)
        #expect(second.ziplineServerURL == "https://zip.example.test")
        #expect(second.ziplineDefaultExpiry == "7d")
        #expect(second.ziplineDefaultBurnOnRead == true)
        #expect(second.ziplineDefaultExtension == "md")
    }

    @Test("raw expiry strings map to the enum")
    func expiryMapping() {
        #expect(SettingsStore.expiry(fromRaw: "never") == .never)
        #expect(SettingsStore.expiry(fromRaw: "7d") == .relative("7d"))
        // An unrecognised value must not become "never" — that would silently
        // turn a corrupted setting into a permanent upload.
        #expect(SettingsStore.expiry(fromRaw: "nonsense") == .relative("1d"))
    }

    @Test("the token is not a settings key")
    func tokenIsNotInDefaults() {
        let suite = "net.scromp.Pastefix.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let s = SettingsStore(defaults: defaults)
        s.ziplineServerURL = "https://zip.example.test"
        let keys = defaults.dictionaryRepresentation().keys
        #expect(!keys.contains { $0.lowercased().contains("token") })
    }
}
```

- [ ] **Step 2: Run to verify they fail**

```bash
swift test --filter ZiplineSettingsTests 2>&1 | tail -5
```
Expected: FAIL — `value of type 'SettingsStore' has no member 'ziplineServerURL'`.

- [ ] **Step 3: Write the implementation**

Add to `SettingsStore`, matching the existing `@Published … didSet` shape exactly:

```swift
    /// The Zipline instance to upload to. Not a secret, so it lives here with
    /// everything else; the token is in the Keychain (`KeychainTokenStore`).
    @Published public var ziplineServerURL: String { didSet { defaults.set(ziplineServerURL, forKey: Key.ziplineServer) } }
    /// Stored as the raw string ("never", "1h", "1d", "7d") rather than an
    /// encoded enum, so the settings file stays readable and adding a case
    /// later cannot fail to decode an old value.
    @Published public var ziplineDefaultExpiry: String { didSet { defaults.set(ziplineDefaultExpiry, forKey: Key.ziplineExpiry) } }
    @Published public var ziplineDefaultBurnOnRead: Bool { didSet { defaults.set(ziplineDefaultBurnOnRead, forKey: Key.ziplineBurn) } }
    @Published public var ziplineDefaultExtension: String { didSet { defaults.set(ziplineDefaultExtension, forKey: Key.ziplineExtension) } }
```

In `init`:

```swift
        self.ziplineServerURL = defaults.string(forKey: Key.ziplineServer) ?? ""
        self.ziplineDefaultExpiry = defaults.string(forKey: Key.ziplineExpiry) ?? "1d"
        self.ziplineDefaultBurnOnRead = (defaults.object(forKey: Key.ziplineBurn) as? Bool) ?? false
        self.ziplineDefaultExtension = defaults.string(forKey: Key.ziplineExtension) ?? "txt"
```

In `Key`:

```swift
        static let ziplineServer = "pastefix.zipline.serverURL"
        static let ziplineExpiry = "pastefix.zipline.defaultExpiry"
        static let ziplineBurn = "pastefix.zipline.defaultBurnOnRead"
        static let ziplineExtension = "pastefix.zipline.defaultExtension"
```

And the mapper, as a static on `SettingsStore`:

```swift
    /// Raw setting → the request value. An unrecognised string falls back to
    /// the default expiry, never to `.never`: a corrupted setting must not
    /// quietly make uploads permanent.
    public static func expiry(fromRaw raw: String) -> ZiplineExpiry {
        switch raw {
        case "never": return .never
        case "1h", "1d", "7d": return .relative(raw)
        default: return .relative("1d")
        }
    }
```

`SettingsStore.swift` will need `import PastefixCore` if it does not already have one.

- [ ] **Step 4: Run to verify they pass**

```bash
swift test --filter ZiplineSettingsTests 2>&1 | tail -5
swift test 2>&1 | tail -1     # whole suite still green
```
Expected: PASS, 4 tests; suite total now roughly 438 + 24.

- [ ] **Step 5: Commit**

```bash
git add Sources/PastefixAppCore/SettingsStore.swift Tests/PastefixAppCoreTests/ZiplineSettingsTests.swift
git commit -m "feat(appcore): Zipline server URL and upload defaults in settings (#14)

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 6: The upload overlay and ⌘⇧U (app target, GUI pass)

**Files:**
- Create: `Pastefix/Pastefix/UploadOverlayView.swift`
- Modify: `Pastefix/Pastefix/HotkeyName.swift` (add `uploadToZipline`)
- Modify: `Pastefix/Pastefix/AppModel.swift` (add `uploadOverlayRequested`)
- Modify: `Pastefix/Pastefix/PanelView.swift` (third overlay, alongside the palette and history at `:133`/`:138`)
- Modify: `Pastefix/Pastefix/PastefixApp.swift` (register the hotkey; a `summonUpload()` beside `summonHistory()`)

**Interfaces:**
- Consumes: `ZiplineUploading`, `URLSessionZiplineClient`, `ZiplineUpload`, `ZiplineExpiry`, `ZiplineUploadError`, `SecretDisposition`, `UploadPayload.text(_:matches:disposition:)`, `ZiplineUpload.defaultExtension(for:)` (Tasks 2–3); `ZiplineTokenStore`, `KeychainTokenStore` (Task 4); the four `SettingsStore` properties and `SettingsStore.expiry(fromRaw:)` (Task 5); `SecretDetector.scan(_:)`, `SecretMatch.kind.displayName`; `ClipboardBridge.writePlain(_:)`.
- Produces: `UploadOverlayView`, `AppModel.uploadOverlayRequested`, `PastefixApp.summonUpload()`.

No unit tests — the app target has none, and this is not the change that starts that (spec, Testing). Verification is the manual pass in Step 5.

- [ ] **Step 1: Hotkey and request flag**

`HotkeyName.swift`, following the two already there:

```swift
    /// Opens the panel straight into the Zipline upload overlay. Default ⌘⇧U;
    /// rebindable in Settings. No dots in the name — `KeyboardShortcuts` will
    /// not take them (AGENTS.md, Plan 9).
    static let uploadToZipline = Self("uploadToZipline", default: .init(.u, modifiers: [.command, .shift]))
```

`AppModel.swift`, beside `historyOverlayRequested`:

```swift
    /// One-shot, cleared as it is consumed, exactly like `historyOverlayRequested`.
    @Published var uploadOverlayRequested = false
```

`PastefixApp.swift`, beside `summonHistory()`:

```swift
    /// ⌘⇧U: show the panel (starting a session from the current clipboard if
    /// none) with the upload overlay open.
    func summonUpload() {
        if model.document == nil { summon() } else { lastSummonAt = Date(); panel?.show() }
        model.uploadOverlayRequested = true
    }
```

Register it where `summonHistory` is registered.

- [ ] **Step 2: Build the overlay**

Model it on `HistoryOverlayView`: same backdrop, card, metrics and footer; every handler reads `@State` at call time, never a value captured while `body` ran (the ⌘K Return bug, `7f67d41`).

State machine, and the order matters:

1. **`configure`** — entered before anything else when `settings.ziplineServerURL` is empty or `tokenStore.token()` is nil. A line of explanation and a button that opens Settings. No scan is started, no controls are shown.
2. **`composing`** — the normal state. Controls live immediately:
   - Expiration: Never / 1 h / 1 d / 7 d, seeded from `settings.ziplineDefaultExpiry` via `SettingsStore.expiry(fromRaw:)`.
   - Burn on read: a toggle, seeded from `settings.ziplineDefaultBurnOnRead`. **Separate from expiration** — it is `x-zipline-max-views`, not an expiry value.
   - Extension: seeded from `ZiplineUpload.defaultExtension(for: text)`, overridable.
     (Historical: it shipped taking `Set<ContentKind>?` and answering `json` or
     `txt` only — see the spec.)
   - A secret row, which is one of: nothing yet (under ~150 ms), "Checking for secrets…", "No secrets found", or the finding list.
   - Upload is **disabled until the scan resolves**.
3. **`uploading`** — Upload replaced by progress; controls disabled.
4. **`done(URL)`** — the short URL with Copy and Open, then dismiss.
5. **`failed(ZiplineUploadError)`** — the message, controls still live, Retry in place.

The scan:

```swift
// Detached because SecretDetector.scan is synchronous and, on the upload path,
// uncapped — see the Task 1 measurement. Only a String crosses.
let text = document
scanTask = Task { @MainActor in
    let matches = await Task.detached(priority: .userInitiated) {
        SecretDetector.scan(text)
    }.value
    guard !Task.isCancelled else { return }
    self.scanState = matches.isEmpty ? .clean : .found(matches)
}
```

The ~150 ms rule: start a second task that sets `showScanProgress = true` after 150 ms and is cancelled when the scan resolves — so a small paste never flickers a loading row, and no size threshold has to be invented.

**Dismissing mid-scan cancels the wrapper but not the scan itself** — `SecretDetector` has no cancellation point. Say that in a comment at the call site and do not describe the cancel as a bound. This is the #46 lesson, restated: serialising or cancelling the wrapper is not the same as bounding the work.

Upload:

```swift
let payload = UploadPayload.text(document, matches: foundMatches, disposition: disposition)
let request = ZiplineUpload(text: payload,
                            fileExtension: chosenExtension,
                            expiry: chosenExpiry,
                            burnOnRead: burnOnRead)
let url = try await uploader.upload(request, to: serverURL, token: token)
ClipboardBridge.writePlain(url.absoluteString)
```

`disposition` defaults to `.redact` when matches were found — the safe choice is the one Return gives you.

- [ ] **Step 3: Wire it into `PanelView`**

Add the third branch beside `CommandPaletteView` (`:133`) and `HistoryOverlayView` (`:138`), with an `onChange(of: model.uploadOverlayRequested)` handler that mirrors the history one at `:202` — including clearing the flag as it is consumed.

- [ ] **Step 4: Build**

```bash
xcodebuild -project Pastefix/Pastefix.xcodeproj -scheme Pastefix -configuration Debug build 2>&1 | tail -3
```
Expected: `** BUILD SUCCEEDED **`. Two pre-existing deprecation warnings in `HotkeyName.swift` are expected; anything else is yours.

- [ ] **Step 5: Manual pass (controller, with the user's permission)**

Against a real Zipline v4 instance:

1. ⌘⇧U with no server configured → configure state, button opens Settings.
2. ⌘⇧U with plain text → overlay, "No secrets found", Upload → clipboard holds the short URL, and the URL opens.
3. ⌘⇧U with an AWS key in the text → findings listed by name, Redact preselected; upload and confirm **the fetched page does not contain the key** and the local document still does.
4. Send as-is on the same text → the page contains the key. (The escape hatch must actually work.)
5. Burn on read → fetch the URL twice; the second fetch 404s.
6. Expiry beyond the server's `maxExpiration` → the `bad options[x-zipline-deletes-at]` message appears against the expiration control and the upload is retryable after changing it.
7. Wrong token → "token rejected", not a generic failure.
8. Server URL on a LAN/Tailscale address → works. (If this fails, `isFetchable` has been wired in by mistake.)
9. A >256 KB paste → the "Checking for secrets…" row appears, then resolves.
10. Dismiss mid-scan on a large paste → no crash, no stuck state.

- [ ] **Step 6: Commit**

```bash
git add Pastefix/Pastefix/UploadOverlayView.swift Pastefix/Pastefix/HotkeyName.swift \
        Pastefix/Pastefix/AppModel.swift Pastefix/Pastefix/PanelView.swift \
        Pastefix/Pastefix/PastefixApp.swift
git commit -m "feat(app): ⌘⇧U upload overlay with an inline secret gate (#14)

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 7: Upload settings tab (app target, GUI pass)

**Files:**
- Create: `Pastefix/Pastefix/UploadSettingsView.swift`
- Modify: `Pastefix/Pastefix/SettingsView.swift` (add the tab)

**Interfaces:**
- Consumes: the four `SettingsStore` properties (Task 5); `ZiplineTokenStore` (Task 4).
- Produces: `UploadSettingsView`.

- [ ] **Step 1: Build the tab**

Follow `PresetsSettingsView` for layout, and AGENTS.md's Plan 7 lesson for controls: a `Form` puts a titled `Stepper`'s label in the leading gutter, so use `HStack { Text; Spacer; control }`.

- Server URL: a `TextField`, trimmed on commit. Show a validation line if it does not parse as an `http`/`https` URL — but **do not** reject private hosts.
- API token: a `SecureField`. It writes to `KeychainTokenStore` on commit, never to `SettingsStore`. Show placeholder text reflecting whether a token is currently stored ("Stored" / "None") rather than reading the value back into the field.
- A Clear token button.
- Defaults: expiration picker, burn-on-read toggle, extension field — the values the overlay opens with.

**The token must never be written to `UserDefaults`, printed, or logged**, including in a debug `print`. Task 5's `tokenIsNotInDefaults` test guards the settings half; this view is the other half and has no test, so it needs the care.

- [ ] **Step 2: Build**

```bash
xcodebuild -project Pastefix/Pastefix.xcodeproj -scheme Pastefix -configuration Debug build 2>&1 | tail -3
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Manual pass**

1. Enter a token, quit and relaunch the app → the overlay no longer shows the configure state (the token survived in the Keychain).
2. `defaults read net.scromp.Pastefix | grep -i token` → **no output**. If the token appears here, stop and fix it before going further.
3. Clear token → the overlay returns to the configure state.
4. Change a default → ⌘⇧U opens with it preselected.

- [ ] **Step 4: Commit**

```bash
git add Pastefix/Pastefix/UploadSettingsView.swift Pastefix/Pastefix/SettingsView.swift
git commit -m "feat(app): Upload settings tab with Keychain-backed token (#14)

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 8: Documentation and PR

**Files:**
- Modify: `AGENTS.md` (file map, plan table row, architecture principle, review lessons)
- Modify: `docs/plans/2026-09-22-pastefix-v2-zipline-upload.md` (status banner)

- [ ] **Step 1: AGENTS.md**

- File map: the five new source files with one-line responsibilities.
- Plan table: add `| 13 — Zipline upload | ZiplineClient, upload overlay, Keychain token, Upload tab | 🟡 in progress, branch feat/zipline-upload — [spec](…), [plan](…) |`.
- Architecture principles: one entry for the rule this feature establishes — **the clipboard leaves the machine only through a surface that has scanned it, and "not scanned" is never "clean"**. Any future upload or share path owes the same gate.
- Lessons: record what Task 1 measured, and the three v4 corrections (the `x-zipline-format` trap especially — it reads like a syntax-highlighting header and is not).

- [ ] **Step 2: Full verification before the PR**

```bash
swift test 2>&1 | tail -1
xcodebuild -project Pastefix/Pastefix.xcodeproj -scheme Pastefix -configuration Debug build 2>&1 | tail -3
```
Both must be green. Paste the real output into the PR body — no claims without it.

- [ ] **Step 3: Open the PR**

```bash
git push -u origin feat/zipline-upload
gh pr create --title "feat: Zipline text/code upload (#14)" --body "$(cat <<'EOF'
⌘⇧U uploads the working text to a self-hosted Zipline v4 instance and replaces
the clipboard with the short URL, through one overlay that owns expiration,
burn-on-read, file extension, an inline secret verdict, the upload, the result
and every error.

**Three corrections to the issue**, from reading diced/zipline v4.7.0 rather
than the original requirements:

- `x-zipline-format` is the server's *filename* format, not syntax
  highlighting — v4 highlights by file extension, so the "language" control
  sets the extension.
- Burn-on-read is `x-zipline-max-views: 1`, a separate header from
  `x-zipline-deletes-at`. The issue listed them as one control.
- No notification: the repo has no notification infrastructure, and the
  overlay is already on screen when the upload lands.

**The secret gate.** Every upload is scanned in full, off the main actor —
`SecretDetector.maxBytes` exists because scanning runs on every summon and
capture, which an upload is not. Redact is preselected, and redaction applies
only to the uploaded copy; the document and clipboard are never rewritten.

**Measured** (Task 1): <paste the real cost curve here>.

**Manual pass**: <paste the ten results from Task 6 Step 5 here>.

**Verification**: <paste the real swift test and xcodebuild output here>.

Closes #14.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

The three angle-bracket lines are the only things left to fill, and they take
real output — not a summary of it.

- [ ] **Step 4: After merge — the docs-only stamping PR**

Repo convention (PR #45, #47): a separate `docs/` branch flipping the plan banner to ✅, the spec frontmatter `status:` to `implemented`, and the AGENTS.md table row to merged with the PR number and commit. Also strike the notification bullet from issue #14's body, which this plan deliberately does not implement.

---

## Notes for the implementer

- **Task 1 is a gate, not a formality.** If 4 MB does not scan in about two seconds, stop and say so. Tasks 2 and 6 change.
- **Never treat a 2xx as success without `files[0].url`.** The spec's `malformedResponse` exists because a silent empty success here means the user believes something was shared that was not.
- **The token is the one value in this repo that must not be logged.** Zipline quotes request headers back in error messages; log response bodies `privacy: .private` if you log them at all.
- **Do not reuse `MarkdownLink.isFetchable`.** It looks like exactly the guard this needs and is exactly wrong here: it blocks private IPs because *there* the URL comes from clipboard content, while here it is one the user typed into Settings. Wiring it in breaks every self-hosted setup.
