import SwiftUI
import PastefixCore
import PastefixAppCore

/// A text label being typed (annotate spec): where it goes, in image pixels and in view points.
struct TextDraft: Equatable {
    var point: ImagePoint
    var viewPoint: CGPoint
    var text: String
}

/// What `ImageSessionView` needs to show markup mode instead of the region overlay.
struct MarkupConfig {
    let tool: ImageMark.Tool
    let color: ImageMark.Color
    /// Marks queued but not yet burned in, previewed so a fast stroke is visible at once.
    let pending: [ImageMark]
    let textDraft: Binding<TextDraft?>
    /// False while a transform the user chose runs (`AppModel.isApplyingNonMark`).
    var enabled: Bool = true
    let onMark: (ImageMark) -> Void
}

/// Drawing over the fitted image in markup mode (annotate spec). One `DragGesture(minimumDistance: 0)`;
/// the stroke's points are collected while it runs and handed to `MarkupGeometry` at the end, which
/// returns the mark (or nil for a tap). Its start is `@GestureState`, so a cancelled stroke leaves
/// nothing behind. The text tool opens a `TextDraft` on a click, typed in the strip's field and
/// previewed here; Return there, or a click elsewhere here, finishes it. Never disabled while a mark
/// applies: the model's queue keeps the order.
struct MarkupOverlay: View {
    let pixelSize: (width: Int, height: Int)
    let config: MarkupConfig

    @GestureState private var active = false
    @State private var path: [CGPoint] = []

    var body: some View {
        GeometryReader { geo in
            let frame = CGRect(origin: .zero, size: geo.size)
            let scale = geo.size.width / Double(max(pixelSize.width, 1))   // points per pixel
            ZStack(alignment: .topLeading) {
                Color.clear
                Canvas { context, _ in
                    for mark in config.pending { draw(mark, in: &context, scale: scale) }
                    if !path.isEmpty,
                       let live = MarkupGeometry.mark(tool: config.tool, color: config.color, path: path,
                                                      frame: frame, pixelSize: pixelSize) {
                        draw(live, in: &context, scale: scale)
                    }
                }
                if let draft = config.textDraft.wrappedValue {
                    // The label being typed, live at its spot. It's typed into the strip's field, not
                    // a field here: an AppKit text field inside this view stops SwiftUI delivering the
                    // drag gesture at all (measured), so "click elsewhere to finish" couldn't work.
                    Text(draft.text.isEmpty ? "Type a label…" : draft.text)
                        .font(.system(size: Double(MarkGeometry.fontSize(longerSide: max(pixelSize.width, pixelSize.height))) * scale,
                                      weight: .bold))
                        .foregroundStyle(draft.text.isEmpty ? Color.secondary : swiftUIColor(config.color))
                        .fixedSize()
                        .offset(x: draft.viewPoint.x, y: draft.viewPoint.y)
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .updating($active) { value, state, _ in
                    if !state { state = true; path = [value.startLocation] }
                    path.append(value.location)
                }
                .onEnded { value in
                    defer { path = [] }
                    if config.tool == .text || config.textDraft.wrappedValue != nil {
                        // A click with a draft open finishes it and starts nothing; otherwise the
                        // text tool opens a draft where it was clicked.
                        if config.textDraft.wrappedValue != nil { commitText(); return }
                        if RegionGeometry.isTap(from: value.startLocation, to: value.location) {
                            config.textDraft.wrappedValue = TextDraft(
                                point: MarkupGeometry.pixel(value.startLocation, frame: frame, pixelSize: pixelSize),
                                viewPoint: value.startLocation, text: "")
                        }
                        return
                    }
                    if let mark = MarkupGeometry.mark(tool: config.tool, color: config.color, path: path,
                                                      frame: frame, pixelSize: pixelSize) {
                        config.onMark(mark)
                    }
                })
            .disabled(!config.enabled)
        }
    }

    private func commitText() {
        guard let draft = config.textDraft.wrappedValue else { return }
        config.textDraft.wrappedValue = nil
        let text = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        config.onMark(ImageMark(tool: .text, color: config.color, points: [draft.point], text: text))
    }

    private func swiftUIColor(_ c: ImageMark.Color) -> Color { Color(.sRGB, red: c.rgb.r, green: c.rgb.g, blue: c.rgb.b) }

    /// A preview of `mark` in view points: the same shapes `MarkRenderer` burns in, at display scale.
    private func draw(_ mark: ImageMark, in context: inout GraphicsContext, scale: Double) {
        let longer = max(pixelSize.width, pixelSize.height)
        let stroke = Double(MarkGeometry.strokeWidth(longerSide: longer)) * scale
        func v(_ p: ImagePoint) -> CGPoint { CGPoint(x: Double(p.x) * scale, y: Double(p.y) * scale) }
        let color = swiftUIColor(mark.color)
        let style = StrokeStyle(lineWidth: max(stroke, 1), lineCap: .round, lineJoin: .round)
        switch mark.tool {
        case .box where mark.points.count >= 2:
            let a = v(mark.points[0]), b = v(mark.points[1])
            context.stroke(Path(CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))), with: .color(color), style: style)
        case .highlight where mark.points.count >= 2:
            let a = v(mark.points[0]), b = v(mark.points[1])
            context.blendMode = .multiply
            context.fill(Path(CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))),
                         with: .color(Color(.sRGB, red: 1, green: 0.9, blue: 0, opacity: 0.45)))
            context.blendMode = .normal
        case .arrow where mark.points.count >= 2:
            let tail = v(mark.points[0]), tip = v(mark.points[1])
            let arrowStroke = max(Double(MarkGeometry.arrowStrokeWidth(longerSide: longer)) * scale, 1)
            let head = MarkGeometry.arrowHead(tail: tail, tip: tip, stroke: arrowStroke)
            context.stroke(Path { $0.move(to: tail); $0.addLine(to: head.base) }, with: .color(color),
                           style: StrokeStyle(lineWidth: arrowStroke, lineCap: .round, lineJoin: .round))
            context.fill(Path { $0.move(to: head.tip); $0.addLine(to: head.left); $0.addLine(to: head.right); $0.closeSubpath() }, with: .color(color))
        case .freehand:
            let pts = MarkGeometry.thinned(mark.points.map(v), minDistance: 1)
            context.stroke(Path(MarkGeometry.smoothPath(pts)), with: .color(color), style: style)
        case .text:
            if let text = mark.text, let p = mark.points.first {
                let size = Double(MarkGeometry.fontSize(longerSide: longer)) * scale
                context.draw(Text(text).font(.system(size: size, weight: .bold)).foregroundStyle(color), at: v(p), anchor: .topLeading)
            }
        default:
            break
        }
    }
}
