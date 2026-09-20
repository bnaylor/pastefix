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

    public func title(for url: URL) async -> String? {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.setValue("text/html", forHTTPHeaderField: "Accept")
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  (http.mimeType ?? "").lowercased().contains("html") else { return nil }
            var data = Data()
            for try await byte in bytes {
                data.append(byte)
                if data.count >= maxBytes { break }
            }
            return Self.parseTitle(data: data)
        } catch {
            return nil
        }
    }

    static func parseTitle(data: Data) -> String? {
        let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
        guard let open = html.range(of: "<title[^>]*>", options: [.regularExpression, .caseInsensitive]),
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
            guard let re = try? NSRegularExpression(pattern: pattern) else { continue }
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
        let named = ["&lt;": "<", "&gt;": ">", "&quot;": "\"", "&apos;": "'", "&nbsp;": " ", "&amp;": "&"]
        for (k, v) in named { out = out.replacingOccurrences(of: k, with: v) }
        return out
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
    private static let maxConcurrentFetches = 8

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

        let fetcher = self.fetcher
        let timeout = self.fetchTimeout
        var titles: [URL: String] = [:]
        await withTaskGroup(of: (URL, String?).self) { group in
            var next = 0
            while next < unique.count, next < Self.maxConcurrentFetches {
                let url = unique[next]; next += 1
                group.addTask { (url, await Self.fetchBounded(url, fetcher: fetcher, timeout: timeout)) }
            }
            for await (url, title) in group {
                if let title { titles[url] = title }
                if next < unique.count {
                    let url = unique[next]; next += 1
                    group.addTask { (url, await Self.fetchBounded(url, fetcher: fetcher, timeout: timeout)) }
                }
            }
        }
        return Self.render(input.text, titles: titles)
    }

    /// Races the fetcher against a sleep so a hung fetcher cannot hang the app.
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
                .replacingOccurrences(of: "[", with: "\\[")
                .replacingOccurrences(of: "]", with: "\\]")
            let target = String(found.original)
                .replacingOccurrences(of: "(", with: "%28")
                .replacingOccurrences(of: ")", with: "%29")
            out.replaceSubrange(found.range, with: "[\(title)](\(target))")
        }
        return out
    }
}
