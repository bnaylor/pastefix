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
/// URL does not leak (flat across 8 calls, including reading the bytes back). Reported to Apple
/// as FB24956933 (tracked on #87); when it is fixed, `PNGEncoderTests.doesNotLeak` says whether
/// an in-memory encode is safe again. `PNGEncoderTests.doesNotLeak` fails if this ever
/// goes back to an in-memory destination.
///
/// **What touches disk.** The encoded bytes, for the duration of one call, in a directory inside
/// the per-user temporary directory created owner-only (0700), removed before returning. The
/// *pixels* can be sensitive — a screenshot of a terminal is the ordinary case — which is why the
/// directory is private and the file never outlives the call. This is a **new kind** of on-disk
/// exposure in two cases, stated rather than hidden: with history turned off, and for a summon
/// from an excluded app (⌘⇧C converts any TIFF through here, and the session path does not apply
/// the capture filters — deliberately, since the user summoned it). Before, neither put image
/// bytes on disk at all. Accepted, because the alternative is a leak of the image's size on every
/// conversion; `ImageIO` refuses a descriptor-only destination (`/dev/fd/N` after unlinking), so a
/// path on disk is unavoidable with a file destination.
///
/// **A crash mid-encode** skips `defer`, so each encode first sweeps anything in the directory
/// older than `staleAfter` — an encode takes a second or two, so the sweep can never touch a live
/// one.
///
/// **Main-actor cost:** `ClipboardBridge.snapshot` converts a TIFF on the main actor, so a TIFF
/// summon now pays a file write and read-back there — milliseconds for a screenshot-sized image,
/// on top of the conversion that was already there.
public enum PNGEncoder {
    /// Owner-only scratch space inside the per-user temporary directory.
    public static let scratchDirectory: URL =
        FileManager.default.temporaryDirectory.appendingPathComponent("net.scromp.Pastefix.png-encode", isDirectory: true)

    /// Anything older than this in the scratch directory is left over from a crash, not in use.
    static let staleAfter: TimeInterval = 60

    /// PNG bytes for `image`, with no properties written (callers decide what metadata survives
    /// by what they put in the `CGImage`: pixels, colour space, alpha), or nil if any step fails.
    public static func encode(_ image: CGImage) -> Data? {
        encode(image, in: scratchDirectory)
    }

    /// `encode(_:)` with an explicit directory — tests use their own, so a parallel suite encoding
    /// through the shared one cannot race an assertion about what is left behind.
    static func encode(_ image: CGImage, in directory: URL, now: Date = Date()) -> Data? {
        encodeViaFile(image, type: .png, options: nil, in: directory, now: now)
    }

    /// The shared body of `encode(_:in:now:)` and `JPEGEncoder.encode(_:quality:)`: a bare
    /// `CGImage` added with `CGImageDestinationAddImage` — never `AddImageFromSource`, which would
    /// carry the source's metadata, MakerNote, gain maps and auxiliary images across — to a file
    /// in the owner-only scratch directory, read back, and removed.
    ///
    /// `options` is for *encoder* options only (JPEG's lossy-compression quality). It is not a
    /// metadata channel: nothing of the source is passed here, and `ImageSanitizerTests` walks the
    /// JPEG's segments to prove it.
    static func encodeViaFile(_ image: CGImage, type: UTType, options: [CFString: Any]?,
                              in directory: URL, now: Date = Date()) -> Data? {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
            // Re-assert on an existing directory too: something else may have created it wider.
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        } catch {
            return nil
        }
        sweepStale(in: directory, now: now)
        let url = directory.appendingPathComponent(UUID().uuidString + "." + (type.preferredFilenameExtension ?? "img"))
        defer { try? fm.removeItem(at: url) }
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, options as CFDictionary?)
        guard CGImageDestinationFinalize(destination),
              let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        return data
    }

    /// Removes files a crash left behind: anything modified more than `staleAfter` ago.
    static func sweepStale(in directory: URL, now: Date) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])
        else { return }
        for entry in entries {
            let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if now.timeIntervalSince(modified) > staleAfter { try? fm.removeItem(at: entry) }
        }
    }
}

/// The one way this codebase encodes a JPEG (#21): `PNGEncoder`'s file path, with the quality as
/// the only option.
///
/// JPEG encoding measured **no** in-memory leak (+0 MB over six encodes; #87 is PNG-specific). It
/// goes through the file anyway, so there is one encode path to reason about rather than two.
///
/// What ImageIO writes, measured on macOS 26.3.1 and 26.6.2 for a bare `CGImage` with only the
/// quality option: SOI, APP0 JFIF, APP1 Exif (pixel dimensions, plus ColorSpace for sRGB — no
/// IFD1, so no thumbnail), APP13 "Photoshop 3.0" with an *empty* IPTC record and its digest, APP2
/// ICC_PROFILE (for any space but sRGB), then the frame. The APP1 and APP13 are ImageIO's own,
/// not carried from anywhere; `ImageSanitizerTests` admits them by exact content.
public enum JPEGEncoder {
    /// JPEG bytes for `image` at `quality` (0…1), with no metadata passed in, or nil.
    public static func encode(_ image: CGImage, quality: Double) -> Data? {
        PNGEncoder.encodeViaFile(image, type: .jpeg,
                                 options: [kCGImageDestinationLossyCompressionQuality: quality],
                                 in: PNGEncoder.scratchDirectory)
    }
}
