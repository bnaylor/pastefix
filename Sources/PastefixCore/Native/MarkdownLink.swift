import Foundation

/// Fetches an HTML page title. The engine's only network access; injected so tests stay offline.
public protocol TitleFetcher: Sendable {
    func title(for url: URL) async -> String?
}

public struct URLSessionTitleFetcher: TitleFetcher {
    public let timeout: TimeInterval
    public let maxBytes: Int

    public init(timeout: TimeInterval = 3, maxBytes: Int = 262_144) {
        self.timeout = timeout
        self.maxBytes = maxBytes
    }

    /// Sent so operators can identify (and, if they like, block) the transform.
    static let userAgent = "Pastefix (+https://github.com/bnaylor/pastefix)"

    public func title(for url: URL) async -> String? {
        guard Self.isFetchable(url) else { return nil }
        var request = URLRequest(url: Self.fetchURL(for: url), cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.setValue("text/html", forHTTPHeaderField: "Accept")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        // A 302 to http://192.168.1.1/ would otherwise walk straight past `isFetchable`.
        let session = URLSession(configuration: config, delegate: RedirectGuard(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  (http.mimeType ?? "").lowercased().contains("html") else { return nil }
            var data = Data()
            for try await byte in bytes {
                data.append(byte)
                // The title is in <head>; stop the moment it closes rather than reading
                // the whole (possibly 256 KB) body.
                if Self.endsWithCloseTitle(data) { break }
                if data.count >= maxBytes { break }
            }
            return Self.parseTitle(data: data)
        } catch {
            return nil
        }
    }

    private static let closeTitleBytes = Array("</title>".utf8)

    /// True when the last bytes of `data` are `</title>` (ASCII case-insensitive).
    static func endsWithCloseTitle(_ data: Data) -> Bool {
        guard data.count >= closeTitleBytes.count else { return false }
        var i = data.index(data.endIndex, offsetBy: -closeTitleBytes.count)
        for expected in closeTitleBytes {
            let byte = data[i]
            let lowered = (byte >= 0x41 && byte <= 0x5A) ? byte + 0x20 : byte
            if lowered != expected { return false }
            i = data.index(after: i)
        }
        return true
    }

    /// The URL actually requested. App Transport Security blocks cleartext, so an `http`
    /// link is fetched over `https` (same host, port, path, query, fragment) — otherwise
    /// every `http://` and bare-`www.` link would always fall back. The Markdown *target*
    /// keeps whatever scheme `URLFinder` produced; only the fetch is upgraded.
    static func fetchURL(for url: URL) -> URL {
        guard url.scheme?.lowercased() == "http",
              var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        comps.scheme = "https"
        return comps.url ?? url
    }

    /// False for hosts we must never contact: loopback, link-local, `.local`/`.localhost`
    /// mDNS names, and the private/reserved IP ranges. A paste can contain anything, and a
    /// transform is not a licence to probe the user's LAN. Unfetchable URLs get the
    /// `host/path` fallback with no request made.
    ///
    /// Address literals go through `inet_pton`, not a hand-rolled dotted-quad parse, so
    /// alternate spellings (`0x7f.0.0.1`, `2130706433`, `::ffff:127.0.0.1`, `[::1]`) either
    /// reduce to the same bytes the range checks see or fail to parse as an address at all.
    ///
    /// Hostnames are **not** resolved before fetching, so a public name pointing at a
    /// private address still gets a request. That is deliberate: this is side-effect hygiene
    /// for a user-initiated GET from the user's own machine, not a server-side trust
    /// boundary — the user could type the address directly, and a resolver-level check would
    /// mean a DNS round trip and a TOCTOU gap for no real gain here.
    static func isFetchable(_ url: URL) -> Bool {
        guard var host = url.host?.lowercased(), !host.isEmpty else { return false }
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        if host == "localhost" || host.hasSuffix(".local") || host.hasSuffix(".localhost") { return false }

        var v4 = in_addr()
        if host.withCString({ inet_pton(AF_INET, $0, &v4) }) == 1 {
            let b = withUnsafeBytes(of: v4.s_addr) { Array($0) }   // network byte order
            return !isPrivateIPv4((b[0], b[1], b[2], b[3]))
        }
        var v6 = in6_addr()
        if host.withCString({ inet_pton(AF_INET6, $0, &v6) }) == 1 {
            return !isPrivateIPv6(withUnsafeBytes(of: v6) { Array($0) })
        }
        return true   // a hostname, not an address literal
    }

    /// Private, loopback, link-local, CGNAT, multicast and reserved IPv4 space.
    static func isPrivateIPv4(_ bytes: (UInt8, UInt8, UInt8, UInt8)) -> Bool {
        let (a, b, _, _) = bytes
        if a == 0 { return true }                          // 0.0.0.0/8 "this network"
        if a == 10 { return true }                         // 10.0.0.0/8
        if a == 100, (64...127).contains(b) { return true } // 100.64.0.0/10 CGNAT
        if a == 127 { return true }                        // 127.0.0.0/8 loopback
        if a == 169, b == 254 { return true }              // 169.254.0.0/16 link-local
        if a == 172, (16...31).contains(b) { return true }  // 172.16.0.0/12
        if a == 192, b == 168 { return true }              // 192.168.0.0/16
        if (224...239).contains(a) { return true }         // 224.0.0.0/4 multicast
        if a >= 240 { return true }                        // 240.0.0.0/4 reserved + broadcast
        return false
    }

    /// Unspecified, loopback, link-local, unique-local and site-local IPv6 space, plus
    /// IPv4-mapped addresses whose embedded v4 address is itself private.
    static func isPrivateIPv6(_ bytes: [UInt8]) -> Bool {
        guard bytes.count == 16 else { return true }
        if bytes.allSatisfy({ $0 == 0 }) { return true }                       // ::/128
        if bytes.dropLast().allSatisfy({ $0 == 0 }), bytes[15] == 1 { return true } // ::1/128
        if bytes[0] == 0xFE, bytes[1] & 0xC0 == 0x80 { return true }           // fe80::/10
        if bytes[0] & 0xFE == 0xFC { return true }                             // fc00::/7
        if bytes[0] == 0xFE, bytes[1] & 0xC0 == 0xC0 { return true }           // fec0::/10
        // ::ffff:0:0/96 — an IPv4 address wearing a v6 hat; judge it as IPv4.
        if bytes[0..<10].allSatisfy({ $0 == 0 }), bytes[10] == 0xFF, bytes[11] == 0xFF {
            return isPrivateIPv4((bytes[12], bytes[13], bytes[14], bytes[15]))
        }
        return false
    }

    /// Decodes a byte-capped HTML buffer as UTF-8, retrying after dropping up to 3 trailing
    /// bytes in case the cap severed a multi-byte sequence, before falling back to Latin-1.
    static func decodeHTML(_ data: Data) -> String {
        if let s = String(data: data, encoding: .utf8) { return s }
        for drop in 1...3 where data.count > drop {
            if let s = String(data: data.dropLast(drop), encoding: .utf8) { return s }
        }
        return String(data: data, encoding: .isoLatin1) ?? ""
    }

    static func parseTitle(data: Data) -> String? {
        let html = decodeHTML(data)
        guard let open = html.range(of: "<title(\\s[^>]*)?>", options: [.regularExpression, .caseInsensitive]),
              let close = html.range(of: "</title>", options: .caseInsensitive, range: open.upperBound..<html.endIndex)
        else { return nil }
        let raw = decodeEntities(String(html[open.upperBound..<close.lowerBound]))
        let collapsed = raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return collapsed.isEmpty ? nil : collapsed
    }

    static func decodeEntities(_ s: String) -> String {
        var out = s
        // Numeric references first so "&amp;#39;" style double-encoding isn't mis-decoded.
        for pattern in ["&#x([0-9A-Fa-f]+);", "&#([0-9]+);"] {
            let options: NSRegularExpression.Options = pattern.contains("x") ? [.caseInsensitive] : []
            guard let re = try? NSRegularExpression(pattern: pattern, options: options) else { continue }
            let ns = out as NSString
            var result = out
            for m in re.matches(in: out, range: NSRange(location: 0, length: ns.length)).reversed() {
                let digits = ns.substring(with: m.range(at: 1))
                let code = pattern.contains("x") ? UInt32(digits, radix: 16) : UInt32(digits)
                if let code, let scalar = Unicode.Scalar(code), let r = Range(m.range, in: result) {
                    result.replaceSubrange(r, with: String(Character(scalar)))
                }
            }
            out = result
        }
        // Named references in a fixed order, with "&amp;" last, so "&amp;lt;" decodes to the
        // literal text "&lt;" rather than "<" — Dictionary iteration order would make this
        // nondeterministic.
        let named: [(String, String)] = [("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&apos;", "'"), ("&nbsp;", " "), ("&amp;", "&")]
        for (k, v) in named { out = out.replacingOccurrences(of: k, with: v) }
        return out
    }
}

/// Refuses a redirect whose destination we would not have fetched in the first place — an
/// open redirect is otherwise a way to reach `192.168.1.1` from a perfectly public URL. When
/// the redirect is refused the original 3xx response is delivered instead, which fails the
/// 2xx check in `title(for:)`, so the link simply gets its `host/path` fallback.
private final class RedirectGuard: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let url = request.url,
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              URLSessionTitleFetcher.isFetchable(url)
        else { return completionHandler(nil) }
        completionHandler(request)
    }
}

/// Replaces each http(s) URL with `[title](url)`, fetching titles concurrently with a hard
/// per-URL bound; falls back to `host/path` on any failure so the transform never errors.
public struct MarkdownLink: Transformer {
    public let id = "builtin.markdownlink"
    public let name = "URL → Markdown Link"
    public let requiresRichInput = false
    public let source: TransformerSource = .builtin
    public let applicableKinds: Set<ContentKind>? = [.url]

    private let fetcher: any TitleFetcher
    private let fetchTimeout: TimeInterval
    /// Equal to `maxFetchedURLs`, so every fetched URL runs in a single batch.
    private static let maxConcurrentFetches = 16
    /// Caps total wall-clock time: ceil(maxFetchedURLs / maxConcurrentFetches) == 1 batch,
    /// bounded by fetchTimeout, so the worst case is one fetchTimeout regardless of how
    /// many links the buffer holds. Any URL beyond this count falls back to `host/path`
    /// without ever being fetched.
    private static let maxFetchedURLs = 16

    public init(fetcher: any TitleFetcher = URLSessionTitleFetcher(), fetchTimeout: TimeInterval = 4) {
        self.fetcher = fetcher
        self.fetchTimeout = fetchTimeout
    }

    public func apply(_ input: TransformInput) async throws -> String {
        let candidates = Self.linkable(in: input.text)
        guard !candidates.isEmpty else { return input.text }
        var unique: [URL] = []
        var seen = Set<URL>()
        for c in candidates where seen.insert(c.url).inserted { unique.append(c.url) }
        let toFetch = Array(unique.prefix(Self.maxFetchedURLs))

        let fetcher = self.fetcher
        let timeout = self.fetchTimeout
        var titles: [URL: String] = [:]
        await withTaskGroup(of: (URL, String?).self) { group in
            var next = 0
            while next < toFetch.count, next < Self.maxConcurrentFetches {
                let url = toFetch[next]; next += 1
                group.addTask { (url, await Self.fetchBounded(url, fetcher: fetcher, timeout: timeout)) }
            }
            for await (url, title) in group {
                if let title { titles[url] = title }
                if next < toFetch.count {
                    let url = toFetch[next]; next += 1
                    group.addTask { (url, await Self.fetchBounded(url, fetcher: fetcher, timeout: timeout)) }
                }
            }
        }
        return Self.render(input.text, titles: titles)
    }

    /// Races the fetcher against a sleep and returns whichever finishes first. The bound is
    /// hard only for fetchers that honor cancellation: `withTaskGroup` still awaits the losing
    /// child before returning, so a fetcher that ignores `Task.isCancelled`/cancellation can
    /// keep running past `timeout` (it just can't delay this function's result).
    /// `URLSessionTitleFetcher` does honor cancellation and is separately capped by its own
    /// 3s `timeout`/`timeoutIntervalForResource`, so in practice it returns promptly either way.
    static func fetchBounded(_ url: URL, fetcher: any TitleFetcher, timeout: TimeInterval) async -> String? {
        await withTaskGroup(of: String?.self) { group in
            group.addTask { await fetcher.title(for: url) }
            group.addTask { try? await Task.sleep(for: .seconds(timeout)); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// URLs eligible for wrapping: not already inside `[...](...)` or `<...>`.
    static func linkable(in text: String) -> [FoundURL] {
        URLFinder.find(in: text).filter { f in
            let before = text[..<f.range.lowerBound]
            let after = text[f.range.upperBound...]
            if before.hasSuffix("](") { return false }
            if before.hasSuffix("<"), after.hasPrefix(">") { return false }
            // A URL used as the *text* of an existing link: `[https://a](https://b)`.
            // Wrapping it would nest brackets and break the link.
            if before.hasSuffix("["), after.hasPrefix("](") { return false }
            return true
        }
    }

    static func fallbackTitle(for url: URL) -> String {
        let host = url.host ?? url.absoluteString
        var path = url.path
        if path.hasSuffix("/") { path.removeLast() }
        return path.isEmpty ? host : host + path
    }

    static func render(_ text: String, titles: [URL: String]) -> String {
        var out = text
        for found in linkable(in: text).reversed() {
            let title = (titles[found.url] ?? fallbackTitle(for: found.url))
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "[", with: "\\[")
                .replacingOccurrences(of: "]", with: "\\]")
            // `found.url.absoluteString`, not `found.original`: schemeless input like
            // "www.example.com" must still render with the scheme URLFinder detected.
            let target = found.url.absoluteString
                .replacingOccurrences(of: "(", with: "%28")
                .replacingOccurrences(of: ")", with: "%29")
            out.replaceSubrange(found.range, with: "[\(title)](\(target))")
        }
        return out
    }
}
