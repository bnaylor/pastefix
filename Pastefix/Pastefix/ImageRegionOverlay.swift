import SwiftUI
import PastefixCore
import PastefixAppCore

/// The region selection over the fitted image (crop spec). Placed as an `.overlay` on the image
/// after `.resizable().scaledToFit()`, so its geometry *is* the fitted image rect: no letterbox
/// offset. One `DragGesture(minimumDistance: 0)`, its start held in `@GestureState`, classified on end: under 3 pt is a tap (outside
/// the region clears it); otherwise new, move or resize by `RegionGeometry.hit`. Drawn Preview-style
/// so it reads on dark, light and blue screenshots.
struct ImageRegionOverlay: View {
    @Binding var region: ImageRegion?
    let pixelSize: (width: Int, height: Int)
    let enabled: Bool

    /// The drag's classification and the region it started from. `@GestureState`, so SwiftUI resets
    /// it when the gesture ends *or is cancelled* (the panel losing key, `.disabled` flipping as a
    /// transform starts); as `@State` a cancelled drag's hit replayed on the next one.
    @GestureState private var drag: DragStart?
    private struct DragStart { let hit: RegionHit; let original: ImageRegion? }

    var body: some View {
        GeometryReader { geo in
            let frame = CGRect(origin: .zero, size: geo.size)
            let rect = region?.viewRect(imageFrame: frame, pixelSize: pixelSize)
            ZStack(alignment: .topLeading) {
                // Fills the image, so there is something to press before any region exists: an
                // empty ZStack is 0×0 and its content shape covers nothing (final review C1).
                Color.clear
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
                .updating($drag) { value, state, _ in
                    if state == nil {
                        state = DragStart(hit: RegionGeometry.hit(value.startLocation, selection: rect), original: region)
                    }
                    guard let start = state, !RegionGeometry.isTap(from: value.startLocation, to: value.location) else { return }
                    // In pixels from the original region, so a move or resize never drifts (I1).
                    if let r = RegionGeometry.draggedRegion(start.hit, from: value.startLocation, to: value.location,
                                                            original: start.original, imageFrame: frame, pixelSize: pixelSize) {
                        region = r
                    }
                }
                .onEnded { value in
                    // A tap outside the region clears it; a tap inside leaves it. Classified from the
                    // gesture's own start: a tap hasn't moved the region, so no stored state is needed.
                    if RegionGeometry.isTap(from: value.startLocation, to: value.location),
                       RegionGeometry.hit(value.startLocation, selection: rect) == .new {
                        region = nil
                    }
                })
            .disabled(!enabled)
        }
    }
}
