import SwiftUI
import PastefixCore

/// The markup tool strip (annotate spec): the five tools, five colours, and Done; with the Text tool,
/// a second row for the label size and the Label field. Shown above the image only in markup mode.
/// Two rows and compact tool buttons so it fits the panel: in one row it wanted 597–655 pt with the
/// Text tool against a 560 pt minimum main area, squeezing Done (owner, GUI pass; `theStripFitsThePanel`).
struct MarkupStrip: View {
    @Binding var tool: ImageMark.Tool
    @Binding var color: ImageMark.Color
    /// The label being typed, if any: its field lives here, previewed on the image.
    @Binding var textDraft: TextDraft?
    /// The label size (#135), shown only for the Text tool.
    @Binding var textSize: ImageMark.TextSize
    let commitText: () -> Void
    let done: () -> Void
    @FocusState private var labelFocused: Bool

    private func symbol(_ t: ImageMark.Tool) -> String {
        switch t {
        case .box: "rectangle"
        case .arrow: "arrow.up.right"
        case .text: "textformat"
        case .highlight: "highlighter"
        case .freehand: "scribble"
        }
    }

    static func showsTextSize(_ tool: ImageMark.Tool) -> Bool { tool == .text }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                ForEach(ImageMark.Tool.allCases, id: \.self) { t in
                    Button { tool = t } label: {
                        Image(systemName: symbol(t)).frame(width: 24, height: 20).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .background(RoundedRectangle(cornerRadius: 5).fill(tool == t ? Color.accentColor.opacity(0.25) : .clear))
                    .overlay(RoundedRectangle(cornerRadius: 5)
                        .stroke(tool == t ? Color.accentColor : Color.secondary.opacity(0.35), lineWidth: 1))
                    .help(t.name)
                    .accessibilityLabel(t.name)
                    .accessibilityAddTraits(tool == t ? .isSelected : [])
                }
                Divider().frame(height: 16).padding(.horizontal, 4)
                ForEach(ImageMark.Color.allCases, id: \.self) { c in
                    Button { color = c } label: {
                        Circle().fill(Color(.sRGB, red: c.rgb.r, green: c.rgb.g, blue: c.rgb.b))
                            .overlay(Circle().stroke(Color.primary.opacity(color == c ? 0.9 : 0.25), lineWidth: color == c ? 2 : 1))
                            .frame(width: 14, height: 14)
                            .padding(2)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(c.rawValue.capitalized)
                    .accessibilityLabel("\(c.rawValue.capitalized) colour")
                    .accessibilityAddTraits(color == c ? .isSelected : [])
                }
                Spacer(minLength: 8)
                Button("Done", action: done)
            }
            if Self.showsTextSize(tool) {
                HStack(spacing: 8) {
                    Picker("Label size", selection: $textSize) {
                        ForEach(ImageMark.TextSize.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .help("Label size")
                    .accessibilityLabel("Label size")
                    if textDraft != nil {
                        TextField("Label", text: Binding(get: { textDraft?.text ?? "" }, set: { textDraft?.text = $0 }))
                            .textFieldStyle(.roundedBorder)
                            .frame(minWidth: 120, idealWidth: 220, maxWidth: 260)
                            .focused($labelFocused)
                            .onSubmit(commitText)
                            // Esc in the focused field: the field editor takes the key before the panel's Cancel
                            // shortcut sees it, so the field discards the label itself (annotate final review I3, measured).
                            .onExitCommand { textDraft = nil }
                            // A turn later: set in onAppear itself, the field isn't in the window yet and the
                            // focus request is dropped (measured: first responder stayed the window).
                            .onAppear { DispatchQueue.main.async { labelFocused = true } }
                            .accessibilityLabel("Label text")
                    } else {
                        Text("Click the picture where the label goes.").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}
