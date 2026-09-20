import Foundation

public struct ShellTransformer: Transformer {
    public let id: String
    public let name: String
    public let requiresRichInput = false
    public let source: TransformerSource
    public let applicableKinds: Set<ContentKind>?
    private let url: URL
    private let timeout: TimeInterval

    public init(url: URL, metadata: ScriptMetadata, timeout: TimeInterval) {
        self.url = url
        self.timeout = timeout
        self.id = "shell:" + url.lastPathComponent
        self.name = metadata.name ?? url.deletingPathExtension().lastPathComponent
        self.source = .shell(url)
        self.applicableKinds = metadata.kinds
    }

    public func apply(_ input: TransformInput) async throws -> String {
        try await ShellRunner.run(scriptURL: url, input: input.text, timeout: timeout)
    }
}
