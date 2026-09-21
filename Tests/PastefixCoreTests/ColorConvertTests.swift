import Testing
@testable import PastefixCore

@Suite struct ColorConvertTests {
    @Test func outputs() async throws {
        #expect(try await ColorConvert(style: .hex).apply(.init(text: "rgb(255, 0, 128)")) == "#ff0080")
        #expect(try await ColorConvert(style: .rgb).apply(.init(text: "#ff0080")) == "rgb(255 0 128)")
        #expect(try await ColorConvert(style: .hsl).apply(.init(text: "#ff0080")) == "hsl(330 100% 50%)")
        #expect(try await ColorConvert(style: .swift).apply(.init(text: " #FF0080 ")) == "Color(red: 1.000, green: 0.000, blue: 0.502)")
    }
    @Test func invalidInputThrows() async {
        await #expect(throws: TransformError.invalidInput("Not a colour literal")) {
            _ = try await ColorConvert(style: .hex).apply(.init(text: "hello"))
        }
    }
    @Test func metadata() {
        let expect: [(ColorConvert.Style, String, String)] = [
            (.hex, "builtin.color.hex", "Color → CSS Hex"), (.rgb, "builtin.color.rgb", "Color → CSS rgb()"),
            (.hsl, "builtin.color.hsl", "Color → CSS hsl()"), (.swift, "builtin.color.swift", "Color → SwiftUI Color"),
        ]
        for (style, id, name) in expect {
            let t = ColorConvert(style: style)
            #expect(t.id == id); #expect(t.name == name)
            #expect(t.category == TransformCategory.colors); #expect(t.applicableKinds == [.color]); #expect(t.source == .builtin)
        }
    }
}
