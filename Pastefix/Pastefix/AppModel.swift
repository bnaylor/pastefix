import Foundation
import AppKit
import Combine
import PastefixCore
import PastefixAppCore

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var document: PasteDocument?
    @Published var errorMessage: String?

    let transformers: [any Transformer]
    var onEndSession: (() -> Void)?

    init() {
        let scriptsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/pastefix/scripts", isDirectory: true)
        let registry = TransformerRegistry(config: RegistryConfig(scriptsDirectory: scriptsDir))
        transformers = registry.load()
    }

    func summon() {
        errorMessage = nil
        document = PasteDocument(origin: ClipboardBridge.snapshot())
    }

    func enabledTransformers() -> [any Transformer] {
        guard let document else { return [] }
        return transformers.filter { TransformCoordinator.isEnabled($0, for: document) }
    }

    func apply(_ transformer: any Transformer) {
        guard let current = document else { return }
        Task {
            let (updated, outcome) = await TransformCoordinator.apply(transformer, to: current)
            self.document = updated
            switch outcome {
            case .applied, .unchanged: self.errorMessage = nil
            case .failed(let message): self.errorMessage = message
            }
        }
    }

    func setWorking(_ text: String) {
        guard var doc = document else { return }
        doc.setWorking(text)
        document = doc
    }

    func undo() { guard var doc = document else { return }; doc.undo(); document = doc }
    func redo() { guard var doc = document else { return }; doc.redo(); document = doc }

    func refresh() {
        guard var doc = document else { return }
        doc.refresh(origin: ClipboardBridge.snapshot())
        document = doc
        errorMessage = nil
    }

    func save() {
        if let text = document?.working { ClipboardBridge.writePlain(text) }
        endSession()
    }

    func cancel() { endSession() }

    private func endSession() {
        document = nil
        errorMessage = nil
        onEndSession?()
    }
}
