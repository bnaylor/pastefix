import Testing
import Foundation
import Darwin
@testable import PastefixCore

/// #64: the 16 MB upload ceiling was set by extrapolating the scan curve (256 KB → 4 MB). This
/// measures the whole text path at the ceiling — the uncapped scan, the redaction the overlay sizes
/// and uploads, and the multipart body — for time and peak memory.
///
/// Opt-in, one size per process, because peak footprint is per process and can't be reset:
///
///     for mb in 1 4 16; do PASTEFIX_MEASURE_MB=$mb swift test --filter UploadPathMeasurement; done
///
/// `PASTEFIX_MEASURE_CORPUS=mixed` swaps the ASCII log corpus for one with non-ASCII prose, which
/// takes the confusable fold's slow path (#102).
@Suite("upload path at the ceiling (#64 measurement)")
struct UploadPathMeasurement {
    static let megabytes = ProcessInfo.processInfo.environment["PASTEFIX_MEASURE_MB"].flatMap(Int.init)
    static let mixed = ProcessInfo.processInfo.environment["PASTEFIX_MEASURE_CORPUS"] == "mixed"

    /// Resident memory as the kernel accounts it (what Activity Monitor shows), now and at its peak.
    static func footprint() -> (now: Int, peak: Int) {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return (0, 0) }
        return (Int(info.phys_footprint), Int(info.ledger_phys_footprint_peak))
    }

    /// The scale test's log corpus: identifier-heavy, a secret every ~400 bytes. `mixed` adds a line
    /// of Cyrillic and accented prose per unit.
    static func corpus(bytes: Int) -> String {
        var unit = """
        2026-09-22T10:15:03Z service=api region=us-east-1 request_id=7f3a9c21-4b0e-4a31-9d77-2c1e8f0b5a63
        user_id=48211 path=/v1/accounts/48211/settings status=200 duration_ms=37 cache=miss
        aws_access_key_id=AKIAIOSFODNN7EXAMPLE bucket=prod-assets-us-east-1 etag=d41d8cd98f00b204e9800998
        authorization=Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiI0ODIxMSIsIm5hbWUiOiJKb2huIn0.abc123
        """
        if mixed { unit += "\nПривет, это обычный текст — café, naïve, Ωmega; ещё одна строка для проверки." }
        var out = ""
        out.reserveCapacity(bytes + unit.utf8.count)
        while out.utf8.count < bytes { out += unit + "\n" }
        return out
    }

    static func seconds(_ d: Duration) -> Double {
        Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    }

    @Test(.enabled(if: megabytes != nil), .timeLimit(.minutes(5)))
    func measure() throws {
        let mb = Self.megabytes!
        let baseline = Self.footprint()
        let text = Self.corpus(bytes: mb * 1_048_576)
        let afterCorpus = Self.footprint()
        let clock = ContinuousClock()

        var matches: [SecretMatch] = []
        let scan = clock.measure { matches = SecretDetector.scanIgnoringSizeCap(text) }
        var redacted = ""
        let redact = clock.measure { redacted = UploadPayload.text(text, matches: matches, disposition: .redact) }
        var body = Data()
        let multipart = try clock.measure {
            let upload = try ZiplineUpload(text: redacted, fileExtension: "txt", expiry: .never, burnOnRead: true)
            body = URLSessionZiplineClient.multipartBody(for: upload, boundary: "measure")
        }
        let end = Self.footprint()
        #expect(!matches.isEmpty && !body.isEmpty)

        let m = { (b: Int) in String(format: "%.0f MB", Double(b) / 1_048_576) }
        print("""
        MEASURE \(mb) MB \(Self.mixed ? "mixed" : "ascii") corpus (\(text.utf8.count) bytes, \(matches.count) matches)
        MEASURE   scan \(String(format: "%.3f", Self.seconds(scan))) s · redact \(String(format: "%.3f", Self.seconds(redact))) s · multipart \(String(format: "%.3f", Self.seconds(multipart))) s
        MEASURE   footprint: baseline \(m(baseline.now)) · with corpus \(m(afterCorpus.now)) · end \(m(end.now)) · PEAK \(m(end.peak)) (peak over baseline \(m(end.peak - baseline.now)))
        """)
    }
}
