import Foundation
import AppKit
import Combine
import PastefixCore
import PastefixAppCore

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var document: PasteDocument?
    @Published var errorMessage: String?
    @Published private(set) var isApplying = false
    @Published private(set) var transformers: [any Transformer] = []
    @Published private(set) var allTransformers: [any Transformer] = []

    let settings: SettingsStore
    var onEndSession: (() -> Void)?

    /// Bumped on every summon and every dismissal. An in-flight transform captures the
    /// value it started under, so a result from a session the user has since dismissed
    /// can't land in a newer one — `document != nil` alone doesn't catch a dismiss-then-
    /// re-summon inside the apply window.
    private var sessionGeneration = 0

    init(settings: SettingsStore) {
        self.settings = settings
        reload()
    }

    /// Rebuild the transformer list from current settings (scripts dir + wrap
    /// width) and apply the user's enable/reorder overrides. Safe to call any
    /// time (e.g. on a script-directory change or a settings edit).
    func reload() {
        let config = RegistryConfig(
            scriptsDirectory: settings.scriptsDirectoryURL,
            wrapWidth: settings.wrapWidth
        )
        let loaded = TransformerRegistry(config: config).load()
        // Unfiltered (for the Settings list): order applied, nothing removed.
        allTransformers = TransformOverrides.apply(to: loaded, enabled: [:], order: settings.transformOrder)
        // Filtered + ordered (for the palette).
        transformers = TransformOverrides.apply(
            to: loaded,
            enabled: settings.transformEnabled,
            order: settings.transformOrder
        )
    }

    func summon() {
        errorMessage = nil
        sessionGeneration &+= 1
        document = PasteDocument(origin: ClipboardBridge.snapshot())
    }

    /// Palette list: enabled transforms in the user's order, with those applicable to the
    /// detected content first. Settings uses `allTransformers`, which detection never reorders.
    func enabledTransformers() -> [any Transformer] {
        guard let document else { return [] }
        let enabled = transformers.filter { TransformCoordinator.isEnabled($0, for: document) }
        return PaletteOrdering.order(enabled, for: document.detectedKinds)
    }

    /// Enabled transforms in the user's order, without detection-based promotion — for browse
    /// surfaces (the sidebar) that should not reshuffle with the clipboard.
    func browsableTransformers() -> [any Transformer] {
        guard let document else { return [] }
        return transformers.filter { TransformCoordinator.isEnabled($0, for: document) }
    }

    /// "URL", "URL, JSON", or nil when nothing was detected.
    var detectedSummary: String? {
        guard let kinds = document?.detectedKinds, !kinds.isEmpty else { return nil }
        return ContentKind.allCases.filter(kinds.contains).map(\.displayName).joined(separator: ", ")
    }

    /// The parsed colour when the buffer is a colour literal; drives the action-bar swatch.
    /// This re-parses live while `detectedKinds` stays frozen during a manual edit, so the swatch
    /// can disappear a keystroke before the badge does — intentional: the swatch must never show a
    /// colour the buffer no longer parses as.
    var detectedColor: ColorLiteral? {
        guard let document, document.detectedKinds.contains(.color) else { return nil }
        return ColorLiteral.parse(document.working)
    }

    func apply(_ transformer: any Transformer) {
        guard let current = document, !isApplying else { return }
        isApplying = true
        let generation = sessionGeneration
        Task {
            let (updated, outcome) = await TransformCoordinator.apply(transformer, to: current)
            // The session can end (Save/Cancel/auto-hide) while a slow transform is in
            // flight, and the user can summon a fresh one before it finishes. Drop the
            // result unless we are still in the session that asked for it — and never
            // leave `isApplying` stuck true for the next summon. Clearing it on the stale
            // path is safe: applies are serialised by `isApplying`, and a new session
            // starts with it false.
            guard self.document != nil, self.sessionGeneration == generation else {
                self.isApplying = false
                return
            }
            self.document = updated
            switch outcome {
            case .applied, .unchanged: self.errorMessage = nil
            case .failed(let message): self.errorMessage = message
            }
            self.isApplying = false
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
        isApplying = false
        sessionGeneration &+= 1
        onEndSession?()
    }
}
