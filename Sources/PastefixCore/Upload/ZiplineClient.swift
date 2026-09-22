import Foundation

public protocol ZiplineUploading: Sendable {
    /// Returns the short URL. The server and token are parameters because this
    /// type has no opinion about where they are stored — "not configured" is
    /// the app layer's check, made before the overlay opens, so this is never
    /// called without both.
    func upload(_ request: ZiplineUpload, to server: URL, token: String) async throws -> URL
}

/// Shaped after `URLSessionTitleFetcher`: ephemeral session, explicit timeout,
/// injectable so consumers can fake it.
///
/// Deliberately has NO `URLSessionDelegate`. A self-hosted Zipline with a
/// self-signed certificate fails, and that is the intended behaviour: TLS is
/// the only transport protection this feature has, and an exception here would
/// remove it for everyone to spare one person a certificate fix.
public struct URLSessionZiplineClient: ZiplineUploading {
    public let timeout: TimeInterval
    private let protocolClasses: [AnyClass]?

    public init(timeout: TimeInterval = 60, protocolClasses: [AnyClass]? = nil) {
        self.timeout = timeout
        self.protocolClasses = protocolClasses
    }

    public func upload(_ request: ZiplineUpload, to server: URL, token: String) async throws -> URL {
        let endpoint = Self.endpoint(for: server)
        let boundary = "PastefixBoundary-\(UUID().uuidString)"

        var req = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData,
                             timeoutInterval: timeout)
        req.httpMethod = "POST"
        req.setValue(token, forHTTPHeaderField: "authorization")
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "content-type")
        for (name, value) in ZiplineV4Headers.headers(for: request) {
            req.setValue(value, forHTTPHeaderField: name)
        }
        req.httpBody = Self.multipartBody(text: request.text,
                                          fileExtension: request.fileExtension,
                                          boundary: boundary)

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        if let protocolClasses { config.protocolClasses = protocolClasses }
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw ZiplineUploadError.transport(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else { throw ZiplineUploadError.malformedResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw Self.error(status: http.statusCode, body: data, requestURL: endpoint)
        }
        guard let url = Self.shortURL(from: data) else { throw ZiplineUploadError.malformedResponse }
        return url
    }

    /// Zipline's own iShare-era config surfaces a `requestURL` of exactly
    /// `https://host/api/upload` — a user migrating from iShare has that full
    /// endpoint string in front of them and may reasonably paste it into the
    /// server field. Appending `api/upload` unconditionally would double it
    /// into `.../api/upload/api/upload` and 404 with no clue why. Normalise
    /// instead: strip trailing slashes, then append only if the path does not
    /// already end in `api/upload`. Idempotent for a bare host, a host with a
    /// trailing slash, a host with a sub-path, and a host that already
    /// includes the endpoint.
    static func endpoint(for server: URL) -> URL {
        guard var comps = URLComponents(url: server, resolvingAgainstBaseURL: false) else {
            return server.appendingPathComponent("api/upload")
        }
        var path = comps.path
        while path.hasSuffix("/") { path.removeLast() }
        if !path.hasSuffix("/api/upload") && path != "api/upload" {
            path += "/api/upload"
        }
        comps.path = path
        return comps.url ?? server.appendingPathComponent("api/upload")
    }

    /// `multipart/form-data` requires a filename on the part; it is a form
    /// field, not `x-zipline-filename`, which is deliberately never sent.
    static func multipartBody(text: String, fileExtension: String, boundary: String) -> Data {
        let ext = fileExtension.hasPrefix(".") ? String(fileExtension.dropFirst()) : fileExtension
        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"paste.\(ext)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: text/plain; charset=utf-8\r\n\r\n".data(using: .utf8)!)
        body.append(Data(text.utf8))
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        return body
    }

    private static func shortURL(from data: Data) -> URL? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let files = object["files"] as? [[String: Any]],
              let first = files.first,
              let string = first["url"] as? String else { return nil }
        return URL(string: string)
    }

    /// Zipline replies `{"code":1001,"message":"bad options[<header>]: <detail>"}`
    /// for a header the user can fix in the overlay, which is why it does not
    /// collapse into the generic server case.
    ///
    /// `requestURL` backfills `.server`'s message only when the body carried
    /// none: a bare 404 from a misconfigured server URL is otherwise
    /// undiagnosable from the UI. Never the token — it is a header, not part
    /// of this URL, so there is nothing to scrub.
    private static func error(status: Int, body: Data, requestURL: URL) -> ZiplineUploadError {
        if status == 401 { return .unauthorized }
        let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        let message = object?["message"] as? String
        if let message, let parsed = parseBadOption(message) {
            return .badOption(header: parsed.header, message: parsed.detail)
        }
        return .server(status: status, message: message ?? "request to \(requestURL.absoluteString) failed")
    }

    static func parseBadOption(_ message: String) -> (header: String, detail: String)? {
        guard message.hasPrefix("bad options["),
              let close = message.firstIndex(of: "]") else { return nil }
        let start = message.index(message.startIndex, offsetBy: "bad options[".count)
        let header = String(message[start..<close])
        // An empty header name is not a header the overlay can point at;
        // treat it as unparseable so it falls back to the generic server case
        // rather than reporting `.badOption(header: "", ...)`.
        guard !header.isEmpty else { return nil }
        var detail = String(message[message.index(after: close)...])
        if detail.hasPrefix(":") { detail.removeFirst() }
        return (header, detail.trimmingCharacters(in: .whitespaces))
    }
}
