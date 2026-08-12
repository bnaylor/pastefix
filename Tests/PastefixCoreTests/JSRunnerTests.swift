import Testing
import Foundation
@testable import PastefixCore

@Suite struct JSRunnerTests {
    @Test func callsTransformFunction() async throws {
        let src = "function transform(t){ return t.toUpperCase(); }"
        let out = try await JSRunner.run(source: src, input: "hello", timeout: 5)
        #expect(out == "HELLO")
    }

    @Test func missingTransformThrows() async throws {
        await #expect(throws: TransformError.scriptFailed("no transform(text) function defined")) {
            try await JSRunner.run(source: "var x = 1;", input: "hi", timeout: 5)
        }
    }

    @Test func jsExceptionThrows() async throws {
        let src = "function transform(t){ throw new Error('nope'); }"
        do {
            _ = try await JSRunner.run(source: src, input: "hi", timeout: 5)
            Issue.record("Expected TransformError.scriptFailed but run() succeeded")
        } catch let err as TransformError {
            if case .scriptFailed = err { /* pass */ } else {
                Issue.record("Expected .scriptFailed, got \(err)")
            }
        }
    }

    @Test func runawayScriptTimesOut() async throws {
        let src = "function transform(t){ while(true){} }"
        await #expect(throws: TransformError.timeout) {
            try await JSRunner.run(source: src, input: "hi", timeout: 1)
        }
    }
}
