import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// The one way this codebase encodes a PNG — via a private temp file, never in memory.
///
/// **Why a file.** ImageIO leaks the encoder's buffers when a PNG is encoded into an in-memory
/// destination: `CGImageDestinationCreateWithData` into `NSMutableData` (~69 MB per 24 MP encode)
/// or `CFMutableData` (~129 MB), a custom `CGDataConsumer` (~129 MB), and
/// `NSBitmapImageRep.representation(using: .png)` (worse). Measured on macOS 26 with a standalone
/// program containing none of this codebase's code: linear per call, no plateau, and
/// `malloc_zone_pressure_relief` frees nothing — a leak, not allocator slack. Encoding to a file
/// URL does not leak (flat across 8 calls, including reading the bytes back). The Apple report
/// and its Feedback ID are tracked on #87. `PNGEncoderTests.doesNotLeak` fails if this ever
/// goes back to an in-memory destination.
///
/// **What touches disk.** The encoded bytes, for the duration of one call, in a directory inside
/// the per-user temporary directory created owner-only (0700), removed before returning. Callers
/// pass images that have already been through their privacy step (the sanitizer strips before it
/// encodes), but the *pixels* can still be sensitive — a screenshot of a terminal is the ordinary
/// case — which is why the directory is private and the file never outlives the call. History
/// already stores images on disk (owner-only), so this is a new place for that exposure rather
/// than a new kind.
public enum PNGEncoder {
    /// Owner-only scratch space inside the per-user temporary directory.
    public static let scratchDirectory: URL =
        FileManager.default.temporaryDirectory.appendingPathComponent("net.scromp.Pastefix.png-encode", isDirectory: true)

    /// PNG bytes for `image`, with no properties written (callers decide what metadata survives
    /// by what they put in the `CGImage`: pixels, colour space, alpha), or nil if any step fails.
    public static func encode(_ image: CGImage) -> Data? {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: scratchDirectory, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
            // Re-assert on an existing directory too: something else may have created it wider.
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scratchDirectory.path)
        } catch {
            return nil
        }
        let url = scratchDirectory.appendingPathComponent(UUID().uuidString + ".png")
        defer { try? fm.removeItem(at: url) }
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination),
              let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        return data
    }
}
