import Testing
import Foundation
@testable import PastefixCore

/// #48: an image goes up as a `SanitizedImage`, never as raw `Data`, with an image content type —
/// and (#21) the extension and content type of the format it actually holds.
@Suite("Zipline image upload body")
struct ZiplineImageUploadTests {
    static func sanitized() throws -> SanitizedImage {
        let input = try #require(Fixture.image(as: "public.png"))
        return try #require(ImageSanitizer.stripped(input))
    }

    static func sanitizedJPEG() throws -> SanitizedImage {
        let input = try #require(Fixture.image(as: "public.png"))
        return try #require(ImageSanitizer.encodings(input)?.jpeg)
    }

    @Test("an image upload's extension is its format's, and the type has no way to say otherwise")
    func extensionFollowsFormat() throws {
        let png = ZiplineUpload(image: try Self.sanitized(), expiry: .never, burnOnRead: false)
        #expect(png.fileExtension == "png")
        let jpeg = ZiplineUpload(image: try Self.sanitizedJPEG(), expiry: .never, burnOnRead: false)
        #expect(jpeg.fileExtension == "jpg")
        // `init(image:expiry:burnOnRead:)` has no extension parameter: the overlay's hidden
        // extension control is absent from the type, not merely from the view.
    }

    @Test("the JPEG multipart part is image/jpeg, named paste.jpg, carrying exactly the JPEG bytes")
    func multipartIsJPEG() throws {
        let image = try Self.sanitizedJPEG()
        #expect(image.format == .jpeg)
        let upload = ZiplineUpload(image: image, expiry: .never, burnOnRead: false)
        let body = URLSessionZiplineClient.multipartBody(for: upload, boundary: "B")
        let header = Data("Content-Disposition: form-data; name=\"file\"; filename=\"paste.jpg\"\r\nContent-Type: image/jpeg\r\n\r\n".utf8)
        let expected = Data("--B\r\n".utf8) + header + image.data + Data("\r\n--B--\r\n".utf8)
        #expect(body == expected)
        #expect(ZiplineV4Headers.headers(for: upload)["x-zipline-file-extension"] == "jpg")
    }

    @Test("the format's own names")
    func formatNames() {
        #expect(ImageFormat.png.fileExtension == "png")
        #expect(ImageFormat.png.contentType == "image/png")
        #expect(ImageFormat.jpeg.fileExtension == "jpg")
        #expect(ImageFormat.jpeg.contentType == "image/jpeg")
    }

    @Test("the multipart part is image/png carrying exactly the stripped bytes")
    func multipartIsImage() throws {
        let image = try Self.sanitized()
        let upload = ZiplineUpload(image: image, expiry: .never, burnOnRead: false)
        let body = URLSessionZiplineClient.multipartBody(for: upload, boundary: "B")
        let header = Data("Content-Disposition: form-data; name=\"file\"; filename=\"paste.png\"\r\nContent-Type: image/png\r\n\r\n".utf8)
        let expected = Data("--B\r\n".utf8) + header + image.data + Data("\r\n--B--\r\n".utf8)
        #expect(body == expected)
    }

    @Test("the text body is unchanged now that the builder branches")
    func textBodyUnchanged() throws {
        let upload = try ZiplineUpload(text: "hello", fileExtension: "txt", expiry: .never, burnOnRead: false)
        let body = URLSessionZiplineClient.multipartBody(for: upload, boundary: "B")
        #expect(body == Data("--B\r\nContent-Disposition: form-data; name=\"file\"; filename=\"paste.txt\"\r\nContent-Type: text/plain; charset=utf-8\r\n\r\nhello\r\n--B--\r\n".utf8))
    }

    @Test("byte count is what leaves: text as UTF-8, an image as its stripped bytes in either format")
    func byteCount() throws {
        let image = try Self.sanitized()
        #expect(ZiplineUpload(image: image, expiry: .never, burnOnRead: false).byteCount == image.data.count)
        let jpeg = try Self.sanitizedJPEG()
        #expect(ZiplineUpload(image: jpeg, expiry: .never, burnOnRead: false).byteCount == jpeg.data.count)
        #expect(try ZiplineUpload(text: "héllo", fileExtension: "txt", expiry: .never, burnOnRead: false).byteCount == 6)
    }
}
