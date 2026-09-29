import Foundation
import PastefixCore
@testable import PastefixAppCore

/// `ImageUploadPreparation.prepare`, run on a dispatch queue and awaited — off Swift's cooperative
/// pool. `prepare` runs Vision synchronously, and a synchronous Vision request waits on work that
/// needs a pool thread: called straight from a test body on a narrow pool (a 3-core CI runner, or
/// `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1`) it deadlocked the whole parallel suite (measured: 756
/// tests started, none finished). The app runs it on its own lane's queue for the same reason.
enum OffPool {
    static func prepare(_ png: Data,
                        maxPixels: Int = PixelLimits.maxConvertiblePixels,
                        maxBytes: Int = UploadLimits.maxPayloadBytes) async -> ImageUploadPreparation.Outcome {
        await run { ImageUploadPreparation.prepare(png, maxPixels: maxPixels, maxBytes: maxBytes) }
    }

    static func prepare(_ png: Data, maxPixels: Int, maxBytes: Int,
                        encode: @escaping @Sendable (Data, Int) -> SanitizedEncodings?) async -> ImageUploadPreparation.Outcome {
        await run { ImageUploadPreparation.prepare(png, maxPixels: maxPixels, maxBytes: maxBytes, encode: encode) }
    }

    static func run<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { continuation.resume(returning: body()) }
        }
    }
}
