import Testing
import Foundation
@testable import PastefixAppCore

/// The test that makes `ClipboardSnapshot.storedPropertyClasses` a rule instead of a comment.
///
/// The claim this replaces was that "Save is a no-op when the session cannot reproduce the
/// clipboard" is a principle broad enough to cover #71 for free. It was false: if #71 records a
/// file reference on `ClipboardSnapshot` and does not grow `SavePayload`, the predicate never
/// mentions the new field, the payload is non-empty, `refusedImagePixels` is nil — so Save clears
/// the clipboard and drops the reference, silently. A principle nobody is forced to re-read when
/// they add a field is a list of cases with better prose.
///
/// So the enforcement is mechanical: enumerate the stored properties with `Mirror` and fail on any
/// one that has not been classified. A new field on `ClipboardSnapshot` fails here until someone
/// decides what a Save owes it.
@Suite("ClipboardSnapshot representation classification")
struct ClipboardSnapshotClassificationTests {
    /// Every stored property populated, so `Mirror` cannot miss one for being nil (it does not —
    /// a nil `Optional` child is still a child — but a fixture that relies on that is a fixture
    /// that stops testing this if it ever stops being true).
    private let snapshot = ClipboardSnapshot(plainText: "text", richRTFD: Data([0x7B]),
                                             imagePNG: Data([0x89, 0x50]),
                                             refusedImagePixels: 30_000_000, changeCount: 7)

    private var mirroredStoredProperties: Set<String> {
        Set(Mirror(reflecting: snapshot).children.compactMap(\.label))
    }

    @Test("every stored property is classified into exactly one bucket")
    func everyStoredPropertyIsClassified() {
        let reflected = mirroredStoredProperties
        #expect(reflected.isEmpty == false, "Mirror saw no stored properties — this test is vacuous")
        let classified = Set(ClipboardSnapshot.storedPropertyClasses.keys)

        let unclassified = reflected.subtracting(classified)
        #expect(unclassified.isEmpty, """
            ClipboardSnapshot gained \(unclassified.sorted()) without deciding what Save owes it. \
            Add each to ClipboardSnapshot.storedPropertyClasses as one of: reproducedByPayload (grow \
            SavePayload too, AND write the comparison in unreproduced(by:) — that step is not \
            mechanical and nothing checks it), droppedByPolicy (and say why, where \
            saveWouldLoseContent names the rich-text exception), metadata (not clipboard content), \
            or lossIfPresent (reported automatically — classifying it is the whole job; populate it \
            in ClipboardSnapshotLossIfPresentTests.fixture, which fails until you do).
            """)
    }

    @Test("no classified name has stopped being a stored property")
    func classificationHasNoStaleEntries() {
        // The other direction, so a renamed or deleted field cannot leave a bucket entry standing
        // in for it and keep the test above green.
        let stale = Set(ClipboardSnapshot.storedPropertyClasses.keys)
            .subtracting(mirroredStoredProperties)
        #expect(stale.isEmpty, "classified but no longer stored: \(stale.sorted())")
    }

    @Test("Mirror sees exactly today's five properties")
    func todaysProperties() {
        // Pinned as a fact about the reflection, not just about the dictionary: if `Mirror` ever
        // stops reporting a stored property of this struct (a macro, a property wrapper, a move to
        // a class), the two tests above go quietly weaker and this one says so instead.
        #expect(mirroredStoredProperties == ["plainText", "richRTFD", "imagePNG",
                                            "refusedImagePixels", "changeCount"])
    }

    @Test("the four buckets are the four the predicate is written against")
    func bucketsAreStable() {
        #expect(Set(ClipboardSnapshot.RepresentationClass.allCases.map(\.rawValue))
                == ["reproducedByPayload", "droppedByPolicy", "metadata", "lossIfPresent"])
    }
}

/// `unreproduced(by:)` itself: what an unedited Save is allowed to drop and what it must refuse
/// over. `saveWouldLoseContent` is this set being non-empty, gated on `isUnedited`, and is covered
/// from the Save side in `SavePayloadTests`.
@Suite("ClipboardSnapshot.unreproduced(by:)")
struct ClipboardSnapshotUnreproducedTests {
    private let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])

    @Test("a plain-text session reproduces everything it holds")
    func plainTextRoundTrips() {
        let origin = ClipboardSnapshot(plainText: "hello", richRTFD: nil)
        #expect(origin.unreproduced(by: SavePayload(document: PasteDocument(origin: origin))).isEmpty)
    }

    @Test("an image session reproduces the image byte for byte")
    func imageRoundTrips() {
        let origin = ClipboardSnapshot(plainText: nil, richRTFD: nil, imagePNG: png)
        #expect(origin.unreproduced(by: SavePayload(document: PasteDocument(origin: origin))).isEmpty)
    }

    @Test("strip formatting is not a loss — rich content is dropped by policy")
    func richIsDroppedByPolicy() {
        // The behaviour the reworded doc comment exists to protect. Summon over a rich-text copy,
        // ⌘S, and the clipboard now holds plain text: the RTFD *is* gone, and that is the feature.
        // If this test ever fails because `.richContent` joined the set, someone has tightened the
        // predicate to match a tidier sentence and broken strip-formatting.
        let origin = ClipboardSnapshot(plainText: "styled text", richRTFD: Data([0x7B, 0x5C, 0x72, 0x74]))
        let doc = PasteDocument(origin: origin)
        #expect(origin.unreproduced(by: SavePayload(document: doc)).isEmpty)
        #expect(doc.saveWouldLoseContent == false, "⌘S over a rich copy must still strip formatting")
    }

    @Test("a refused image is a loss however full the payload is")
    func refusedImageIsAlwaysALoss() {
        let origin = ClipboardSnapshot(plainText: "notes about that photo", richRTFD: nil,
                                       imagePNG: nil, refusedImagePixels: 30_000_000)
        #expect(origin.unreproduced(by: SavePayload(document: PasteDocument(origin: origin)))
                == [.lossIfPresent("refusedImagePixels")])
    }

    @Test("a payload that writes nothing loses the whole clipboard, known representations or not")
    func emptyPayloadLosesEverything() {
        // Includes the case no field can describe: a Finder file copy leaves `plainText` nil (or a
        // filename), no image (the TIFF is the icon), and nothing else this type stores — so the
        // only thing that makes ⌘S a no-op there is `.wholeClipboard`. Dropping that case would
        // turn summon-then-⌘S over a copied file into "clipboard cleared".
        let empty = ClipboardSnapshot(plainText: nil, richRTFD: nil)
        #expect(empty.unreproduced(by: SavePayload(document: PasteDocument(origin: empty)))
                == [.wholeClipboard])
        #expect(PasteDocument(origin: empty).saveWouldLoseContent)
    }

    @Test("an empty image is not a representation, so it is not a loss")
    func emptyImageBytesAreNotContent() {
        // `SavePayload` turns `Data()` into nil — that is the backstop against a zero-byte
        // `public.png`. The predicate must agree that nothing was lost, or every such session
        // becomes an un-saveable one.
        let origin = ClipboardSnapshot(plainText: "text", richRTFD: nil, imagePNG: Data())
        #expect(origin.unreproduced(by: SavePayload(document: PasteDocument(origin: origin))).isEmpty)
    }

    @Test("a payload that drops a real image reports it")
    func aDroppedImageIsReported() {
        // No document produces this today (`SavePayload(document:)` carries `origin.imagePNG`
        // through), so it is asserted against a hand-built payload: the point is that the
        // classification reports an unreproduced image rather than trusting that no caller can
        // ever construct one — which is exactly the trust that made the Markdown branch a bug.
        let origin = ClipboardSnapshot(plainText: "caption", richRTFD: nil, imagePNG: png)
        #expect(origin.unreproduced(by: SavePayload(text: "caption")) == [.image])
    }

    @Test("a payload that drops the text reports it")
    func droppedTextIsReported() {
        let origin = ClipboardSnapshot(plainText: "hello", richRTFD: nil)
        #expect(origin.unreproduced(by: SavePayload(text: nil, imagePNG: png)) == [.plainText])
    }

    @Test("blank origin text is not a representation", arguments: ["", " ", "\n", "  \t\n "])
    func blankOriginTextIsNothing(_ blank: String) {
        // Same rule as `SavePayload.isEmpty` and `displaysAsImage`. Asserted against an image
        // payload so `.wholeClipboard` is not what makes the set non-empty.
        let origin = ClipboardSnapshot(plainText: blank, richRTFD: nil, imagePNG: png)
        #expect(origin.unreproduced(by: SavePayload(text: nil, imagePNG: png)).isEmpty)
    }

    @Test("changeCount is metadata, not content")
    func changeCountIsNotContent() {
        let origin = ClipboardSnapshot(plainText: "hello", richRTFD: nil, changeCount: 41)
        #expect(origin.unreproduced(by: SavePayload(document: PasteDocument(origin: origin))).isEmpty)
    }
}

/// The tests that make the `.lossIfPresent` bucket *be* the implementation.
///
/// What they replace: a classification dictionary nothing read. The reviewer reproduced the hole by
/// doing what an honest #71 implementer does — add `fileReference`, classify it `.lossIfPresent`
/// correctly, update the pinned property set because it fails otherwise, and leave
/// `unreproduced(by:)` alone. Every test stayed green while an unedited `"hello"` session holding a
/// file reference reported `saveWouldLoseContent == false`, so Save wrote `"hello"` and dropped the
/// reference. The earlier "verified to bite" check added the field *without* classifying it, which
/// is the one variant that did fail.
///
/// Neither of the two tests that carry the weight here can be silenced by editing a literal list:
/// both derive what they expect from `storedPropertyClasses` itself.
@Suite("ClipboardSnapshot .lossIfPresent is driven by the classification")
struct ClipboardSnapshotLossIfPresentTests {
    /// The same presence rule `unreproduced(by:)` applies, written out again here rather than shared
    /// with it: a fixture check that called the code under test would agree with it by construction.
    private func isPresent(_ value: Any) -> Bool {
        let mirror = Mirror(reflecting: value)
        guard mirror.displayStyle == .optional else { return true }
        return mirror.children.isEmpty == false
    }

    private var lossIfPresentProperties: Set<String> {
        Set(ClipboardSnapshot.storedPropertyClasses.filter { $0.value == .lossIfPresent }.keys)
    }

    /// Every `.lossIfPresent` property populated, and nothing that could contribute another case:
    /// no origin text and no origin image (so no `.plainText`/`.image`), weighed below against a
    /// payload that writes something (so no `.wholeClipboard`). Whatever comes back is the bucket
    /// alone.
    private let fixture = ClipboardSnapshot(plainText: nil, richRTFD: nil, imagePNG: nil,
                                            refusedImagePixels: 30_000_000, changeCount: 7)

    @Test("the fixture populates every .lossIfPresent property")
    func fixtureIsNotVacuous() {
        #expect(lossIfPresentProperties.isEmpty == false, "no .lossIfPresent bucket — test is vacuous")
        let mirrored = Dictionary(uniqueKeysWithValues:
            Mirror(reflecting: fixture).children.compactMap { child in
                child.label.map { ($0, child.value) }
            })
        let unpopulated = lossIfPresentProperties.filter { !isPresent(mirrored[$0] as Any) }
        #expect(unpopulated.isEmpty, """
            ClipboardSnapshot classifies \(unpopulated.sorted()) as lossIfPresent but this suite's \
            fixture leaves them nil, so the test below cannot see whether unreproduced(by:) reports \
            them. Populate them in `fixture`.
            """)
    }

    @Test("the reported loss set is exactly the populated .lossIfPresent properties")
    func reportedLossesAreExactlyTheClassifiedOnes() {
        // The reviewer's variant, as an assertion: the expectation is derived from the dictionary, so
        // a property classified `.lossIfPresent` and not reported fails here. Populating the fixture
        // above is the only step #71 owes this suite; being reported is `unreproduced(by:)`'s job,
        // and it does that by reflection rather than by naming the field.
        let expected = Set(lossIfPresentProperties.map(ClipboardSnapshot.Representation.lossIfPresent))
        #expect(fixture.unreproduced(by: SavePayload(text: "notes about that photo")) == expected)
    }

    @Test("a property the predicate never names is reported when classified .lossIfPresent")
    func aPropertyThePredicateNeverNamesIsStillReported() {
        // The part the test above cannot reach while the type has exactly one `.lossIfPresent` field:
        // with one real field, "honours the bucket" and "reports refusedImagePixels" are the same
        // assertion, and a hard-coded `refusedImagePixels != nil` satisfies both. So here the
        // classification is injected and `changeCount` stands in for #71's file reference — a
        // property `unreproduced(by:)` has never heard of, in that bucket. A body that names fields
        // instead of reading the dictionary fails this test today, with no new field to add.
        var classes = ClipboardSnapshot.storedPropertyClasses
        classes["changeCount"] = .lossIfPresent
        let origin = ClipboardSnapshot(plainText: "hello", richRTFD: nil, changeCount: 41)
        let payload = SavePayload(document: PasteDocument(origin: origin))
        #expect(origin.unreproduced(by: payload, classifiedBy: classes)
                == [.lossIfPresent("changeCount")])
        #expect(origin.unreproduced(by: payload).isEmpty,
                "and under the real classification changeCount is still metadata")
    }

    @Test("a nil .lossIfPresent property is not reported")
    func absentPropertiesAreNotLosses() {
        // The other direction, and the reason presence is an Optional unwrap rather than a
        // description compare: a snapshot with nothing refused has to stay saveable.
        let origin = ClipboardSnapshot(plainText: "hello", richRTFD: nil)
        #expect(origin.unreproduced(by: SavePayload(text: "hello")).isEmpty)
    }
}
