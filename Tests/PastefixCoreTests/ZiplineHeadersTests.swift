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
