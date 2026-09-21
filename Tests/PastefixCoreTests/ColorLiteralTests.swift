import Testing
@testable import PastefixCore

@Suite struct ColorLiteralTests {
    private func p(_ s: String) -> ColorLiteral? { ColorLiteral.parse(s) }
    private func rgb255(_ c: ColorLiteral) -> [Int] { [c.red, c.green, c.blue].map { Int(($0 * 255).rounded()) } }

    @Test func hexForms() {
        #expect(rgb255(p("#fff")!) == [255, 255, 255])
        #expect(p("#ffff")?.alpha == 1)
        #expect(rgb255(p("#FF0080")!) == [255, 0, 128])
        #expect(p("#ff008080")?.alpha == 128.0 / 255.0)
        #expect(rgb255(p("  #abc  ")!) == [170, 187, 204])
    }
    @Test func rgbForms() {
        #expect(rgb255(p("rgb(255, 0, 128)")!) == [255, 0, 128])
        #expect(p("rgb(255 0 128 / 0.5)")?.alpha == 0.5)
        #expect(rgb255(p("rgb(100%, 0%, 50%)")!) == [255, 0, 128])
        #expect(p("rgba(255,0,128,50%)")?.alpha == 0.5)
        #expect(rgb255(p("RGB(300, -5, 12)")!) == [255, 0, 12])   // clamped
    }
    @Test func hslForms() {
        #expect(rgb255(p("hsl(330, 100%, 50%)")!) == [255, 0, 128])
        #expect(rgb255(p("hsl(-30 100% 50%)")!) == [255, 0, 128])   // hue wraps to 330
        #expect(p("hsla(330deg 100% 50% / .25)")?.alpha == 0.25)
        #expect(rgb255(p("hsl(0 0% 50%)")!) == [128, 128, 128])
    }
    @Test func rejects() {
        for bad in ["#ggg", "#12345", "rgb(1,2)", "red", "#fff extra", "hsl(1 2 3 4 5)", "", "rgb()", "rgb(a,b,c)"] {
            #expect(p(bad) == nil, Comment(rawValue: bad))
        }
    }
    @Test func rejectsFullwidthHexDigits() {
        #expect(p("#\u{FF26}\u{FF26}\u{FF26}") == nil)
    }
    @Test func rejectsNonFiniteNumbers() {
        for bad in ["rgb(nan, 0, 0)", "rgb(NaN 0 0)", "hsl(nan 50% 50%)", "rgb(0 0 0 / nan)", "rgb(1e400,0,0)", "rgb(infinity,0,0)"] {
            #expect(p(bad) == nil, Comment(rawValue: bad))
        }
    }
    @Test func rejectsHexFloatLiterals() {
        #expect(p("rgb(0x10, 0, 0)") == nil)
    }
    @Test func nearOpaqueAlphaPrintsOpaque() {
        let c = p("rgb(0 0 0 / 0.9999)")!
        #expect(c.cssHex == "#000000")
        #expect(c.cssRGB == "rgb(0 0 0)")
    }
    @Test func formatting() {
        let c = p("#ff0080")!
        #expect(c.cssHex == "#ff0080")
        #expect(c.cssRGB == "rgb(255 0 128)")
        #expect(c.cssHSL == "hsl(330 100% 50%)")
        #expect(c.swiftUI == "Color(red: 1.000, green: 0.000, blue: 0.502)")
        let t = p("rgb(255 0 128 / 0.5)")!
        #expect(t.cssHex == "#ff008080")
        #expect(t.cssRGB == "rgb(255 0 128 / 0.5)")
        #expect(t.cssHSL == "hsl(330 100% 50% / 0.5)")
        #expect(t.swiftUI == "Color(red: 1.000, green: 0.000, blue: 0.502, opacity: 0.500)")
        #expect(p("rgb(0 0 0 / 0.3333)")!.cssRGB == "rgb(0 0 0 / 0.333)")
    }
    /// The initialiser is public, so a non-finite component must clamp rather than trap in
    /// `Int(_:)` during formatting. Non-finite alpha becomes 1 (opaque) — the safe default.
    @Test func nonFiniteComponentsClampToZero() {
        let c = ColorLiteral(red: .nan, green: .infinity, blue: -.infinity, alpha: .nan)
        #expect(c.cssHex == "#000000")
        #expect(c.cssRGB == "rgb(0 0 0)")
        #expect(c.cssHSL == "hsl(0 0% 0%)")
        #expect(ColorLiteral(red: 2, green: -1, blue: .nan, alpha: .infinity).cssHex == "#ff0000")
    }

    /// A hue that rounds to 360 must print as 0.
    @Test func hueWrapsAtThreeSixty() {
        #expect(p("hsl(359.9999 100% 50%)")!.cssHSL == "hsl(0 100% 50%)")
    }

    @Test func roundTrips() {
        for hex in ["#000000", "#ffffff", "#ff0080", "#141414", "#603010", "#80ff00"] {
            let c = p(hex)!
            #expect(p(c.cssRGB)!.cssHex == hex, Comment(rawValue: hex))
            #expect(p(c.cssHSL)!.cssHex == hex, Comment(rawValue: hex))   // integer HSL loses ≤1/255; adjust expectation only if a listed colour provably cannot round-trip
        }
    }
}
