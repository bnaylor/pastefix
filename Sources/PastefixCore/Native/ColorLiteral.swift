import Foundation

/// An sRGB colour parsed from a CSS-style literal. Components are 0…1.
public struct ColorLiteral: Equatable, Sendable {
    public var red: Double, green: Double, blue: Double, alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = min(max(red, 0), 1); self.green = min(max(green, 0), 1)
        self.blue = min(max(blue, 0), 1); self.alpha = min(max(alpha, 0), 1)
    }

    // MARK: Parsing

    public static func parse(_ text: String) -> ColorLiteral? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !t.isEmpty else { return nil }
        if t.hasPrefix("#") { return parseHex(String(t.dropFirst())) }
        guard let open = t.firstIndex(of: "("), t.hasSuffix(")") else { return nil }
        let fn = String(t[..<open])
        let inner = String(t[t.index(after: open)..<t.index(before: t.endIndex)])
        let parts = inner.replacingOccurrences(of: "/", with: " ").replacingOccurrences(of: ",", with: " ")
            .split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard parts.count == 3 || parts.count == 4 else { return nil }
        let alpha: Double
        if parts.count == 4 { guard let a = alphaValue(parts[3]) else { return nil }; alpha = a } else { alpha = 1 }
        switch fn {
        case "rgb", "rgba":
            guard let r = channel(parts[0]), let g = channel(parts[1]), let b = channel(parts[2]) else { return nil }
            return ColorLiteral(red: r, green: g, blue: b, alpha: alpha)
        case "hsl", "hsla":
            guard let h = hue(parts[0]), let s = percent(parts[1]), let l = percent(parts[2]) else { return nil }
            let (r, g, b) = hslToRGB(h: h, s: s, l: l)
            return ColorLiteral(red: r, green: g, blue: b, alpha: alpha)
        default: return nil
        }
    }

    private static func parseHex(_ h: String) -> ColorLiteral? {
        guard h.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { return nil }
        let digits: [Character]
        switch h.count {
        case 3, 4: digits = h.flatMap { [$0, $0] }
        case 6, 8: digits = Array(h)
        default: return nil
        }
        func byte(_ i: Int) -> Double { Double(UInt8(String(digits[i..<i + 2]), radix: 16)!) / 255 }
        let a = digits.count == 8 ? byte(6) : 1
        return ColorLiteral(red: byte(0), green: byte(2), blue: byte(4), alpha: a)
    }

    private static func number(_ s: String) -> Double? {
        guard !s.contains("x") else { return nil }
        guard let d = Double(s), d.isFinite else { return nil }
        return d
    }
    private static func channel(_ s: String) -> Double? {
        if s.hasSuffix("%") { return number(String(s.dropLast())).map { $0 / 100 } }
        return number(s).map { $0 / 255 }
    }
    private static func percent(_ s: String) -> Double? {
        let core = s.hasSuffix("%") ? String(s.dropLast()) : s
        return number(core).map { min(max($0, 0), 100) / 100 }
    }
    private static func alphaValue(_ s: String) -> Double? {
        if s.hasSuffix("%") { return number(String(s.dropLast())).map { $0 / 100 } }
        return number(s)
    }
    private static func hue(_ s: String) -> Double? {
        let core = s.hasSuffix("deg") ? String(s.dropLast(3)) : s
        guard var h = number(core) else { return nil }
        h = h.truncatingRemainder(dividingBy: 360); if h < 0 { h += 360 }
        return h
    }

    static func hslToRGB(h: Double, s: Double, l: Double) -> (Double, Double, Double) {
        let c = (1 - abs(2 * l - 1)) * s
        let hp = h / 60
        let x = c * (1 - abs(hp.truncatingRemainder(dividingBy: 2) - 1))
        let (r1, g1, b1): (Double, Double, Double)
        switch hp {
        case 0..<1: (r1, g1, b1) = (c, x, 0)
        case 1..<2: (r1, g1, b1) = (x, c, 0)
        case 2..<3: (r1, g1, b1) = (0, c, x)
        case 3..<4: (r1, g1, b1) = (0, x, c)
        case 4..<5: (r1, g1, b1) = (x, 0, c)
        default:    (r1, g1, b1) = (c, 0, x)
        }
        let m = l - c / 2
        return (r1 + m, g1 + m, b1 + m)
    }

    // MARK: Formatting

    public var hsl: (h: Double, s: Double, l: Double) {
        let maxC = max(red, green, blue), minC = min(red, green, blue), d = maxC - minC
        let l = (maxC + minC) / 2
        guard d > 0 else { return (0, 0, l) }
        let s = d / (1 - abs(2 * l - 1))
        var h: Double
        if maxC == red { h = ((green - blue) / d).truncatingRemainder(dividingBy: 6) }
        else if maxC == green { h = (blue - red) / d + 2 }
        else { h = (red - green) / d + 4 }
        h *= 60; if h < 0 { h += 360 }
        return (h, s, l)
    }

    private var r255: Int { Int((red * 255).rounded()) }
    private var g255: Int { Int((green * 255).rounded()) }
    private var b255: Int { Int((blue * 255).rounded()) }
    private var hasAlpha: Bool { Int((alpha * 255).rounded()) < 255 }
    /// "0.5", "0.333", "0.25" — up to 3 decimals, trailing zeros trimmed.
    private var cssAlpha: String {
        var s = String(format: "%.3f", alpha)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }

    public var cssHex: String {
        let base = String(format: "#%02x%02x%02x", r255, g255, b255)
        return hasAlpha ? base + String(format: "%02x", Int((alpha * 255).rounded())) : base
    }
    public var cssRGB: String {
        "rgb(\(r255) \(g255) \(b255)" + (hasAlpha ? " / \(cssAlpha))" : ")")
    }
    public var cssHSL: String {
        let (h, s, l) = hsl
        return "hsl(\(Int(h.rounded())) \(Int((s * 100).rounded()))% \(Int((l * 100).rounded()))%" + (hasAlpha ? " / \(cssAlpha))" : ")")
    }
    public var swiftUI: String {
        let base = String(format: "Color(red: %.3f, green: %.3f, blue: %.3f", red, green, blue)
        return hasAlpha ? base + String(format: ", opacity: %.3f)", alpha) : base + ")"
    }
}
