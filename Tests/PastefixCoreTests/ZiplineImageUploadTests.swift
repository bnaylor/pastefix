import Testing
import Foundation
@testable import PastefixCore

/// #48: an image goes up as a `SanitizedImage`, never as raw `Data`, with an image content type.
@Suite("Zipline image upload body")
struct ZiplineImageUploadTests {
    static func sanitized() throws -> SanitizedImage {
        let input = try #require(Fixture.image(as: "public.png"))
        return try #require(ImageSanitizer.stripped(input))
    }

    @Test("an image upload is png, and the type has no way to say otherwise")
    func imageIsPNG() throws {
        let upload = ZiplineUpload(image: try Self.sanitized(), expiry: .never, burnOnRead: false)
        #expect(upload.fileExtension == "png")
        // `init(image:expiry:burnOnRead:)` has no extension parameter: the overlay's hidden
        // extension control is absent from the type, not merely from the view.
    }

    @Test("the multipart part is image/png carrying exactly the stripped bytes")
    func multipartIsImage() throws {
        let image = try Self.sanitized()
        let upload = ZiplineUpload(image: image, expiry: .never, burnOnRead: false)
        let body = URLSessionZiplineClient.multipartBody(for: upload, boundary: "B")
        let header = Data("Content-Disposition: form-data; name=\"file\"; filename=\"paste.png\"\r\nContent-Type: image/png\r\n\r\n".utf8)
        let expected = Data("--B\r\n".utf8) + header + image.png + Data("\r\n--B--\r\n".utf8)
        #expect(body == expected)
    }

    @Test("the text body is unchanged now that the builder branches")
    func textBodyUnchanged() throws {
        let upload = try ZiplineUpload(text: "hello", fileExtension: "txt", expiry: .never, burnOnRead: false)
        let body = URLSessionZiplineClient.multipartBody(for: upload, boundary: "B")
        #expect(body == Data("--B\r\nContent-Disposition: form-data; name=\"file\"; filename=\"paste.txt\"\r\nContent-Type: text/plain; charset=utf-8\r\n\r\nhello\r\n--B--\r\n".utf8))
    }

    @Test("byte count is what leaves: text as UTF-8, an image as its stripped PNG")
    func byteCount() throws {
        let image = try Self.sanitized()
        #expect(ZiplineUpload(image: image, expiry: .never, burnOnRead: false).byteCount == image.png.count)
        #expect(try ZiplineUpload(text: "héllo", fileExtension: "txt", expiry: .never, burnOnRead: false).byteCount == 6)
    }
}
