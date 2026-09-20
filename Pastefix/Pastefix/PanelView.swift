import SwiftUI
import PastefixCore
import PastefixAppCore

struct PanelView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: SettingsStore
    @State private var isPaletteOpen = false
    @FocusState private var editorFocused: Bool

    private var workingBinding: Binding<String> {
        Binding(
            get: { model.document?.working ?? "" },
            set: { model.setWorking($0) }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            HStack(spacing: 0) {
                ZStack {
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
                    if isPaletteOpen {
                        CommandPaletteView(model: model, onClose: closePalette)
                            .transition(.opacity)
                            // A sidebar-started apply must not leave a live palette behind.
                            .disabled(model.isApplying)
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
        .frame(minWidth: settings.showSidebar ? 780 : 560, minHeight: 380)
        .animation(.easeInOut(duration: 0.15), value: settings.showSidebar)
        .animation(.easeInOut(duration: 0.1), value: isPaletteOpen)
        // A new session always starts with the palette closed.
        .onChange(of: model.document == nil) { _, ended in
            if ended { isPaletteOpen = false }
        }
        // Hand focus back to the editor once a transform finishes, unless the user has
        // the palette open and is picking the next one.
        .onChange(of: model.isApplying) { _, applying in
            if !applying && !isPaletteOpen { editorFocused = true }
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
            Button { settings.showSidebar.toggle() } label: {
                Image(systemName: "sidebar.right")
            }
            .help(settings.showSidebar ? "Hide Transforms Sidebar (⌘⇧L)" : "Show Transforms Sidebar (⌘⇧L)")
            .accessibilityLabel(settings.showSidebar ? "Hide Transforms Sidebar" : "Show Transforms Sidebar")
            .keyboardShortcut("l", modifiers: [.command, .shift])
            // Cancel stays enabled during a slow transform. Its Esc binding is detached while
            // the palette is open so a first Esc closes the palette, not the panel.
            Button("Cancel") { model.cancel() }
                .keyboardShortcut(isPaletteOpen ? nil : .cancelAction)
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
            .keyboardShortcut("k", modifiers: .command)
            .disabled(model.isApplying)
            .accessibilityLabel("Find a transform")
            if let summary = model.detectedSummary {
                Text("Detected: \(summary)")
                    .font(.caption)
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
        if isPaletteOpen { closePalette() } else { isPaletteOpen = true }
    }

    private func closePalette() {
        isPaletteOpen = false
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
