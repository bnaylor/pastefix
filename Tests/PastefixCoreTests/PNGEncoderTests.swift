import Testing
import Foundation
import CoreGraphics
import ImageIO
@testable import PastefixCore

/// ImageIO leaks the encoder's buffers when a PNG is encoded into an in-memory destination
/// (`CGImageDestinationCreateWithData` into NSMutableData or CFMutableData, a custom
/// `CGDataConsumer`, and `NSBitmapImageRep.representation(using: .png)` alike) — measured at
/// roughly the output size, or more, per call, linear, never returned (malloc pressure relief
/// frees nothing). Encoding to a file does not leak. `PNGEncoder` encodes via a private temp file.
@Suite("PNGEncoder", .serialized)
struct PNGEncoderTests {
    static func physFootprint() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? Int(info.phys_footprint) : -1
    }

    /// Noise, so the PNG is about as large as the pixels (~12 MB): a leak of the output size per
    /// call is unmistakable against it.
    static func noise(width: Int = 2000, height: Int = 1500) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              let p = ctx.data?.assumingMemoryBound(to: UInt32.self) else { return nil }
        var s: UInt32 = 0x9E37_79B9
        for i in 0..<(width * height) { s ^= s << 13; s ^= s >> 17; s ^= s << 5; p[i] = s | 0xFF00_0000 }
        return ctx.makeImage()
    }

    @Test("encodes a decodable PNG of the same dimensions")
    func roundTrips() throws {
        let image = try #require(Self.noise(width: 64, height: 48))
        let png = try #require(PNGEncoder.encode(image))
        let src = try #require(CGImageSourceCreateWithData(png as CFData, nil))
        #expect(CGImageSourceGetType(src) as String? == "public.png")
        let back = try #require(CGImageSourceCreateImageAtIndex(src, 0, nil))
        #expect(back.width == 64 && back.height == 48)
    }

    @Test("repeated encodes do not grow the process footprint — measured as a slope, not a level")
    func doesNotLeak() throws {
        let image = try #require(Self.noise())
        // Warm-up past the steady state. Under the full parallel suite the footprint plateaus at
        // about 2× the output (a read-back held plus the allocator's large-block cache) — measured
        // flat across 16 encodes — so a level threshold at 2× sat exactly on it and false-failed.
        // A leak is a *slope*: ~1× the output per call, so ~8× across the measured calls.
        var outputSize = 0
        for _ in 0..<4 { autoreleasepool { outputSize = PNGEncoder.encode(image)?.count ?? 0 } }
        #expect(outputSize > 0)
        let before = Self.physFootprint()
        for _ in 0..<8 { autoreleasepool { _ = PNGEncoder.encode(image) } }
        let grown = Self.physFootprint() - before
        #expect(grown < outputSize, "footprint grew \(grown / 1_048_576) MB over 8 encodes of a \(outputSize / 1_048_576) MB PNG")
    }

    /// A directory of this test's own — the shared one is written to concurrently by other suites.
    static func privateDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("pngencoder-test-\(UUID().uuidString)", isDirectory: true)
    }

    @Test("leaves nothing behind, and the directory is owner-only")
    func cleansUp() throws {
        let dir = Self.privateDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let image = try #require(Self.noise(width: 32, height: 32))
        #expect(PNGEncoder.encode(image, in: dir) != nil)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(leftovers.isEmpty)
        let mode = try FileManager.default.attributesOfItem(atPath: dir.path)[.posixPermissions] as? Int
        #expect(mode == 0o700)
    }

    @Test("a file a crash left behind is swept on the next encode; a fresh one is not")
    func sweepsStale() throws {
        let dir = Self.privateDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let stale = dir.appendingPathComponent("stale.png"), fresh = dir.appendingPathComponent("fresh.png")
        try Data([1]).write(to: stale); try Data([2]).write(to: fresh)
        let now = Date()
        try fm.setAttributes([.modificationDate: now.addingTimeInterval(-(PNGEncoder.staleAfter + 5))], ofItemAtPath: stale.path)
        let image = try #require(Self.noise(width: 8, height: 8))
        _ = PNGEncoder.encode(image, in: dir, now: now)
        #expect(!fm.fileExists(atPath: stale.path))
        #expect(fm.fileExists(atPath: fresh.path))   // an encode in flight elsewhere is never touched
    }
}
