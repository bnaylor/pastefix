import SwiftUI
import PastefixCore
import PastefixAppCore

/// The region selection over the fitted image (crop spec). Placed as an `.overlay` on the image
/// after `.resizable().scaledToFit()`, so its geometry *is* the fitted image rect: no letterbox
/// offset. One `DragGesture(minimumDistance: 0)`, classified on end: under 3 pt is a tap (outside
/// the region clears it); otherwise new, move or resize by `RegionGeometry.hit`. Drawn Preview-style
/// so it reads on dark, light and blue screenshots.
struct ImageRegionOverlay: View {
    @Binding var region: ImageRegion?
    let pixelSize: (width: Int, height: Int)
    let enabled: Bool

    @State private var dragHit: RegionHit?
    @State private var dragOriginal: CGRect?

    var body: some View {
        GeometryReader { geo in
            let frame = CGRect(origin: .zero, size: geo.size)
            let rect = region?.viewRect(imageFrame: frame, pixelSize: pixelSize)
            ZStack(alignment: .topLeading) {
                if let rect {
                    // Dimming outside the region, about 50%.
                    Path { p in p.addRect(frame); p.addRect(rect) }
                        .fill(Color.black.opacity(0.5), style: FillStyle(eoFill: true))
                    // Two-tone outline: white over a black hairline.
                    Rectangle().path(in: rect).stroke(Color.black, lineWidth: 2)
                    Rectangle().path(in: rect.insetBy(dx: 0.5, dy: 0.5)).stroke(Color.white, lineWidth: 1)
                    ForEach(RegionGeometry.handlePoints(rect), id: \.0) { _, point in
                        Rectangle()
                            .fill(Color.white)
                            .overlay(Rectangle().stroke(Color.black.opacity(0.8), lineWidth: 1))
                            .frame(width: 7, height: 7)
                            .shadow(color: .black.opacity(0.4), radius: 1)
                            .position(point)
                    }
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if dragHit == nil {
                        dragHit = RegionGeometry.hit(value.startLocation, selection: rect)
                        dragOriginal = rect
                    }
                    guard let hit = dragHit, !RegionGeometry.isTap(from: value.startLocation, to: value.location) else { return }
                    let next = RegionGeometry.dragged(hit, from: value.startLocation, to: value.location, original: dragOriginal, bounds: frame)
                    if let r = ImageRegion.from(viewRect: next, imageFrame: frame, pixelSize: pixelSize) { region = r }
                }
                .onEnded { value in
                    // A tap outside the region clears it; a tap inside leaves it.
                    if RegionGeometry.isTap(from: value.startLocation, to: value.location), dragHit == .new { region = nil }
                    dragHit = nil
                    dragOriginal = nil
                })
            .disabled(!enabled)
        }
    }
}
