import SwiftUI
import PastefixCore
import PastefixAppCore

struct PanelView: View {
    @ObservedObject var model: AppModel

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
            TextEditor(text: workingBinding)
                .font(.system(.body, design: .monospaced))
                .padding(8)
                .disabled(model.isApplying)
            if let error = model.errorMessage {
                errorBanner(error)
            }
            Divider()
            palette
        }
        .frame(minWidth: 560, minHeight: 380)
    }

    private var toolbar: some View {
        HStack {
            Button("Undo") { model.undo() }
                .disabled(model.document?.canUndo != true)
            Button("Redo") { model.redo() }
                .disabled(model.document?.canRedo != true)
            Button("Refresh") { model.refresh() }
            Spacer()
            Button("Cancel") { model.cancel() }
                .keyboardShortcut(.cancelAction)
            Button("Save") { model.save() }
                .keyboardShortcut("s", modifiers: .command)
        }
        .padding(8)
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

    private var palette: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if let summary = model.detectedSummary {
                    Text("Detected: \(summary)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.trailing, 4)
                        .accessibilityLabel("Detected content: \(summary)")
                }
                ForEach(model.enabledTransformers(), id: \.id) { transformer in
                    Button(transformer.name) { model.apply(transformer) }
                        .buttonStyle(.bordered)
                }
            }
            .padding(8)
        }
        .disabled(model.isApplying)
    }
}
