import SwiftUI
import PastefixCore
import PastefixAppCore

struct PanelView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: SettingsStore
    @State private var isPaletteOpen = false
    @State private var isHistoryOpen = false
    @FocusState private var editorFocused: Bool

    private var workingBinding: Binding<String> {
        Binding(
            get: { model.document?.working ?? "" },
            set: { model.setWorking($0) }
        )
    }

    var body: some View {
        // The palette is a sibling of the whole panel, not of the editor: its backdrop has to
        // dim and swallow clicks for the toolbar, sidebar and action bar too, or a "modal"
        // overlay would leave live controls showing through around its edges.
        ZStack {
            VStack(spacing: 0) {
                toolbar
                Divider()
                HStack(spacing: 0) {
                    VStack(spacing: 0) {
                        TextEditor(text: workingBinding)
                            .font(.system(.body, design: .monospaced))
                            .padding(8)
                            .disabled(model.isApplying)
                            .focused($editorFocused)
                        if let error = model.errorMessage {
                            errorBanner(error)
                        }
                    }
                    if settings.showSidebar {
                        Divider()
                        SidebarView(model: model)
                    }
                }
                Divider()
                actionBar
            }
            // The two overlays are mutually exclusive: one backdrop, one focused field, one
            // owner for Esc. Opening either closes the other.
            if isPaletteOpen {
                CommandPaletteView(model: model, onClose: closePalette)
                    .transition(.opacity)
                    // A sidebar-started apply must not leave a live palette behind.
                    .disabled(model.isApplying)
            } else if isHistoryOpen {
                HistoryOverlayView(model: model, onClose: closeHistory)
                    .transition(.opacity)
                    .disabled(model.isApplying)
            }
        }
        .frame(
            minWidth: settings.showSidebar
                ? PanelMetrics.minContentWidthWithSidebar
                : PanelMetrics.minContentWidth,
            minHeight: PanelMetrics.minContentHeight
        )
        .animation(.easeInOut(duration: 0.15), value: settings.showSidebar)
        .animation(.easeInOut(duration: 0.1), value: isPaletteOpen)
        .animation(.easeInOut(duration: 0.1), value: isHistoryOpen)
        // A new session always starts with both overlays closed.
        .onChange(of: model.document == nil) { _, ended in
            if ended { isPaletteOpen = false; isHistoryOpen = false }
        }
        // Hand focus back to the editor once a transform finishes, unless the user has an
        // overlay open and is picking the next thing.
        .onChange(of: model.isApplying) { _, applying in
            if !applying && !isPaletteOpen && !isHistoryOpen { editorFocused = true }
        }
        // ⌘⇧V summons straight into the history overlay; the flag is a one-shot request,
        // so reset it here or the next summon would reopen the overlay by itself.
        .onChange(of: model.historyOverlayRequested) { _, requested in
            guard requested else { return }
            isPaletteOpen = false
            isHistoryOpen = true
            model.historyOverlayRequested = false
        }
    }

    private var toolbar: some View {
        HStack {
            Button("Undo") { model.undo() }
                .disabled(model.isApplying || model.document?.canUndo != true)
            Button("Redo") { model.redo() }
                .disabled(model.isApplying || model.document?.canRedo != true)
            Button("Refresh") { model.refresh() }
                .disabled(model.isApplying)
            Spacer()
            Button { toggleHistory() } label: {
                Image(systemName: "clock.arrow.circlepath")
            }
            .help("Clipboard History (⌘Y)")
            .accessibilityLabel("Clipboard History")
            // Same one-binding rule as ⌘K below: while the history overlay is open its own
            // hidden button owns ⌘Y (to close), and while the palette is open nothing does.
            .keyboardShortcut(isPaletteOpen || isHistoryOpen ? nil : KeyboardShortcut("y", modifiers: .command))
            .disabled(model.isApplying)
            Button { settings.showSidebar.toggle() } label: {
                Image(systemName: "sidebar.right")
            }
            .help(settings.showSidebar ? "Hide Transforms Sidebar (⌘⇧L)" : "Show Transforms Sidebar (⌘⇧L)")
            .accessibilityLabel(settings.showSidebar ? "Hide Transforms Sidebar" : "Show Transforms Sidebar")
            .keyboardShortcut("l", modifiers: [.command, .shift])
            // Cancel stays enabled during a slow transform, and owns Esc outright: one key with
            // two meanings, resolved here rather than by attaching and detaching the binding.
            // Esc with an overlay open closes that overlay; Esc with both closed cancels the
            // panel. Keeping the shortcut permanently attached means there is never a frame in
            // which nothing claims Esc.
            Button("Cancel") { escape() }
                .keyboardShortcut(.cancelAction)
            Button("Save") { model.save() }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(model.isApplying)
        }
        .padding(8)
    }

    private var actionBar: some View {
        HStack(spacing: 12) {
            Button { togglePalette() } label: {
                HStack {
                    Image(systemName: "magnifyingglass")
                    Text("Transform…")
                    Spacer()
                    Text("⌘K")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // Only one ⌘K can exist at a time: while the palette is open this button is still
            // in the hierarchy (just under the backdrop), and the palette's own hidden button
            // takes over the shortcut to close it. Two live bindings would be ambiguous.
            .keyboardShortcut(isPaletteOpen || isHistoryOpen ? nil : KeyboardShortcut("k", modifiers: .command))
            .disabled(model.isApplying)
            .accessibilityLabel("Find a transform")
            if let color = model.detectedColor {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color(.sRGB, red: color.red, green: color.green, blue: color.blue, opacity: color.alpha))
                    .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(.secondary.opacity(0.4), lineWidth: 0.5))
                    .frame(width: 14, height: 14)
                    .accessibilityLabel("Detected color \(color.cssHex)")
            }
            if let summary = model.detectedSummary {
                Text("Detected: \(summary)")
                    .font(.caption)
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Detected content: \(summary)")
            }
            if model.isApplying {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Applying transform")
            }
        }
        .padding(8)
    }

    private func togglePalette() {
        if isPaletteOpen { closePalette() } else { isHistoryOpen = false; isPaletteOpen = true }
    }

    private func toggleHistory() {
        if isHistoryOpen { closeHistory() } else { isPaletteOpen = false; isHistoryOpen = true }
    }

    /// Esc: close whichever overlay is open, otherwise end the session.
    private func escape() {
        if isPaletteOpen { closePalette() } else if isHistoryOpen { closeHistory() } else { model.cancel() }
    }

    private func closePalette() {
        isPaletteOpen = false
        editorFocused = true
    }

    private func closeHistory() {
        isHistoryOpen = false
        editorFocused = true
    }

    private func errorBanner(_ text: String) -> some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(text).lineLimit(2)
            Spacer()
        }
        .font(.callout)
        .foregroundStyle(.white)
        .padding(8)
        .background(Color.red.opacity(0.85))
    }
}
