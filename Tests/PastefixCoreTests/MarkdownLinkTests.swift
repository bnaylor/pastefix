import Testing
import Foundation
@testable import PastefixCore

/// Offline fetcher: returns canned titles; optional delay; records calls.
private actor CallLog { var urls: [URL] = []; func add(_ u: URL) { urls.append(u) } }

private struct StubTitleFetcher: TitleFetcher {
    var titles: [String: String] = [:]
    var delay: Duration = .zero
    var log = CallLog()
    func title(for url: URL) async -> String? {
        await log.add(url)
        if delay > .zero { try? await Task.sleep(for: delay) }
        return titles[url.absoluteString]
    }
}

@Suite struct MarkdownLinkTests {
    @Test func rendersFetchedTitle() async throws {
        let t = MarkdownLink(fetcher: StubTitleFetcher(titles: ["https://ex.com/a": "Example A"]))
        #expect(try await t.apply(.init(text: "see https://ex.com/a today")) == "see [Example A](https://ex.com/a) today")
    }
    @Test func fallbackWhenFetcherReturnsNil() async throws {
        let t = MarkdownLink(fetcher: StubTitleFetcher())
        #expect(try await t.apply(.init(text: "https://ex.com/docs/intro/")) == "[ex.com/docs/intro](https://ex.com/docs/intro/)")
    }
    @Test func bareHostFallback() {
        #expect(MarkdownLink.fallbackTitle(for: URL(string: "https://ex.com/")!) == "ex.com")
        #expect(MarkdownLink.fallbackTitle(for: URL(string: "https://ex.com")!) == "ex.com")
    }
    @Test func escapesBracketsInTitle() {
        let out = MarkdownLink.render("https://ex.com/x", titles: [URL(string: "https://ex.com/x")!: "A [b] c"])
        #expect(out == "[A \\[b\\] c](https://ex.com/x)")
    }
    @Test func percentEncodesParensInURL() {
        let u = "https://en.wikipedia.org/wiki/Foo_(bar)"
        let out = MarkdownLink.render(u, titles: [URL(string: u)!: "Foo"])
        #expect(out == "[Foo](https://en.wikipedia.org/wiki/Foo_%28bar%29)")
    }
    @Test func leavesExistingMarkdownLinksAlone() {
        let text = "[Already](https://ex.com/a) and <https://ex.com/b> and https://ex.com/c"
        let titles = [URL(string: "https://ex.com/c")!: "C"]
        #expect(MarkdownLink.render(text, titles: titles) == "[Already](https://ex.com/a) and <https://ex.com/b> and [C](https://ex.com/c)")
    }
    @Test func multipleURLsPreserveOrderAndFetchEachOnce() async throws {
        let stub = StubTitleFetcher(titles: ["https://one.test/": "One", "https://two.test/": "Two"])
        let t = MarkdownLink(fetcher: stub)
        let out = try await t.apply(.init(text: "https://one.test/ https://two.test/ https://one.test/"))
        #expect(out == "[One](https://one.test/) [Two](https://two.test/) [One](https://one.test/)")
        #expect(await stub.log.urls.count == 2)
    }
    @Test func slowFetcherFallsBackWithinTimeout() async throws {
        let t = MarkdownLink(fetcher: StubTitleFetcher(delay: .seconds(10)), fetchTimeout: 0.2)
        let start = ContinuousClock.now
        let out = try await t.apply(.init(text: "https://slow.test/p"))
        #expect(out == "[slow.test/p](https://slow.test/p)")
        #expect(ContinuousClock.now - start < .seconds(3))
    }
    @Test func noURLsUnchanged() async throws {
        #expect(try await MarkdownLink(fetcher: StubTitleFetcher()).apply(.init(text: "plain")) == "plain")
    }
    @Test func metadata() {
        let t = MarkdownLink(fetcher: StubTitleFetcher())
        #expect(t.id == "builtin.markdownlink")
        #expect(t.name == "URL → Markdown Link")
        #expect(t.applicableKinds == [.url])
    }
    @Test func schemelessURLGetsSchemeInTarget() {
        let u = URL(string: "http://www.example.com/p")!
        #expect(MarkdownLink.render("see www.example.com/p", titles: [u: "Ex"]) == "see [Ex](http://www.example.com/p)")
    }
    @Test func escapesBackslashBeforeBrackets() {
        let u = URL(string: "https://ex.com/x")!
        let out = MarkdownLink.render("https://ex.com/x", titles: [u: "a\\b [c]"])
        #expect(out == "[a\\\\b \\[c\\]](https://ex.com/x)")
    }
    @Test func urlUsedAsExistingLinkTextIsLeftAlone() {
        let text = "[https://ex.com/a](https://ex.com/b)"
        #expect(MarkdownLink.render(text, titles: [:]) == text)
    }
    @Test func fetchCountBoundedAtSixteen() async throws {
        let urls = (1...20).map { "https://host\($0).test/p\($0)" }
        let titles = Dictionary(uniqueKeysWithValues: urls.map { ($0, "Title-\($0)") })
        let stub = StubTitleFetcher(titles: titles)
        let t = MarkdownLink(fetcher: stub)
        let out = try await t.apply(.init(text: urls.joined(separator: " ")))
        #expect(await stub.log.urls.count == 16)
        let fetchedTitleCount = urls.filter { out.contains("[Title-\($0)]") }.count
        #expect(fetchedTitleCount == 16)
    }
}
