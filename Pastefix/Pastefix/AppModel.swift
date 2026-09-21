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

    /// Set by the ⌘⇧V hotkey; PanelView opens the history overlay and resets it.
    @Published var historyOverlayRequested = false

    let settings: SettingsStore
    let history: HistoryStore
    var onEndSession: (() -> Void)?

    /// The app to paste a snippet into once Pastefix hides, supplied by the delegate from
    /// `FrontmostAppTracker`. A closure rather than a stored app so the value is read at paste
    /// time, not at whatever moment the model happened to be wired up.
    var previousAppProvider: () -> NSRunningApplication? = { nil }

    /// Bumped on every summon and every dismissal. An in-flight transform captures the
    /// value it started under, so a result from a session the user has since dismissed
    /// can't land in a newer one — `document != nil` alone doesn't catch a dismiss-then-
    /// re-summon inside the apply window.
    ///
    /// Published because it is also the panel's reset signal: it moves monotonically, so a
    /// `PanelView` that never got to render between a session ending and the next one starting
    /// still sees the change (a derived `document == nil` reads the same on both sides of a
    /// skipped render and the overlay stays open over a fresh session).
    @Published private(set) var sessionGeneration = 0

    init(settings: SettingsStore, history: HistoryStore) {
        self.settings = settings
        self.history = history
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
        guard let doc = document else { endSession(); return }
        if doc.outputMode == .renderedMarkdown {
            do {
                let rich = try RichOutputRenderer.render(markdown: doc.working)
                ClipboardBridge.writeRich(text: doc.working, html: rich.html, rtf: rich.rtf)
            } catch {
                // Keep the session open and the mode armed: the user can read the error and
                // either fix the Markdown or disarm the badge and save plain text instead.
                errorMessage = "Couldn't render Markdown: \(error.localizedDescription)"
                return
            }
        } else {
            ClipboardBridge.writePlain(doc.working)
        }
        endSession()
    }

    /// True while Save would write HTML + RTF; drives the action-bar badge and the Save tooltip.
    var isRichOutputArmed: Bool { document?.outputMode == .renderedMarkdown }

    /// Back to a plain-text Save. `document` is `private(set)`, so mutate a copy and reassign
    /// to publish the change.
    func disarmRichOutput() {
        guard var doc = document else { return }
        doc.outputMode = .plain
        document = doc
    }

    func cancel() { endSession() }

    /// Starts a new session from a history item (rich data attached when present).
    func load(_ item: HistoryItem) {
        // An image-only item has no text to edit; opening a session would silently discard the
        // image. Put it straight back on the clipboard instead of opening an empty editor.
        guard item.hasText else { copyBack(item); return }
        errorMessage = nil
        sessionGeneration &+= 1
        document = PasteDocument(origin: ClipboardSnapshot(plainText: item.plainText ?? "", richRTFD: history.richRTFD(for: item)))
    }

    /// Puts the whole item back on the clipboard and ends the session.
    func copyBack(_ item: HistoryItem) {
        ClipboardBridge.write(text: item.plainText, richRTFD: history.richRTFD(for: item), imagePNG: history.imagePNG(for: item))
        endSession()
    }

    // MARK: Pinned snippets

    /// Pin or unpin from a browse surface (the history overlay). The store publishes the
    /// change, so the overlay's items observer re-ranks and the row re-renders.
    func togglePin(_ item: HistoryItem) {
        item.pinned ? history.unpin(item.id) : history.pin(item.id)
    }

    /// Why a pin didn't happen. The store returns one nil for two very different refusals, and
    /// the popover has to tell the user which: "Nothing to pin" is a state they can see, "Too
    /// large" is one they can't.
    enum PinOutcome: Equatable { case pinned, nothingToPin, tooLarge }

    /// Pins the editor buffer, carrying the origin's rich data so a pinned snippet pastes back
    /// with its formatting.
    @discardableResult
    func pinCurrentBuffer(title: String?) -> PinOutcome {
        // No session at all, or a buffer that is empty or all whitespace: `HistoryStore.record`
        // refuses both, so rule them out here rather than reporting them as a size problem.
        guard let doc = document,
              !doc.working.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .nothingToPin }
        return history.pinText(doc.working, richRTFD: doc.origin.richRTFD, title: title) != nil
            ? .pinned : .tooLarge
    }

    /// Copies the item, pastes it into the app the user came from, and hides the panel.
    ///
    /// Both the target read and the paste happen *before* `endSession()`, and the order is
    /// load-bearing rather than tidy. `endSession()` hides the panel synchronously, so afterwards
    /// the provider would report whatever the window server promoted in our place, and — the part
    /// that actually breaks — `SnippetPaster` would be asking for cooperative activation as a
    /// background agent that no longer owns it, which macOS 14+ is entitled to refuse. Hiding
    /// after is safe: `paste` only requests activation and schedules the ⌘V, which re-checks the
    /// frontmost app before it fires.
    ///
    /// The `.copiedOnly` outcome is deliberately ignored — without Accessibility the snippet is
    /// still on the clipboard, which is a silent fallback by design; Settings shows the permission
    /// state rather than interrupting the paste. `onGaveUp` is different, and gets the same beep
    /// `SnippetHotkeys.fire` uses: a chain that expires after `paste` already predicted `.pasted`
    /// has closed the panel and pasted nothing, with nothing left on screen to say so. ⇧↵ is in
    /// fact the likelier of the two paths to expire — shift is itself a blocking modifier, so the
    /// chain cannot post until the user lets go of the very key they pressed.
    func pasteIntoPreviousApp(_ item: HistoryItem) {
        // Nothing to paste as text (an image-only row): behave exactly like ⌘↵. Writing an empty
        // pasteboard would destroy whatever the user had copied, and the ⌘V that followed would
        // replace the target's selection with nothing — a silent delete they never asked for.
        // `copyBack` writes the image and ends the session.
        guard item.hasText, let text = item.plainText else { copyBack(item); return }
        let rich = history.richRTFD(for: item)
        _ = SnippetPaster.paste(text: text, richRTFD: rich, into: previousAppProvider(),
                                onGaveUp: { NSSound.beep() })
        endSession()
    }

    private func endSession() {
        document = nil
        errorMessage = nil
        isApplying = false
        sessionGeneration &+= 1
        onEndSession?()
    }
}
