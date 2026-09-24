import Foundation

/// What an upload is allowed to be: one size ceiling, and the two timeouts that have to agree
/// with it.
///
/// **Why there is a ceiling at all.** Nothing bounded this path. `source` is whatever the
/// clipboard held; the overlay scans it with `SecretDetector.scanIgnoringSizeCap` (a
/// straight-line run with no cancellation point, on a detached pool thread), `SecretRedactor`
/// builds a second full copy of it, and the client builds a third as the multipart body. At the
/// measured 0.85 s per 4 MB, a 100 MB paste is ~20 s of an *uncancellable* thread and roughly
/// 3× its size resident — and dismissing the overlay drops the result without stopping the work,
/// so a second ⌘⇧U starts another one alongside it. This repo's rule is that input caps bound
/// the work and the deadline bounds the wait; every other `SecretDetector` consumer already has
/// a cap, and this path had none.
///
/// **An over-cap buffer is refused, never quietly cleared.** That is the whole point: a cap on a
/// safety feature must never produce a clean verdict on bytes nobody looked at (Critical
/// Invariant 13, and the PR #42 lesson before it). The overlay states the actual size and this
/// limit, and Upload stays disabled — nothing is scanned and nothing is sent.
public enum UploadLimits {
    /// 16 MB of *text*. Generous for a paste — a 16 MB buffer is on the order of two million
    /// words — while bounding what the cap actually buys:
    ///
    /// - **Work:** ~3.4 s of an uncancellable detached scan at the measured 0.85 s/4 MB, rather
    ///   than the unbounded ~20 s a 100 MB paste cost.
    /// - **Memory:** ~3× resident at the peak (source + redacted copy + multipart body), so
    ///   ~48 MB, not ~300 MB.
    /// - **Transfer:** it has to be *sendable*, which is what `resourceTimeout` below exists to
    ///   guarantee. A cap that admits a size the client cannot finish sending is not a cap, it
    ///   is a slower failure.
    public static let maxPayloadBytes = 16 * 1_048_576

    /// The **idle** timeout: `timeoutIntervalForRequest`, which URLSession restarts every time
    /// bytes move. 60 s of *nothing happening* is a stalled request, whatever the body's size —
    /// so this one is deliberately not scaled by the payload.
    public static let idleTimeout: TimeInterval = 60

    /// The **whole-transfer** timeout: `timeoutIntervalForResource`, which is a wall clock over
    /// the entire request and does not restart on progress.
    ///
    /// This used to be 60 s as well, sharing a single `timeout` with the idle bound, which meant
    /// the path admitted sizes the client could not finish sending: a 30 MB body on a slow
    /// uplink was cancelled mid-send and surfaced as `.transport` with Retry — which would fail
    /// the same way — as the only remedy. The two bounds answer different questions and now hold
    /// different values.
    ///
    /// 600 s against a 16 MB ceiling is a floor of ~27 kB/s (~218 kbit/s) sustained: slower than
    /// that and the transfer is abandoned, and anything that stops moving entirely is caught by
    /// the 60 s idle bound long before this one. `minimumThroughputBytesPerSecond` states that
    /// relationship in one place, and `UploadLimitsTests` asserts the pair stays consistent, so
    /// raising the cap without raising this is a test failure rather than a field report.
    public static let resourceTimeout: TimeInterval = 600

    /// The most of a *reply* this client will read before giving up on it.
    ///
    /// A Zipline `{"files":[{"url":"…"}]}` body is a few hundred bytes. The server URL, though,
    /// is a free-text field: point it at a file host, a captive portal, or a proxy and what
    /// comes back is an HTML page of arbitrary size, which `session.data(for:)` buffered in
    /// full before `shortURL(from:)` got to reject it. This repo's network pattern is a hard
    /// timeout *and* a byte cap (`URLSessionTitleFetcher.maxBytes`, same 256 KB), so the read
    /// is streamed and stops here.
    ///
    /// Deliberately not derived from `expectedContentLength`: it is `-1` for any chunked
    /// response, and it is a number the other end chose. The cap is enforced against the bytes
    /// actually delivered.
    public static let maxResponseBytes = 262_144

    /// The slowest uplink on which the largest admissible upload can still finish. The cap and
    /// the resource timeout are two ways of saying this number; it exists so that changing
    /// either one has to be an argument about it.
    public static var minimumThroughputBytesPerSecond: Double {
        Double(maxPayloadBytes) / resourceTimeout
    }
}
