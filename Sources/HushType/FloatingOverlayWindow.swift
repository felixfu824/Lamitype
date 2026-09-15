import AppKit
import SwiftUI
import os

private let log = Logger(subsystem: "com.felix.hushtype", category: "overlay")

/// Borderless floating panel that displays the recording/transcribing
/// indicator near the bottom of the screen.
///
/// Window-level notes:
///   - `.screenSaver` is required to render over fullscreen Spaces apps.
///     `.statusBar` only works for windowed apps.
///   - `.fullScreenAuxiliary` collection behavior is required so the panel
///     follows the active fullscreen window into its Space.
///   - `.nonactivatingPanel` + canBecomeKey/Main → false ensures we never
///     steal focus from the user's text input.
final class FloatingOverlayWindow: NSPanel {

    private let stateModel: OverlayStateModel

    init(stateModel: OverlayStateModel) {
        self.stateModel = stateModel
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 280, height: 56),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isOpaque = false
        backgroundColor = .clear
        hasShadow = false  // we draw our own shadow inside the SwiftUI view
        level = .screenSaver
        collectionBehavior = [
            .canJoinAllSpaces,
            .stationary,
            .ignoresCycle,
            .fullScreenAuxiliary,
        ]
        hidesOnDeactivate = false
        isFloatingPanel = true
        isMovable = false
        ignoresMouseEvents = true  // pure indicator, never receives input

        let hostingView = NSHostingView(rootView: FloatingOverlayView(model: stateModel))
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        contentView = hostingView
    }

    // Never become the key/main window — we must not steal focus.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Show the overlay, positioned bottom-centered on the screen with the
    /// active window. Falls back to main screen if no active screen is found.
    func show() {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame

        // Use the SwiftUI view's intrinsic size — fixedSize() in the view
        // means hostingView.fittingSize is the natural pill width.
        // Lay out first: show() is called immediately after a state change, and
        // a notice is both wider and taller than the routine pill.
        contentView?.layoutSubtreeIfNeeded()
        let fittingSize = (contentView as? NSHostingView<FloatingOverlayView>)?.fittingSize
            ?? NSSize(width: 220, height: 56)

        let x = visible.midX - fittingSize.width / 2
        let y = visible.minY + 80
        let frame = NSRect(origin: CGPoint(x: x, y: y), size: fittingSize)
        setFrame(frame, display: false)

        alphaValue = 0
        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.16
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            self.animator().alphaValue = 1
        }
    }

    /// Hide immediately.
    ///
    /// Deliberately synchronous. The old fade-out ordered the panel out from an
    /// animation completion block, which fired even when show() had run in the
    /// meantime, so a stale dismissal could hide a fresh notice or recording
    /// pill. The 0.16 s show fade is retained.
    func hide() {
        alphaValue = 0
        orderOut(nil)
    }
}
