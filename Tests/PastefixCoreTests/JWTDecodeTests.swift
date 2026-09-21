import Testing
import Foundation
@testable import PastefixCore

@Suite struct JWTDecodeTests {
    private func b64url(_ json: String) -> String {
        Data(json.utf8).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
    private func token(header: String = #"{"alg":"HS256","typ":"JWT"}"#, payload: String, sig: String = "sig") -> String {
        "\(b64url(header)).\(b64url(payload)).\(sig)"
    }

    @Test func decodesHeaderAndPayloadWithExpiry() async throws {
        let out = try await JWTDecode().apply(.init(text: token(payload: #"{"sub":"42","exp":1600000000}"#)))
        #expect(out.hasPrefix("{\n"))
        #expect(out.contains("\"alg\" : \"HS256\""))
        #expect(out.contains("\"sub\" : \"42\""))
        #expect(out.contains("// exp: 2020-09-13T12:26:40Z (expired)"))
        #expect(out.hasSuffix("// signature not verified"))
    }
    @Test func futureExpiryIsValid() async throws {
        let out = try await JWTDecode().apply(.init(text: token(payload: #"{"exp":4102444800}"#)))   // 2100-01-01
        #expect(out.contains("// exp: 2100-01-01T00:00:00Z (valid)"))
    }
    @Test func noExpiryNoLine() async throws {
        let out = try await JWTDecode().apply(.init(text: token(payload: #"{"sub":"x","iat":1516239022}"#)))
        #expect(!out.contains("// exp"))
        #expect(out.contains("// iat: 2018-01-18T01:30:22Z"))
    }
    @Test func algNoneWithEmptySignature() async throws {
        let out = try await JWTDecode().apply(.init(text: token(header: #"{"alg":"none"}"#, payload: #"{"a":1}"#, sig: "")))
        #expect(out.contains("\"alg\" : \"none\""))
    }
    @Test func splitRejectsNonJWT() {
        #expect(JWTDecoder.split("a.b") == nil)
        #expect(JWTDecoder.split("\(b64url(#"{"x":1}"#)).\(b64url("{}")).s") == nil)   // header lacks alg
        #expect(JWTDecoder.split("not.base64!.x") == nil)
        #expect(JWTDecoder.split(token(payload: "{}")) != nil)
    }
    @Test func invalidThrows() async {
        await #expect(throws: TransformError.invalidInput("Not a decodable JWT")) { _ = try await JWTDecode().apply(.init(text: "hello.world")) }
    }
    @Test func metadata() {
        let t = JWTDecode()
        #expect(t.id == "builtin.jwt.decode"); #expect(t.name == "Decode JWT")
        #expect(t.applicableKinds == [.jwt]); #expect(t.category == TransformCategory.data)
    }
}
