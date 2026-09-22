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
///
/// The request does carry a per-*task* delegate, `SameOriginRedirectPolicy`,
/// which is a different thing: a task delegate has no authentication-challenge
/// callback, so it is not a place a trust bypass can appear. The session still
/// has no delegate at all.
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
            // A *per-task* delegate, never a session delegate — see `SameOriginRedirectPolicy`.
            (data, response) = try await session.data(for: req, delegate: SameOriginRedirectPolicy())
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
        // A 3xx can only reach here because `SameOriginRedirectPolicy` refused to follow it:
        // a same-origin redirect is followed and its final response is what lands. Say so,
        // because a bare "Server error 308" with the upload's own URL in it is the least
        // diagnosable message this client can produce.
        if (300..<400).contains(status) {
            return .server(status: status,
                           message: "The server redirected the upload to a different host. "
                                  + "Pastefix won't send your text or token to an address you "
                                  + "didn't configure — set the server URL to the final address.")
        }
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

/// The redirect policy for the upload request, attached to the *task* with
/// `session.data(for:delegate:)`.
///
/// A task delegate, emphatically not a session delegate: `URLSessionZiplineClient` still
/// passes no delegate to `URLSession(configuration:)`, so there remains nowhere for a
/// `urlSession(_:didReceive:completionHandler:)` certificate-trust callback to be bolted on
/// later. A self-signed certificate must keep failing. `URLSessionTaskDelegate` carries no
/// authentication-challenge callback of its own for that hook to hide in.
///
/// **Policy: follow a redirect that stays on the origin the user configured (same scheme,
/// host and port); refuse every other redirect.**
///
/// Refuse, rather than forward with the `authorization` header stripped, because the token
/// is only one of the two secrets on this request. A 307/308 re-POSTs the *body* — the
/// user's clipboard, which is the thing this whole feature is careful about — and dropping
/// one header does nothing about that. There is no useful version of "send the text to a
/// host the user never typed", so the safe answer is not to make the second request at all.
/// It also removes the question of whether a given CFNetwork build strips `authorization`
/// across origins by itself, which is version-dependent and not something to rely on.
///
/// What this costs: a reverse proxy that answers `http` with a 301 to `https` is
/// cross-origin (the scheme differs) and is refused, so the user has to type the `https`
/// URL. App Transport Security already forces that for any named host (see the ATS note in
/// `UploadSettingsView`), so in practice it costs close to nothing. The benign same-origin
/// cases — trailing-slash normalisation, a path rewrite in front of `api/upload` — still work.
///
/// Stateless, hence `@unchecked Sendable`: it stores nothing and the delegate method reads
/// only its arguments.
final class SameOriginRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(Self.redirect(from: task.originalRequest?.url, to: request))
    }

    /// Compared against the **original** request's URL rather than the previous hop, so a
    /// chain cannot walk off the configured origin one same-origin-looking step at a time.
    static func redirect(from origin: URL?, to request: URLRequest) -> URLRequest? {
        guard let origin, let target = request.url,
              isSameOrigin(origin, target) else { return nil }
        return request
    }

    /// Origin in the RFC 6454 sense: scheme, host and port, with the scheme's default port
    /// filled in so `https://host` and `https://host:443` are the same origin. Case-folded
    /// on scheme and host only — path and query are not part of an origin and a redirect is
    /// allowed to change them.
    static func isSameOrigin(_ a: URL, _ b: URL) -> Bool {
        guard let aScheme = a.scheme?.lowercased(), let bScheme = b.scheme?.lowercased(),
              let aHost = a.host?.lowercased(), let bHost = b.host?.lowercased(),
              !aHost.isEmpty, !bHost.isEmpty else { return false }
        return aScheme == bScheme && aHost == bHost && port(of: a) == port(of: b)
    }

    private static func port(of url: URL) -> Int? {
        if let port = url.port { return port }
        switch url.scheme?.lowercased() {
        case "http": return 80
        case "https": return 443
        default: return nil
        }
    }
}
