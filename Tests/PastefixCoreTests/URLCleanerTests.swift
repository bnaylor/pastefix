import Testing
import Foundation
@testable import PastefixCore

@Suite struct URLCleanerTests {
    let subject = URLCleaner()
    private func clean(_ s: String) -> String { URLCleaner.clean(s) }

    @Test func stripsUTMAndRemovesEmptyQuery() {
        #expect(clean("https://ex.com/p?utm_source=a&utm_medium=b") == "https://ex.com/p")
    }
    @Test func keepsOtherParamsInOrder() {
        #expect(clean("https://ex.com/p?a=1&utm_source=x&b=2&fbclid=Z&c=3") == "https://ex.com/p?a=1&b=2&c=3")
    }
    @Test func preservesFragment() {
        #expect(clean("https://ex.com/p?utm_campaign=c#section-2") == "https://ex.com/p#section-2")
    }
    @Test func preservesPercentEncodingOfKeptValues() {
        #expect(clean("https://ex.com/s?q=a%20b%26c&gclid=1") == "https://ex.com/s?q=a%20b%26c")
    }
    @Test func caseInsensitiveNames() {
        #expect(clean("https://ex.com/?UTM_SOURCE=x&FBCLID=y&Keep=1") == "https://ex.com/?Keep=1")
    }
    @Test func refDroppedButRefreshKept() {
        #expect(clean("https://ex.com/?ref=tw&refresh=1") == "https://ex.com/?refresh=1")
    }
    @Test func multipleURLsInProseTextIntact() {
        let input = "See https://a.test/x?utm_source=1 and (https://b.test/y?id=2&si=abc), ok."
        #expect(clean(input) == "See https://a.test/x and (https://b.test/y?id=2), ok.")
    }
    @Test func untouchedURLIsByteIdentical() {
        let odd = "https://ex.com/a%2Fb?x=%7E&y=1#frag"
        #expect(clean("go \(odd) now") == "go \(odd) now")
    }
    @Test func noQueryUnchanged() { #expect(clean("https://ex.com/path") == "https://ex.com/path") }
    @Test func bareWWWKeepsItsForm() {
        #expect(clean("www.ex.com/p?utm_source=a&k=1") == "www.ex.com/p?k=1")
    }
    @Test func plainTextUnchanged() { #expect(clean("no links here") == "no links here") }
    @Test func isTrackingList() {
        #expect(URLCleaner.isTracking("utm_anything"))
        #expect(URLCleaner.isTracking("mc_eid"))
        #expect(!URLCleaner.isTracking("id"))
    }
    @Test func htmlEscapedAmpersandSeparatorsAreNormalisedAndCleaned() {
        let input = "https://ex.com/p?utm_source=news&amp;utm_medium=email&amp;utm_campaign=black+friday+sale&amp;id=7"
        #expect(clean(input) == "https://ex.com/p?id=7")
    }
    @Test func htmlEscapedAmpersandWithoutTrackingIsStillNormalised() {
        #expect(clean("https://ex.com/p?a=1&amp;b=2") == "https://ex.com/p?a=1&b=2")
    }
    @Test func literalAmpInParamValueSurvivesOnlyWhenNotASeparator() {
        // `amp` as a real parameter name is untouched; only the `&amp;` escape sequence is normalised.
        #expect(clean("https://ex.com/p?amp=1&x=2") == "https://ex.com/p?amp=1&x=2")
    }
    @Test func applyAndMetadata() async throws {
        #expect(try await subject.apply(.init(text: "https://ex.com/?utm_x=1")) == "https://ex.com/")
        #expect(subject.id == "builtin.urlclean")
        #expect(subject.applicableKinds == [.url])
        #expect(subject.source == .builtin)
        #expect(subject.requiresRichInput == false)
    }
}
