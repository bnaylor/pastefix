import Testing
@testable import PastefixCore

@Suite struct EncodersTests {
    private func enc(_ c: Codec, _ s: String) async throws -> String { try await Encode(codec: c).apply(.init(text: s)) }
    private func dec(_ c: Codec, _ s: String) async throws -> String { try await Decode(codec: c).apply(.init(text: s)) }

    @Test func base64RoundTrip() async throws {
        #expect(try await enc(.base64, "héllo 😀") == "aMOpbGxvIPCfmIA=")
        #expect(try await dec(.base64, "aMOpbGxvIPCfmIA=") == "héllo 😀")
    }
    @Test func base64DecodeTolerant() async throws {
        #expect(try await dec(.base64, "aMOp\nbGxv IPCf\nmIA") == "héllo 😀")            // whitespace + missing padding
        #expect(try await dec(.base64, "aMOpbGxvIPCfmIA") == "héllo 😀")
        #expect(try await dec(.base64, "PD8-Pz8_") == "<?>???")                              // url-safe alphabet
    }
    @Test func base64DecodeErrors() async {
        await #expect(throws: TransformError.invalidInput("Not valid Base64 text")) { _ = try await dec(.base64, "not base64!!") }
        await #expect(throws: TransformError.invalidInput("Not valid Base64 text")) { _ = try await dec(.base64, "AAAA") }   // decodes to NULs
        await #expect(throws: TransformError.invalidInput("Not valid Base64 text")) { _ = try await dec(.base64, "/////w==") } // invalid UTF-8
    }
    @Test func looksLikeBase64() {
        #expect(Base64Codec.looksLikeBase64("aMOpbGxvIPCfmIA="))
        #expect(!Base64Codec.looksLikeBase64("aMOpbGxv"))                  // < 16 chars
        #expect(!Base64Codec.looksLikeBase64("internationalization"))      // letters, but decodes to junk
        #expect(!Base64Codec.looksLikeBase64("AAAAAAAAAAAAAAAA"))          // NULs
        #expect(Base64Codec.looksLikeBase64("SGVsbG8sIHdvcmxkLiBUaGlzIGlzIHRleHQu"))
        #expect(!Base64Codec.looksLikeBase64("aGVsbG8gd29ybGTCm3g="))              // decodes to "hello world\u{9B}x" (C1 control)
    }
    @Test func base64LeadingPaddingRejected() {
        #expect(Base64Codec.decodeText("=aGVsbG8=") == nil)
    }
    @Test func urlEncodeDecode() async throws {
        #expect(try await enc(.url, "a b&c=d/é~") == "a%20b%26c%3Dd%2F%C3%A9~")
        #expect(try await dec(.url, "a%20b%26c%3Dd%2F%C3%A9+x%E2%80%94") == "a b&c=d/é+x—")
    }
    @Test func urlDecodeErrors() async {
        await #expect(throws: TransformError.invalidInput("Malformed percent-encoding")) { _ = try await dec(.url, "100%ZZ") }
        await #expect(throws: TransformError.invalidInput("Malformed percent-encoding")) { _ = try await dec(.url, "%FF%FE") }   // not UTF-8
    }
    @Test func htmlEncodeDecode() async throws {
        #expect(try await enc(.html, #"<a href="x">Tom & Jerry's</a>"#) == "&lt;a href=&quot;x&quot;&gt;Tom &amp; Jerry&#39;s&lt;/a&gt;")
        #expect(try await dec(.html, "caf&eacute; &amp;lt; &#8212; &bogus;") == "café &lt; — &bogus;")
    }
    @Test func metadata() {
        let expect: [(Codec, String, String, String, String, Set<ContentKind>?)] = [
            (.base64, "builtin.base64.encode", "Base64 Encode", "builtin.base64.decode", "Base64 Decode", [.base64]),
            (.url, "builtin.url.encode", "URL Encode", "builtin.url.decode", "URL Decode", [.percentEncoded]),
            (.html, "builtin.html.encode", "HTML Encode", "builtin.html.decode", "HTML Decode", [.htmlEntities]),
        ]
        for (codec, eid, ename, did, dname, dkinds) in expect {
            let e = Encode(codec: codec), d = Decode(codec: codec)
            #expect(e.id == eid); #expect(e.name == ename); #expect(e.applicableKinds == nil); #expect(e.category == TransformCategory.data)
            #expect(d.id == did); #expect(d.name == dname); #expect(d.applicableKinds == dkinds); #expect(d.category == TransformCategory.data)
        }
    }
}
