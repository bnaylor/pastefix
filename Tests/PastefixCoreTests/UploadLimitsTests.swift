import Testing
import Foundation
@testable import PastefixCore

/// The cap and the timeouts are one decision, so they are asserted together: the point of these
/// tests is that raising the size ceiling without giving the transfer time to match it fails
/// here rather than in the field, as a body cancelled mid-send and reported as `.transport`.
@Suite("Upload limits")
struct UploadLimitsTests {
    @Test("the payload cap is a deliberate, stated size")
    func capIsInRange() {
        // Generous for a text paste and small enough that the uncancellable scan it admits stays
        // in seconds (measured 0.85 s per 4 MB → ~3.4 s at this cap).
        #expect(UploadLimits.maxPayloadBytes == 16 * 1_048_576)
        #expect(ByteLimit.describe(UploadLimits.maxPayloadBytes) == "16 MB")
    }

    @Test("the idle timeout bounds inactivity, not the body")
    func idleTimeout() {
        // Deliberately not scaled by the payload: URLSession restarts this whenever bytes move,
        // so it answers "has this stalled?", which has the same answer at 1 KB and at 16 MB.
        #expect(UploadLimits.idleTimeout == 60)
    }

    @Test("the whole-transfer timeout can actually send the largest admitted upload")
    func resourceTimeoutAgreesWithTheCap() {
        // `timeoutIntervalForResource` does not restart on progress, so `maxPayloadBytes` has to
        // fit inside it at a throughput a slow-but-real uplink can sustain. 32 kB/s (~256 kbit/s)
        // is the bar: below that we would be cancelling transfers that were making progress the
        // whole time, which is exactly the failure this pairing exists to prevent.
        #expect(UploadLimits.minimumThroughputBytesPerSecond <= 32_768)
        #expect(UploadLimits.resourceTimeout > UploadLimits.idleTimeout)
        // Stated the other way round as well, so the relationship is readable in the failure
        // message rather than only in the ratio.
        #expect(Double(UploadLimits.maxPayloadBytes) / UploadLimits.minimumThroughputBytesPerSecond
                == UploadLimits.resourceTimeout)
    }

    @Test("the client takes its defaults from the limits, and keeps them apart")
    func clientDefaults() {
        let client = URLSessionZiplineClient()
        #expect(client.timeout == UploadLimits.idleTimeout)
        #expect(client.resourceTimeout == UploadLimits.resourceTimeout)
        // The bug this replaced: one `timeout` value feeding both `timeoutIntervalForRequest`
        // and `timeoutIntervalForResource`.
        #expect(client.timeout != client.resourceTimeout)
    }
}
