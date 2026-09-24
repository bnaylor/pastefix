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
/// The request does carry a per-*task* delegate, `SameOriginRedirectPolicy`, attached solely
/// to police redirects. `URLSessionTaskDelegate` does expose authentication-challenge
/// callbacks — the session-level one it inherits plus its own task-level one — and this type
/// deliberately implements neither, so a challenge falls through to default handling and an
/// untrusted certificate still fails the request. Implementing one here is exactly how a
/// trust bypass would get added, and that must not happen.
public struct URLSessionZiplineClient: ZiplineUploading {
    /// The **idle** bound (`timeoutIntervalForRequest`, and the request's own
    /// `timeoutInterval`): how long nothing may happen before the request is abandoned.
    /// URLSession restarts it whenever bytes move, so it is independent of the body's size.
    public let timeout: TimeInterval
    /// The **whole-transfer** bound (`timeoutIntervalForResource`), which does not restart on
    /// progress and therefore has to be large enough to send the largest body the upload path
    /// admits. It is not the same question as `timeout` and no longer shares its value — see
    /// `UploadLimits`, which ties this to `UploadLimits.maxPayloadBytes`.
    public let resourceTimeout: TimeInterval
    private let protocolClasses: [AnyClass]?

    public init(timeout: TimeInterval = UploadLimits.idleTimeout,
                resourceTimeout: TimeInterval = UploadLimits.resourceTimeout,
                protocolClasses: [AnyClass]? = nil) {
        self.timeout = timeout
        self.resourceTimeout = resourceTimeout
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
        req.httpBody = Self.multipartBody(for: request, boundary: boundary)

        let config = URLSessionConfiguration.ephemeral
        // Idle, then whole-transfer. Setting both from one value (as this did) meant a body the
        // path was happy to admit could be cancelled mid-send on a slow uplink and reported as
        // `.transport`, with Retry — which fails identically — as the only offered remedy.
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = resourceTimeout
        if let protocolClasses { config.protocolClasses = protocolClasses }
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        // A *per-task* delegate, never a session delegate — see `SameOriginRedirectPolicy`.
        // Held rather than passed inline so its refusal reason is readable afterwards: a
        // refused 3xx is delivered as a 3xx response, and which refusal it was decides which
        // message the user gets.
        let policy = SameOriginRedirectPolicy()
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        let data: Data
        let truncated: Bool
        do {
            // `bytes(for:)`, not `data(for:)`: the reply is read through a byte cap rather than
            // buffered in full. See `UploadLimits.maxResponseBytes`.
            (bytes, response) = try await session.bytes(for: req, delegate: policy)
            (data, truncated) = try await Self.readCapped(bytes, limit: UploadLimits.maxResponseBytes)
        } catch {
            throw ZiplineUploadError.transport(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else { throw ZiplineUploadError.malformedResponse }
        // Status first: a 404 whose error page ran past the cap is still best reported as a 404,
        // and a body truncated mid-JSON simply does not parse, so `error(status:…)` falls back to
        // naming the URL rather than quoting half a message.
        guard (200..<300).contains(http.statusCode) else {
            throw Self.error(status: http.statusCode, body: data, requestURL: endpoint,
                             refusal: policy.refusal)
        }
        guard !truncated else { throw ZiplineUploadError.oversizedResponse }
        guard let url = Self.shortURL(from: data) else { throw ZiplineUploadError.malformedResponse }
        return url
    }

    /// Reads at most `limit` bytes of the reply, reporting whether there was more.
    ///
    /// Stops on reaching the cap and leaves the rest of the stream unread — the caller's
    /// `session.invalidateAndCancel()` tears the task down. `truncated` is returned rather than
    /// thrown because the status code outranks it: an over-long *error* page is still a status
    /// error, and only an over-long *2xx* is `.oversizedResponse`.
    static func readCapped(_ bytes: URLSession.AsyncBytes,
                           limit: Int) async throws -> (body: Data, truncated: Bool) {
        var data = Data()
        data.reserveCapacity(min(limit, 8_192))
        for try await byte in bytes {
            if data.count >= limit { return (data, true) }
            data.append(byte)
        }
        return (data, false)
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
    ///
    /// Takes the whole `ZiplineUpload` rather than a `text`/`fileExtension` pair so that the
    /// only way to get a filename into this `Content-Disposition` line is through a value
    /// whose extension `ZiplineUpload.init` has already accepted — including from a test.
    /// Nothing is stripped or escaped here on purpose: this is the *use* site, and
    /// `ZiplineFileExtension` is the single choke point (a `"` would end the quoted filename,
    /// a CR LF would inject a header into this block).
    static func multipartBody(for upload: ZiplineUpload, boundary: String) -> Data {
        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"paste.\(upload.fileExtension)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: text/plain; charset=utf-8\r\n\r\n".data(using: .utf8)!)
        body.append(Data(upload.text.utf8))
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
    ///
    /// `refusal` is the redirect policy's own answer to "why did I not follow it", which is the
    /// only way to tell a cross-origin refusal from a same-origin 301 whose body CFNetwork had
    /// already dropped. Both are 3xx statuses and the remedy is the same sentence's worth of
    /// advice, but naming the wrong cause sends the user looking for a redirect to another host
    /// that never happened.
    private static func error(status: Int, body: Data, requestURL: URL,
                              refusal: SameOriginRedirectPolicy.Refusal?) -> ZiplineUploadError {
        if status == 401 { return .unauthorized }
        // A 3xx can only reach here because `SameOriginRedirectPolicy` refused to follow it:
        // an allowed redirect is followed and its final response is what lands. Say so,
        // because a bare "Server error 308" with the upload's own URL in it is the least
        // diagnosable message this client can produce.
        if (300..<400).contains(status) {
            switch refusal {
            case .bodyDropped:
                return .server(status: status,
                               message: "The server redirected the upload with a status (\(status)) "
                                      + "that drops the uploaded text, so Pastefix stopped rather "
                                      + "than send an empty request — set the server URL to the "
                                      + "address it redirects to.")
            case .crossOrigin, nil:
                return .server(status: status,
                               message: "The server redirected the upload to a different host. "
                                      + "Pastefix won't send your text or token to an address you "
                                      + "didn't configure — set the server URL to the final address.")
            }
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
/// A task delegate, emphatically not a session delegate — but not because a task delegate is
/// incapable of the thing that must not happen here. `URLSessionTaskDelegate` inherits the
/// session-level `urlSession(_:didReceive:completionHandler:)` and declares its own
/// task-level challenge callback besides; either is a place a certificate-trust bypass could
/// be bolted on. This type implements neither, on purpose: no challenge callback here means
/// every challenge falls through to default handling, and a self-signed certificate keeps
/// failing. Adding one is exactly how that would stop being true, so it must not happen.
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
/// **And: refuse a redirect whose method is no longer `POST`.** Same-origin is necessary but
/// not sufficient. CFNetwork implements the RFC 7231 rewrite for 301, 302 and 303 — a `POST`
/// becomes a `GET` and the body is dropped — so a same-origin 301 from `/api/upload` to
/// `/api/upload/` was previously followed as a bodiless `GET`, which Zipline answers 404 or
/// 405, surfacing as a bare "Server error 405" about an upload that never carried the text.
/// Only 307 and 308 preserve the method and the body. Refusing the rewritten hop turns that
/// into a message naming the cause, with the one fix that works: configure the final address.
///
/// What this costs: a reverse proxy that answers `http` with a 301 to `https` is
/// cross-origin (the scheme differs) and is refused, so the user has to type the `https`
/// URL. App Transport Security already forces that for any named host (see the ATS note in
/// `UploadSettingsView`), so in practice it costs close to nothing. Of the benign same-origin
/// cases, the ones that arrive as a 307 or 308 — a path rewrite in front of `api/upload` —
/// still work; trailing-slash normalisation sent as a 301 does not, and cannot: there is no
/// body left to send by the time this delegate is consulted. That was the previous comment's
/// claim and it was wrong.
///
/// Not stateless, and that is the one piece of state: the reason a redirect was refused, so
/// the delivered 3xx can be reported with the right cause. `@unchecked Sendable` because the
/// delegate callback and the client's read happen on different threads; the `NSLock` is the
/// synchronisation that makes the promise true (AGENTS.md: if you write `@unchecked Sendable`,
/// the synchronization must actually exist).
final class SameOriginRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    /// Why a redirect was not followed. Only ever set by the delegate callback, and only for a
    /// refusal — a followed redirect leaves it nil.
    enum Refusal: Sendable, Equatable {
        /// The target left the origin the user configured (scheme, host or port differs).
        case crossOrigin
        /// Same origin, but the redirect status rewrote `POST` to `GET`, so the upload body is
        /// already gone. 301, 302 and 303 do this; 307 and 308 do not.
        case bodyDropped
    }

    private let lock = NSLock()
    private var recorded: Refusal?

    /// The first refusal on this task, or nil if no redirect was refused. First rather than
    /// last: a chain stops at the hop that was refused, so there can only be one.
    var refusal: Refusal? {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    /// Checks the claim above rather than merely stating it: this type must not gain a
    /// challenge callback, session-level or task-level, by accident.
    override init() {
        super.init()
        assert(!responds(to: #selector(URLSessionDelegate.urlSession(_:didReceive:completionHandler:))))
        assert(!responds(to: #selector(URLSessionTaskDelegate.urlSession(_:task:didReceive:completionHandler:))))
    }

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        let refusal = Self.refusal(from: task.originalRequest?.url, to: request)
        if let refusal {
            lock.lock()
            if recorded == nil { recorded = refusal }
            lock.unlock()
        }
        completionHandler(refusal == nil ? request : nil)
    }

    /// Why this redirect must not be followed, or nil when it may be.
    ///
    /// Origin is compared against the **original** request's URL rather than the previous hop,
    /// so a chain cannot walk off the configured origin one same-origin-looking step at a time.
    static func refusal(from origin: URL?, to request: URLRequest) -> Refusal? {
        guard let origin, let target = request.url, isSameOrigin(origin, target) else {
            return .crossOrigin
        }
        // Not "is the status 307/308": this is the method CFNetwork has already decided to use,
        // which is the thing that actually determines whether the body survives.
        guard request.httpMethod?.uppercased() == "POST" else { return .bodyDropped }
        return nil
    }

    /// The request to follow, or nil to refuse. Kept as the shape the delegate contract wants,
    /// and defined in terms of `refusal(from:to:)` so there is one rule, not two.
    static func redirect(from origin: URL?, to request: URLRequest) -> URLRequest? {
        refusal(from: origin, to: request) == nil ? request : nil
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
