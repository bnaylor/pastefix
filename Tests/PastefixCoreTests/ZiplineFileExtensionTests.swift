import Testing
import Foundation
@testable import PastefixCore

/// The "File type" field is the only free-text value on the upload path that reaches *protocol
/// framing*: it is interpolated into the multipart part's `Content-Disposition` filename and sent
/// as the `x-zipline-file-extension` header value. These tests pin down both halves of the fix —
/// that an unframeable value is refused at the single choke point (`ZiplineUpload.init`, via
/// `ZiplineFileExtension.canonical`), and that the ordinary values still go through unchanged.
@Suite("Zipline file extension framing")
struct ZiplineFileExtensionTests {
    private func request(_ ext: String) throws -> ZiplineUpload {
        try ZiplineUpload(text: "hello", fileExtension: ext, expiry: .never, burnOnRead: false)
    }

    // MARK: Refusals

    @Test("a quote in the extension is refused, not quoted or stripped")
    func quoteIsRefused() {
        // `filename="paste.tx"t"` ends the quoted string early: everything after the injected `"`
        // is read as further `Content-Disposition` parameters.
        #expect(ZiplineFileExtension.canonical(#"tx"t"#) == nil)
        #expect(throws: ZiplineUploadError.invalidFileExtension) { try request(#"tx"t"#) }
        // And the bare quote on its own, which is the shortest version of the same thing.
        #expect(throws: ZiplineUploadError.invalidFileExtension) { try request("\"") }
    }

    @Test("a CR LF in the extension is refused")
    func crlfIsRefused() {
        // Two injection sites, one value: in the multipart block this would add a header to the
        // file part; as `x-zipline-file-extension`'s value it would split the request's own header
        // block. Neither may be reachable from a text field.
        let injected = "txt\r\nx-zipline-max-views: 99"
        #expect(ZiplineFileExtension.canonical(injected) == nil)
        #expect(throws: ZiplineUploadError.invalidFileExtension) { try request(injected) }
        // A bare CR and a bare LF too: `trimmingCharacters(in: .whitespacesAndNewlines)` alone
        // removes them at the ends and leaves them anywhere else.
        #expect(throws: ZiplineUploadError.invalidFileExtension) { try request("t\nxt") }
        #expect(throws: ZiplineUploadError.invalidFileExtension) { try request("t\rxt") }
    }

    @Test("separators and spaces that corrupt the part are refused")
    func separatorsAreRefused() {
        for bad in ["a/b", "a\\b", "a;b", "a b", "a=b", "a:b", "a,b", "a\tb", "<b>", "%2e", "a\u{0}b"] {
            #expect(ZiplineFileExtension.canonical(bad) == nil, "\(bad) should be refused")
        }
    }

    @Test("empty, dots-only and over-long values are refused")
    func degenerateValuesAreRefused() {
        // Empty is nil here rather than `txt`: the UI layer owns "no preference" (a blank field is
        // seeded `txt`), and defaulting *here* would turn every rejected value into a silent
        // `paste.txt` — the substitution this whole change exists to avoid.
        #expect(ZiplineFileExtension.canonical("") == nil)
        #expect(ZiplineFileExtension.canonical("   ") == nil)
        #expect(ZiplineFileExtension.canonical("...") == nil)
        #expect(ZiplineFileExtension.canonical(String(repeating: "a", count: 17)) == nil)
        #expect(ZiplineFileExtension.canonical(String(repeating: "a", count: 16))
                == String(repeating: "a", count: 16))
    }

    @Test("non-ASCII is refused even when it looks like a letter")
    func nonASCIIIsRefused() {
        #expect(ZiplineFileExtension.canonical("täxt") == nil)
        // A grapheme cluster whose first scalar is allowed: the check asks for an ASCII value, so
        // the combining mark cannot ride along on the `a`.
        #expect(ZiplineFileExtension.canonical("a\u{0301}") == nil)
        #expect(ZiplineFileExtension.canonical("日本語") == nil)
    }

    // MARK: Ordinary values still work

    @Test("ordinary extensions pass through, canonicalised")
    func ordinaryValues() throws {
        #expect(ZiplineFileExtension.canonical("txt") == "txt")
        #expect(ZiplineFileExtension.canonical("swift") == "swift")
        #expect(ZiplineFileExtension.canonical("json") == "json")
        // The three canonicalisations, none of which can change which file the server produces:
        // a whitespace trim, leading dots, and case.
        #expect(ZiplineFileExtension.canonical("  py  ") == "py")
        #expect(ZiplineFileExtension.canonical(".md") == "md")
        #expect(ZiplineFileExtension.canonical("...md") == "md")
        #expect(ZiplineFileExtension.canonical("JSON") == "json")
        // The compound and punctuated real cases the 16-character cap has to leave room for.
        #expect(ZiplineFileExtension.canonical("tar.gz") == "tar.gz")
        #expect(ZiplineFileExtension.canonical("c++") == "c++")
        #expect(ZiplineFileExtension.canonical("f90-fixed") == "f90-fixed")
        #expect(ZiplineFileExtension.canonical("my_ext") == "my_ext")
        // And the canonical form is what the value carries afterwards.
        #expect(try request(".TXT").fileExtension == "txt")
    }

    // MARK: What the framing then looks like

    @Test("the accepted value lands in one Content-Disposition line and one header")
    func framing() throws {
        let upload = try request("tar.gz")
        let body = String(decoding: URLSessionZiplineClient.multipartBody(for: upload, boundary: "B"),
                          as: UTF8.self)
        #expect(body.contains("Content-Disposition: form-data; name=\"file\"; filename=\"paste.tar.gz\"\r\n"))
        // The part has exactly the two headers it is supposed to have. Counted rather than merely
        // looked for, because an injection's symptom is an *extra* header line, not a missing one.
        #expect(body.components(separatedBy: "\r\n").filter { $0.lowercased().hasPrefix("content-") }.count == 2)
        #expect(ZiplineV4Headers.headers(for: upload)["x-zipline-file-extension"] == "tar.gz")
    }

    @Test("the extension header is always sent, because it can no longer be empty")
    func headerIsAlwaysPresent() throws {
        // `ZiplineV4Headers` used to omit the header for an empty extension. An empty one cannot
        // exist any more, so that branch is gone and this is the property that replaced it.
        #expect(ZiplineV4Headers.headers(for: try request("txt"))["x-zipline-file-extension"] == "txt")
    }
}
