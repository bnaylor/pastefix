import Testing
@testable import PastefixCore

@Suite struct JSONActionsTests {
    @Test func prettifySortsKeysAndIndents() async throws {
        let out = try await JSONPrettify().apply(.init(text: #"{"b":[1,2,{"z":null,"a":"x/y"}],"a":"é"}"#))
        #expect(out == """
        {
          "a" : "é",
          "b" : [
            1,
            2,
            {
              "a" : "x/y",
              "z" : null
            }
          ]
        }
        """)
    }
    @Test func minify() async throws {
        #expect(try await JSONMinify().apply(.init(text: "{ \"b\" : 1 ,\n \"a\" : [ true ] }")) == #"{"a":[true],"b":1}"#)
    }
    @Test func fragmentsAllowed() async throws {
        #expect(try await JSONMinify().apply(.init(text: " 42 ")) == "42")
    }
    @Test func invalidJSONThrows() async {
        await #expect(throws: TransformError.self) { _ = try await JSONPrettify().apply(.init(text: "{ not json")) }
        do { _ = try await JSONMinify().apply(.init(text: "{ not json")); Issue.record("expected throw") }
        catch let e as TransformError { if case .invalidInput(let m) = e { #expect(m.hasPrefix("Not valid JSON")) } else { Issue.record("wrong case") } }
        catch { Issue.record("wrong error type") }
    }
    @Test func escapeAsJSONString() async throws {
        let out = try await JSONEscape().apply(.init(text: "say \"hi\"\n\ttab \\ slash / é 😀"))
        #expect(out == #""say \"hi\"\n\ttab \\ slash / é 😀""#)
    }
    @Test func metadata() {
        #expect(JSONPrettify().id == "builtin.json.pretty"); #expect(JSONPrettify().applicableKinds == [.json])
        #expect(JSONMinify().id == "builtin.json.minify");   #expect(JSONMinify().applicableKinds == [.json])
        #expect(JSONEscape().id == "builtin.json.escape");   #expect(JSONEscape().applicableKinds == nil)
        for c in [JSONPrettify().category, JSONMinify().category, JSONEscape().category] { #expect(c == TransformCategory.data) }
    }
}
