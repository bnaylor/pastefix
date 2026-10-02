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
        // Up to three curves, passing on the first that's linear: scheduling noise from the parallel
        // suite spoils some measurements (#132: 36–45x against the 32x bound under heavy load), while
        // the superlinear cost this guards against is 256x on every curve.
        var best = Double.infinity
        for _ in 0..<3 {
            guard let growth = measureCurve() else { return }
            if growth <= 2 { return }
            best = min(best, growth)
        }
        Issue.record("on three curves the time grew at least \(best)x faster than the input — that is superlinear")
    }

    /// One scale curve's cost growth relative to its size growth (time ratio ÷ byte ratio, largest
    /// input over smallest): ~1 is linear, 2 is the bound, quadratic is ~16. Nil after recording a
    /// clock problem.
    private func measureCurve() -> Double? {
        var measurements: [(bytes: Int, seconds: Double)] = []
        for multiple in [1, 4, 16] {
            let text = realisticCorpus(bytes: SecretDetector.maxBytes * multiple)
            // The fastest of three: scheduling noise from the parallel suite only ever adds time, so
            // the minimum is the cleanest reading. One noisy pass on the small input pushed the ratio
            // to 45x against the 32x bound under load (#132).
            var seconds = Double.infinity
            var matches: [SecretMatch] = []
            for _ in 0..<3 {
                let start = ContinuousClock.now
                matches = SecretDetector.scanIgnoringSizeCap(text)
                let elapsed = ContinuousClock.now - start
                seconds = min(seconds, Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18)
            }
            measurements.append((text.utf8.count, seconds))
            // A sanity check on the corpus, not on the cap: `pastTheCapIsActuallyScanned`
            // below is what asserts the scan reaches bytes past `maxBytes`. This corpus's
            // first secret is in its first ~300 bytes, so on its own it proves nothing
            // about that.
            #expect(!matches.isEmpty, "the corpus is supposed to contain secrets")
        }
        for m in measurements {
            print("SecretDetector.scanIgnoringSizeCap: \(m.bytes) bytes in \(String(format: "%.3f", m.seconds)) s")
        }
        // **A ratio, not a stopwatch reading.** The property this test exists to catch is
        // superlinear cost, and that is machine-independent: a 16x input costs about 16x on
        // any machine, while the regression being guarded against (`NSRegularExpression` over
        // a multi-MB `NSString`, or the JWT backtracking of Plan 11) costs 256x or worse. The
        // absolute figure is not machine-independent — the 2.0 s bound this replaces was
        // measured at 0.85 s on an M4 Max debug build, ~2.3x headroom, which is a coin toss on
        // a loaded CI runner or an Intel machine and says nothing about the shape of the curve.
        // So the absolute numbers stay as printed output above and the assertion is on growth.
        //
        // 2x linear, not the 1.5x a review suggested, for one reason: both measurements are
        // wall clock taken while the other 65 suites run in parallel, so each carries
        // scheduling noise in the same direction. Quadratic is 256x — 8x clear of this bound —
        // so the slack costs nothing the test was ever able to catch.
        let base = measurements.first!
        let largest = measurements.last!
        let sizeRatio = Double(largest.bytes) / Double(base.bytes)
        guard base.seconds > 0 else {
            Issue.record("the \(base.bytes)-byte scan measured 0 s; the clock is not usable here")
            return nil
        }
        let costRatio = largest.seconds / base.seconds
        print("SecretDetector.scanIgnoringSizeCap: \(String(format: "%.1f", sizeRatio))x the bytes "
              + "cost \(String(format: "%.1f", costRatio))x the time")
        return costRatio / sizeRatio
    }

    /// The claim `scanIgnoringSizeCap` exists to make: it reads *past* 256 KB.
    ///
    /// The `scaleCurve` corpus could not show this. Its first secret sits in the first ~300
    /// bytes, so `!matches.isEmpty` passed whether the scanner examined 4 MB or stopped at
    /// `maxBytes` — which is the whole point of the entry point. This puts a known key *after*
    /// the cap and asserts where it was found, and pairs with `SecretDetectorTests.boundedCost`,
    /// which asserts the capped `scan` returns `[]` for the same shape.
    @Test("a secret past maxBytes is found, and found past maxBytes")
    func pastTheCapIsActuallyScanned() {
        // ASCII throughout, so a UTF-8 offset and a character offset are the same number.
        let filler = String(repeating: "a", count: SecretDetector.maxBytes)
        let text = filler + " AKIAIOSFODNN7EXAMPLE"
        #expect(text.utf8.count > SecretDetector.maxBytes)

        let matches = SecretDetector.scanIgnoringSizeCap(text)
        let keys = matches.filter { $0.kind == .awsAccessKey }
        #expect(keys.count == 1)
        guard let key = keys.first else { return }
        let offset = text.utf8.distance(from: text.utf8.startIndex, to: key.range.lowerBound)
        // The literal, not just the constant: a scan that stopped at the cap could only ever
        // report an offset below this one.
        #expect(offset > 262_144)
        #expect(offset == SecretDetector.maxBytes + 1)   // the separating space

        // The mirror, so the pair states the whole rule: the capped entry point refuses the same
        // buffer outright rather than reporting the key it never looked for.
        #expect(SecretDetector.scan(text).isEmpty)
    }
}
