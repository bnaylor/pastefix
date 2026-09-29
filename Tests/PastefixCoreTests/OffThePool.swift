import Foundation

/// Runs a synchronous body on a dispatch queue and awaits it — off Swift's cooperative pool. A
/// synchronous Vision request waits on work that needs a pool thread: run straight from a test body
/// on a narrow pool (a 3-core CI runner, or `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1`) it deadlocked
/// the whole parallel suite (measured). The app runs Vision on `ImageTransformLane`'s queue.
func offThePool<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async { continuation.resume(with: Result { try body() }) }
    }
}
