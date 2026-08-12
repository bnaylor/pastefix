import Foundation

public struct JSTransformer: Transformer {
    public let id: String
    public let name: String
    public let requiresRichInput = false
    public let source: TransformerSource
    private let url: URL
    private let timeout: TimeInterval

    public init(url: URL, metadata: ScriptMetadata, timeout: TimeInterval) {
        self.url = url
        self.timeout = timeout
        self.id = "js:" + url.lastPathComponent
        self.name = metadata.name ?? url.deletingPathExtension().lastPathComponent
        self.source = .javascript(url)
    }

    public func apply(_ input: TransformInput) async throws -> String {
        let src = try String(contentsOf: url, encoding: .utf8)
        return try await JSRunner.run(source: src, input: input.text, timeout: timeout)
    }
}
