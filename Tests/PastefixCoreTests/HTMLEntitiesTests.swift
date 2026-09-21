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
}
