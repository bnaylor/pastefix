import Testing
@testable import PastefixCore

@Suite struct CaseConvertTests {
    private func all(_ s: String) -> [String] {
        [CaseConvert.Style.camel, .snake, .kebab, .constant].map { CaseConvert.convert(s, style: $0) }
    }

    @Test func words() {
        #expect(CaseConvert.words(in: "hello world") == ["hello", "world"])
        #expect(CaseConvert.words(in: "fooBarBaz") == ["foo", "bar", "baz"])
        #expect(CaseConvert.words(in: "HTTPServerError") == ["http", "server", "error"])
        #expect(CaseConvert.words(in: "utf8Decoder") == ["utf8", "decoder"])
        #expect(CaseConvert.words(in: "v2") == ["v2"])
        #expect(CaseConvert.words(in: "snake_case_input") == ["snake", "case", "input"])
        #expect(CaseConvert.words(in: "kebab-case-input") == ["kebab", "case", "input"])
        #expect(CaseConvert.words(in: "already_CONSTANT") == ["already", "constant"])
        #expect(CaseConvert.words(in: "hello, world!") == ["hello", "world"])
        #expect(CaseConvert.words(in: "version 2 beta") == ["version", "2", "beta"])
        #expect(CaseConvert.words(in: "café au lait") == ["café", "au", "lait"])
        #expect(CaseConvert.words(in: "---") == [])
    }

    @Test func helloWorldAllStyles() {
        #expect(all("hello world") == ["helloWorld", "hello_world", "hello-world", "HELLO_WORLD"])
    }
    @Test func acronyms() {
        #expect(all("HTTPServerError") == ["httpServerError", "http_server_error", "http-server-error", "HTTP_SERVER_ERROR"])
    }
    @Test func nonASCIILettersKept() {
        #expect(CaseConvert.convert("café au lait", style: .camel) == "caféAuLait")
    }
    @Test func perLineWithIndentationPreserved() {
        let input = "  first line\n\tsecond_line  \n\nlast"
        #expect(CaseConvert.convert(input, style: .kebab) == "  first-line\n\tsecond-line  \n\nlast")
    }
    @Test func lineWithoutTokensUnchanged() {
        #expect(CaseConvert.convert("--- ***", style: .snake) == "--- ***")
    }
    @Test func metadata() async throws {
        let cases: [(CaseConvert.Style, String, String)] = [
            (.camel, "builtin.case.camel", "camelCase"),
            (.snake, "builtin.case.snake", "snake_case"),
            (.kebab, "builtin.case.kebab", "kebab-case"),
            (.constant, "builtin.case.constant", "CONSTANT_CASE"),
        ]
        for (style, id, name) in cases {
            let t = CaseConvert(style: style)
            #expect(t.id == id)
            #expect(t.name == name)
            #expect(t.applicableKinds == nil)
            #expect(t.source == .builtin)
            #expect(try await t.apply(.init(text: "a b")).isEmpty == false)
        }
    }
}
