import Testing
import Foundation
@testable import PastefixCore

@Suite("Strip Image Metadata (#82)")
struct StripImageMetadataTests {
    @Test("strips a GPS-tagged image and says what went")
    func strips() throws {
        let data = try #require(Fixture.image(as: "public.png"))
        guard case .image(let out, let note) = try StripImageMetadata().transformImage(data) else {
            Issue.record("expected an image"); return
        }
        #expect(ImageMetadata.inspect(out).isEmpty)
        #expect(note == "Removed location, camera details and other metadata.")
    }

    @Test("a clean image has nothing to remove, and nothing is re-encoded")
    func clean() throws {
        let original = try #require(Fixture.image(as: "public.png"))
        let clean = try #require(ImageSanitizer.stripped(original))
        #expect(try StripImageMetadata().transformImage(clean.data) == .nothingToDo(ImageMetadata.nothingToRemoveMessage))
    }

    @Test("it is registered, in Privacy, for images only")
    func registered() {
        let t = TransformerRegistry(config: RegistryConfig(scriptsDirectory: URL(fileURLWithPath: "/nonexistent")))
            .load().first { $0.id == "builtin.stripimagemetadata" }
        #expect(t?.name == "Strip Image Metadata" && t?.category == TransformCategory.privacy)
        #expect(t?.acceptedForms == [.image])
    }
}
