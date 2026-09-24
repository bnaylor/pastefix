import Foundation
import PastefixCore

/// What one scan of a buffer found. Pure and synchronous: the scheduler runs `compute` off the
/// main actor and the document installs the result by revision.
public struct DetectionResult: Sendable, Equatable {
    public let kinds: Set<ContentKind>
    public let secretMatches: [SecretMatch]
    /// True when the text was over `SecretDetector.maxBytes`, so `secretMatches` is empty for
    /// want of a scan rather than for want of secrets.
    public let secretScanSkipped: Bool

    public init(kinds: Set<ContentKind>, secretMatches: [SecretMatch], secretScanSkipped: Bool) {
        self.kinds = kinds
        self.secretMatches = secretMatches
        self.secretScanSkipped = secretScanSkipped
    }

    /// The one place the secret scan and content detection are paired, so the scan runs once for
    /// both consumers. Never call on the main actor for session text (Plan 14).
    public static func compute(_ text: String) -> DetectionResult {
        let secrets = SecretDetector.scan(text)
        return DetectionResult(kinds: ContentDetector.detect(text, secrets: secrets),
                               secretMatches: secrets,
                               secretScanSkipped: !SecretDetector.isScannable(text))
    }
}

public enum DetectionState: Sendable, Equatable {
    case pending
    case complete(DetectionResult)
}
