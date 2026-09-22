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
