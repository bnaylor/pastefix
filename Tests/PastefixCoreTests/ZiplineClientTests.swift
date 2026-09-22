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
    /// When set, the *first* request is answered with `redirectStatus` and a `Location` of
    /// this value; any request after that gets the normal canned response. Drives the
    /// redirect-policy tests below.
    nonisolated(unsafe) static var redirectTo: String?
    nonisolated(unsafe) static var redirectStatus = 307
    /// Every request this protocol saw, in order — so a test can assert on the *second* hop
    /// (did it happen at all, and what did it carry) rather than only on the last one.
    nonisolated(unsafe) static var requests: [(url: URL, headers: [String: String], body: Data)] = []

    static func reset() {
        status = 200; body = Data(); capturedHeaders = [:]; capturedBody = Data(); failWith = nil
        redirectTo = nil; redirectStatus = 307; requests = []
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.capturedHeaders = request.allHTTPHeaderFields ?? [:]
        // URLSession moves an upload body to `httpBodyStream`.
        var thisBody = Data()
        if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while case let read = stream.read(&buffer, maxLength: buffer.count), read > 0 {
                thisBody.append(contentsOf: buffer[0..<read])
            }
        } else if let body = request.httpBody {
            thisBody = body
        }
        Self.capturedBody = thisBody
        Self.requests.append((url: request.url!, headers: Self.capturedHeaders, body: thisBody))
        if let error = Self.failWith {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        if let location = Self.redirectTo, Self.requests.count == 1 {
            let response = HTTPURLResponse(url: request.url!, statusCode: Self.redirectStatus,
                                           httpVersion: "HTTP/1.1",
                                           headerFields: ["Location": location])!
            var followUp = request
            followUp.url = URL(string: location, relativeTo: request.url)?.absoluteURL
            // 307/308 preserve the method and the body; that is exactly why they matter here.
            client?.urlProtocol(self, wasRedirectedTo: followUp, redirectResponse: response)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data())
            client?.urlProtocolDidFinishLoading(self)
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
        // Pinned to the opening delimiter specifically — `body.contains("--\(boundary)")`
        // would also be satisfied by the closing `--boundary--` alone, so it would
        // pass even if the client dropped the opening delimiter entirely.
        #expect(body.hasPrefix("--\(boundary)\r\n"))
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

    // MARK: - Endpoint normalisation (server URL -> /api/upload, no doubling)

    @Test("a bare host gets /api/upload appended")
    func endpointBareHost() {
        let url = URLSessionZiplineClient.endpoint(for: URL(string: "https://zip.example.test")!)
        #expect(url == URL(string: "https://zip.example.test/api/upload"))
    }

    @Test("a trailing slash does not produce a double slash before /api/upload")
    func endpointTrailingSlash() {
        let url = URLSessionZiplineClient.endpoint(for: URL(string: "https://zip.example.test/")!)
        #expect(url == URL(string: "https://zip.example.test/api/upload"))
    }

    @Test("a sub-path is preserved ahead of /api/upload")
    func endpointSubPath() {
        let url = URLSessionZiplineClient.endpoint(for: URL(string: "https://zip.example.test/zipline")!)
        #expect(url == URL(string: "https://zip.example.test/zipline/api/upload"))
    }

    @Test("a server URL that already ends in /api/upload is used as-is, not doubled")
    func endpointAlreadyFull() {
        let url = URLSessionZiplineClient.endpoint(for: URL(string: "https://zip.example.test/api/upload")!)
        #expect(url == URL(string: "https://zip.example.test/api/upload"))
    }

    @Test("a full endpoint URL with a trailing slash is still not doubled")
    func endpointAlreadyFullWithTrailingSlash() {
        let url = URLSessionZiplineClient.endpoint(for: URL(string: "https://zip.example.test/api/upload/")!)
        #expect(url == URL(string: "https://zip.example.test/api/upload"))
    }

    @Test("a 404 with no JSON message names the attempted URL, not just a bare status")
    func serverErrorWithoutMessageNamesURL() async throws {
        let c = client()
        StubProtocol.status = 404
        StubProtocol.body = Data()
        let thrown = await #expect(throws: ZiplineUploadError.self) {
            try await c.upload(upload, to: server, token: "tok_123")
        }
        guard let thrown, case .server(let status, let message) = thrown else {
            Issue.record("expected server, got \(String(describing: thrown))"); return
        }
        #expect(status == 404)
        #expect(message?.contains("zip.example.test/api/upload") == true)
        // The token must never leak into a diagnostic message.
        #expect(message?.contains("tok_123") == false)
    }

    // MARK: - Redirects: same-origin is followed, cross-origin is refused

    @Test("a same-origin redirect is followed and the upload succeeds")
    func redirectSameOriginIsFollowed() async throws {
        let c = client()
        StubProtocol.redirectTo = "https://zip.example.test/zipline/api/upload"
        StubProtocol.body = #"{"files":[{"url":"https://zip.example.test/u/abc"}]}"#.data(using: .utf8)!
        let url = try await c.upload(upload, to: server, token: "tok_123")
        #expect(url == URL(string: "https://zip.example.test/u/abc"))
        // Two hops, and the second one is the redirect target.
        #expect(StubProtocol.requests.count == 2)
        #expect(StubProtocol.requests.last?.url.absoluteString == "https://zip.example.test/zipline/api/upload")
    }

    @Test("a cross-origin redirect is not followed: no second request, so no token and no text")
    func redirectCrossOriginIsRefused() async throws {
        let c = client()
        StubProtocol.redirectTo = "https://evil.example.test/api/upload"
        let thrown = await #expect(throws: ZiplineUploadError.self) {
            try await c.upload(upload, to: server, token: "tok_123")
        }
        guard let thrown, case .server(let status, let message) = thrown else {
            Issue.record("expected server, got \(String(describing: thrown))"); return
        }
        #expect(status == 307)
        #expect(message?.contains("redirected") == true)
        // The assertion that matters: the second request never happened at all, so neither
        // the token nor the clipboard text was offered to the other origin.
        #expect(StubProtocol.requests.count == 1)
        #expect(StubProtocol.requests.allSatisfy { $0.url.host == "zip.example.test" })
        let sentElsewhere = StubProtocol.requests.filter { $0.url.host != "zip.example.test" }
        #expect(sentElsewhere.isEmpty)
    }

    @Test("a redirect to a different port on the same host is cross-origin and refused")
    func redirectDifferentPortIsRefused() async throws {
        let c = client()
        StubProtocol.redirectTo = "https://zip.example.test:8443/api/upload"
        await #expect(throws: ZiplineUploadError.self) {
            try await c.upload(upload, to: server, token: "tok_123")
        }
        #expect(StubProtocol.requests.count == 1)
    }

    @Test("an http -> https upgrade is cross-origin and refused")
    func redirectSchemeUpgradeIsRefused() async throws {
        let c = client()
        StubProtocol.redirectStatus = 301
        StubProtocol.redirectTo = "https://zip.example.test/api/upload"
        await #expect(throws: ZiplineUploadError.self) {
            try await c.upload(upload, to: URL(string: "http://zip.example.test")!, token: "tok_123")
        }
        #expect(StubProtocol.requests.count == 1)
    }

    // The policy object itself, without a transport: these pin the origin comparison
    // directly, so a change to `isSameOrigin` fails here with a readable reason rather than
    // only as a puzzling integration failure.

    @Test("the redirect policy allows a same-origin target and the scheme's default port")
    func policyAllowsSameOrigin() {
        let origin = URL(string: "https://zip.example.test/api/upload")!
        #expect(SameOriginRedirectPolicy.redirect(
            from: origin,
            to: URLRequest(url: URL(string: "https://zip.example.test/elsewhere")!)) != nil)
        // Explicit :443 is the same origin as an implicit one.
        #expect(SameOriginRedirectPolicy.redirect(
            from: origin,
            to: URLRequest(url: URL(string: "https://zip.example.test:443/api/upload")!)) != nil)
        // Host comparison is case-insensitive; a case difference is not a different origin.
        #expect(SameOriginRedirectPolicy.redirect(
            from: origin,
            to: URLRequest(url: URL(string: "https://ZIP.EXAMPLE.TEST/api/upload")!)) != nil)
    }

    @Test("the redirect policy refuses a different host, port or scheme")
    func policyRefusesCrossOrigin() {
        let origin = URL(string: "https://zip.example.test/api/upload")!
        for target in ["https://evil.example.test/api/upload",
                       "https://zip.example.test.evil.test/api/upload",
                       "https://zip.example.test:8443/api/upload",
                       "http://zip.example.test/api/upload",
                       "file:///etc/passwd"] {
            #expect(SameOriginRedirectPolicy.redirect(
                from: origin,
                to: URLRequest(url: URL(string: target)!)) == nil,
                    "should have refused \(target)")
        }
    }

    // MARK: - parseBadOption: malformed inputs fall back to the generic server case

    @Test("a message with no closing bracket does not parse as badOption")
    func parseBadOptionNoClosingBracket() {
        #expect(URLSessionZiplineClient.parseBadOption("bad options[x-zipline-deletes-at: oops") == nil)
    }

    @Test("a message with the wrong prefix does not parse as badOption")
    func parseBadOptionWrongPrefix() {
        #expect(URLSessionZiplineClient.parseBadOption("something else entirely") == nil)
    }

    @Test("an empty header name does not parse as badOption")
    func parseBadOptionEmptyHeader() {
        #expect(URLSessionZiplineClient.parseBadOption("bad options[]: x") == nil)
    }

    @Test("a malformed-prefix message surfaces as server, not badOption")
    func malformedBadOptionMessageBecomesServer() async throws {
        let c = client()
        StubProtocol.status = 400
        StubProtocol.body = #"{"code":1001,"message":"bad options[]: nonsense"}"#.data(using: .utf8)!
        let thrown = await #expect(throws: ZiplineUploadError.self) {
            try await c.upload(upload, to: server, token: "tok_123")
        }
        guard let thrown, case .server(let status, let message) = thrown else {
            Issue.record("expected server, got \(String(describing: thrown))"); return
        }
        #expect(status == 400)
        #expect(message == "bad options[]: nonsense")
    }

    // MARK: - shortURL's guard chain: every unreadable-body shape is malformed, never success

    @Test("a non-JSON 2xx body is malformed")
    func malformedNonJSON() async throws {
        let c = client()
        StubProtocol.body = "not json at all".data(using: .utf8)!
        await #expect(throws: ZiplineUploadError.malformedResponse) {
            try await c.upload(upload, to: server, token: "tok_123")
        }
    }

    @Test("a 2xx JSON body with no files key is malformed")
    func malformedNoFilesKey() async throws {
        let c = client()
        StubProtocol.body = #"{"ok":true}"#.data(using: .utf8)!
        await #expect(throws: ZiplineUploadError.malformedResponse) {
            try await c.upload(upload, to: server, token: "tok_123")
        }
    }

    @Test("a files[0] with no url is malformed")
    func malformedFileWithoutURL() async throws {
        let c = client()
        StubProtocol.body = #"{"files":[{"id":"a","name":"x.txt"}]}"#.data(using: .utf8)!
        await #expect(throws: ZiplineUploadError.malformedResponse) {
            try await c.upload(upload, to: server, token: "tok_123")
        }
    }
}
