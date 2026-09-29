import AppKit
import SwiftUI

/// Hands the panel's window to `AppModel`, whose undo manager is the one stack for typing and
/// transforms (#103).
///
/// An `NSView` subclass reporting `viewDidMoveToWindow`, not a read in `makeNSView`/`updateNSView`:
/// the window is nil when the view is made, and nothing promises another update once it attaches
/// (the `work` session's spike read a nil window exactly that way).
struct WindowUndoBinding: NSViewRepresentable {
    let model: AppModel

    final class Probe: NSView {
        var onWindow: ((NSWindow) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { onWindow?(window) }
        }
    }

    func makeNSView(context: Context) -> Probe {
        let probe = Probe()
        probe.onWindow = { [weak model] window in
            guard let model, model.panelWindow !== window else { return }
            model.panelWindow = window
        }
        return probe
    }

    func updateNSView(_ probe: Probe, context: Context) {}
}
