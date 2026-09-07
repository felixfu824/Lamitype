import AppKit
import SwiftUI

@MainActor
private final class EvalWindowDelegate: NSObject, NSWindowDelegate {
    let onClose: () -> Void
    let shouldClose: () -> Bool

    init(shouldClose: @escaping () -> Bool, onClose: @escaping () -> Void) {
        self.shouldClose = shouldClose
        self.onClose = onClose
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool { shouldClose() }
    func windowWillClose(_ notification: Notification) { onClose() }
}

@MainActor
enum EvalWindow {
    private static var window: NSPanel?
    private static var windowDelegate: EvalWindowDelegate?
    private static var model: EvalWindowModel?

    static var isPresented: Bool { window != nil }

    /// Reuses the window-close draft guard for application termination. A
    /// canceled quit never reaches `applicationWillTerminate`, so session
    /// entries remain available while the user keeps editing.
    static func confirmApplicationTermination() -> Bool {
        model?.confirmWindowClose() ?? true
    }

    static func present(
        isAppIdle: @escaping () -> Bool,
        requestEvalEnabled: @escaping (Bool) -> Void,
        focusPromptEditor: Bool = false
    ) {
        if let window {
            if focusPromptEditor { model?.showPromptEditor() }
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
        panel.contentMinSize = NSSize(width: 760, height: 520)
        panel.setFrameAutosaveName("EvalModeWindow")
        panel.center()

        let delegate = EvalWindowDelegate(shouldClose: {
            model.confirmWindowClose()
        }) {
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
        if focusPromptEditor { model.showPromptEditor() }
    }
}
