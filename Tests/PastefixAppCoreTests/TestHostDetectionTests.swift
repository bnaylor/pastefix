import Testing
@testable import PastefixAppCore

/// #68: when Pastefix.app is launched as a test host it must start nothing — no hotkeys, no
/// clipboard monitor, no real history, no Sparkle. That rests entirely on this function, so a
/// typo in the variable name would make the guard silently fail open. These pin it.
@Suite("TestHostDetection")
struct TestHostDetectionTests {
    @Test("any one of the four XCTest variables means hosting tests", arguments: TestHostDetection.environmentKeys)
    func anyXCTestVariable(key: String) {
        #expect(TestHostDetection.isHostingTests(environment: [key: "/tmp/x"]))
    }

    @Test("an ordinary launch, including Xcode's Debug run, is not hosting tests")
    func ordinaryLaunch() {
        #expect(!TestHostDetection.isHostingTests(environment: [:]))
        #expect(!TestHostDetection.isHostingTests(environment: ["__XCODE_BUILT_PRODUCTS_DIR_PATHS": "/x", "DYLD_FRAMEWORK_PATH": "/x"]))
    }

    @Test("an empty value is not a test host")
    func emptyValue() {
        for key in TestHostDetection.environmentKeys {
            #expect(!TestHostDetection.isHostingTests(environment: [key: ""]))
        }
    }
}
