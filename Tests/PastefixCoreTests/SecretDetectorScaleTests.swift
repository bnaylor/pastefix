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
    /// without a cap via `scanIgnoringSizeCap`, so a regression into
    /// superlinear cost must fail here rather than freeze an overlay.
    ///
    /// Calls `scanIgnoringSizeCap` once per size, on the whole corpus, unlike
    /// the chunked measurement this replaced: chunking every call at
    /// `maxBytes` made the total mechanically `chunks x constant` and could
    /// not have detected superlinear cost, which is the one thing this test
    /// exists to catch (`NSRegularExpression` over a multi-MB `NSString` is
    /// the specific risk — it need not behave like N calls over 1/N-sized
    /// ones).
    @Test("uncapped scan cost stays linear well past maxBytes", .timeLimit(.minutes(1)))
    func scaleCurve() {
        var measurements: [(bytes: Int, seconds: Double)] = []
        for multiple in [1, 4, 16] {
            let text = realisticCorpus(bytes: SecretDetector.maxBytes * multiple)
            let start = ContinuousClock.now
            let matches = SecretDetector.scanIgnoringSizeCap(text)
            let elapsed = ContinuousClock.now - start
            let seconds = Double(elapsed.components.seconds)
                + Double(elapsed.components.attoseconds) / 1e18
            measurements.append((text.utf8.count, seconds))
            #expect(!matches.isEmpty, "the corpus is supposed to contain secrets")
        }
        for m in measurements {
            print("SecretDetector.scanIgnoringSizeCap: \(m.bytes) bytes in \(String(format: "%.3f", m.seconds)) s")
        }
        // 4 MB is the largest paste this flow should ever meet without the user
        // noticing they did something unusual. Two seconds is the point past
        // which a spinner is a lie and the overlay needs real progress.
        let largest = measurements.last!
        #expect(largest.seconds < 2.0,
                "scan of \(largest.bytes) bytes took \(largest.seconds)s — see Task 1 decision gate")
    }
}
