import Foundation
import JavaScriptCore

public enum JSRunner {
    public static func run(source: String, input: String, timeout: TimeInterval) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let state = ResumeGuard()

            DispatchQueue.global(qos: .userInitiated).async {
                let result = evaluate(source: source, input: input)
                if state.claim() { continuation.resume(with: result) }
            }

            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if state.claim() { continuation.resume(throwing: TransformError.timeout) }
            }
        }
    }

    private static func evaluate(source: String, input: String) -> Result<String, Error> {
        guard let context = JSContext() else {
            return .failure(TransformError.scriptFailed("could not create JSContext"))
        }
        context.evaluateScript(source)
        if let exception = context.exception {
            return .failure(TransformError.scriptFailed(exception.toString()))
        }

        guard let fn = context.objectForKeyedSubscript("transform"), !fn.isUndefined else {
            return .failure(TransformError.scriptFailed("no transform(text) function defined"))
        }
        context.exception = nil
        let value = fn.call(withArguments: [input])
        if let exception = context.exception {
            return .failure(TransformError.scriptFailed(exception.toString()))
        }
        guard let value, value.isString else {
            return .failure(TransformError.scriptFailed("transform() did not return a string"))
        }
        return .success(value.toString())
    }
}

/// Ensures a continuation is resumed exactly once across racing closures.
private final class ResumeGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}
