import Foundation
import Testing
@testable import PastefixCore

@Suite struct HTMLEntitiesTests {
    @Test func basicNamed() { #expect(HTMLEntities.decode("&lt;a&gt; &amp; &quot;q&quot; &apos;s&apos;") == "<a> & \"q\" 's'") }
    @Test func numericAndHex() { #expect(HTMLEntities.decode("&#8212; &#x2014; &#X2014;") == "— — —") }
    @Test func latin1Names() { #expect(HTMLEntities.decode("caf&eacute; &copy; &nbsp;&frac12;") == "café © \u{00A0}½") }
    @Test func typographicNames() { #expect(HTMLEntities.decode("&mdash;&ndash;&hellip;&ldquo;x&rdquo;&euro;&trade;") == "—–…“x”€™") }
    @Test func doubleEncodedDecodesOnce() { #expect(HTMLEntities.decode("&amp;lt;") == "&lt;") }
    @Test func unknownLeftVerbatim() { #expect(HTMLEntities.decode("&bogus; &#xZZ; & alone") == "&bogus; &#xZZ; & alone") }
    @Test func invalidScalarLeftVerbatim() { #expect(HTMLEntities.decode("&#xD800;&#9999999999;") == "&#xD800;&#9999999999;") }

    /// C0 controls (other than tab/LF/CR) stay as text: "&#0;" must never inject a NUL into the
    /// buffer, which would truncate the value for anything downstream that speaks C strings.
    @Test func c0ControlReferencesLeftVerbatim() {
        #expect(HTMLEntities.decode("&#0;") == "&#0;")
        #expect(HTMLEntities.decode("&#x1F;") == "&#x1F;")
        #expect(HTMLEntities.decode("a&#0;b&#x00;c") == "a&#0;b&#x00;c")
        #expect(HTMLEntities.decode("a&#9;b") == "a\tb")          // tab is allowed
        #expect(HTMLEntities.decode("a&#10;b&#13;c") == "a\nb\rc") // LF/CR are allowed
    }

    /// Guard against the quadratic decoder: the numeric pass must not re-index the whole buffer
    /// per match. 20 000 references (~140 KB) used to take tens of seconds.
    @Test func numericDecodeIsLinearOnLargeInput() {
        let input = String(repeating: "&#8212;", count: 20_000)
        let start = Date()
        let out = HTMLEntities.decode(input)
        let elapsed = Date().timeIntervalSince(start)
        #expect(elapsed < 1.0, "decode took \(elapsed)s")
        #expect(out == String(repeating: "\u{2014}", count: 20_000))
    }
}
