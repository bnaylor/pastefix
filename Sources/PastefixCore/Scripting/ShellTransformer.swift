import Foundation

public struct ShellTransformer: Transformer {
    public let id: String
    public let name: String
    public let requiresRichInput = false
    public let source: TransformerSource
    public let applicableKinds: Set<ContentKind>?
    public let category: String?
    private let url: URL
    private let runnerTimeout: TimeInterval
    // One second of margin so a script that finishes inside its own budget is never reported as
    // timed out by the outer race.
    public var timeout: TimeInterval { runnerTimeout + 1 }

    public init(url: URL, metadata: ScriptMetadata, timeout: TimeInterval) {
        self.url = url
        self.runnerTimeout = timeout
        self.id = "shell:" + url.lastPathComponent
        self.name = metadata.name ?? url.deletingPathExtension().lastPathComponent
        self.source = .shell(url)
        self.applicableKinds = metadata.kinds
        self.category = metadata.category
    }

    public func apply(_ input: TransformInput) async throws -> String {
        try await ShellRunner.run(scriptURL: url, input: input.text, timeout: runnerTimeout)
    }
}
