import SwiftUI
import PastefixCore

/// The markup tool strip (annotate spec): the five tools, five colours, and Done. Shown above the
/// image only in markup mode.
struct MarkupStrip: View {
    @Binding var tool: ImageMark.Tool
    @Binding var color: ImageMark.Color
    /// The label being typed, if any: its field lives here, previewed on the image.
    @Binding var textDraft: TextDraft?
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

    var body: some View {
        HStack(spacing: 6) {
            ForEach(ImageMark.Tool.allCases, id: \.self) { t in
                Button { tool = t } label: { Image(systemName: symbol(t)).frame(width: 22, height: 18) }
                    .buttonStyle(.bordered)
                    .tint(tool == t ? .accentColor : nil)
                    .help(t.name)
                    .accessibilityLabel(t.name)
                    .accessibilityAddTraits(tool == t ? .isSelected : [])
            }
            Divider().frame(height: 16)
            ForEach(ImageMark.Color.allCases, id: \.self) { c in
                Button { color = c } label: {
                    Circle().fill(Color(.sRGB, red: c.rgb.r, green: c.rgb.g, blue: c.rgb.b))
                        .overlay(Circle().stroke(Color.primary.opacity(color == c ? 0.9 : 0.25), lineWidth: color == c ? 2 : 1))
                        .frame(width: 14, height: 14)
                }
                .buttonStyle(.plain)
                .help(c.rawValue.capitalized)
                .accessibilityLabel("\(c.rawValue.capitalized) colour")
                .accessibilityAddTraits(color == c ? .isSelected : [])
            }
            if textDraft != nil {
                Divider().frame(height: 16)
                TextField("Label", text: Binding(get: { textDraft?.text ?? "" }, set: { textDraft?.text = $0 }))
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 220)
                    .focused($labelFocused)
                    .onSubmit(commitText)
                    .onAppear { labelFocused = true }
                    .accessibilityLabel("Label text")
            }
            Spacer()
            Button("Done", action: done)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}
