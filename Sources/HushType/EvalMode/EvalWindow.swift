import AppKit
import SwiftUI

@MainActor
private final class EvalWindowDelegate: NSObject, NSWindowDelegate {
    let onClose: () -> Void

    init(onClose: @escaping () -> Void) {
        self.onClose = onClose
    }

    func windowWillClose(_ notification: Notification) { onClose() }
}

@MainActor
enum EvalWindow {
    private static var window: NSPanel?
    private static var windowDelegate: EvalWindowDelegate?
    private static var model: EvalWindowModel?

    static var isPresented: Bool { window != nil }

    static func present(
        isAppIdle: @escaping () -> Bool,
        requestEvalEnabled: @escaping (Bool) -> Void
    ) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let model = EvalWindowModel(
            isAppIdle: isAppIdle,
            requestEvalEnabled: requestEvalEnabled
        )
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 640),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        panel.title = L10n.string("window.eval.title", fallback: "Eval Mode")
        panel.contentViewController = NSHostingController(rootView: EvalWindowView(model: model))
        panel.isReleasedWhenClosed = false
        panel.level = .normal
        panel.minSize = NSSize(width: 760, height: 520)
        panel.setFrameAutosaveName("EvalModeWindow")
        panel.center()

        let delegate = EvalWindowDelegate {
            model.close()
            DispatchQueue.main.async {
                window = nil
                windowDelegate = nil
                self.model = nil
            }
        }
        panel.delegate = delegate
        windowDelegate = delegate
        window = panel
        self.model = model
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        Task { @MainActor in await model.open() }
    }
}
