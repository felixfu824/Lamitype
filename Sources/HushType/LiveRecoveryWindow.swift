import AppKit
import SwiftUI

@MainActor
final class LiveRecoveryWindow: NSWindowController, NSWindowDelegate, ObservableObject {
    @Published var text = ""
    @Published var message = ""
    @Published var hasAudio = false
    @Published var working = false
    var onRetry: (() -> Void)?
    var onSave: (() -> Void)?
    var onDiscard: (() -> Void)?

    init() {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 260),
                            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.title = L10n.string("live.result.title", fallback: "Local Live Dictation")
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        super.init(window: panel)
        panel.contentView = NSHostingView(rootView: LiveRecoveryView(model: self))
        panel.delegate = self
        panel.center()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func present(text: String = "", message: String, hasAudio: Bool) {
        self.text = text; self.message = message; self.hasAudio = hasAudio; working = false
        window?.makeKeyAndOrderFront(nil)
    }
    /// Completed text is retained for explicit Last Live Result access.
    /// Also closes a previously visible failure/retry panel without focusing
    /// the app or opening another window after completion.
    func storeResult(text: String, message: String) {
        self.text = text; self.message = message
        hasAudio = false; working = false
        window?.orderOut(nil)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if hasAudio { onDiscard?() }
        return true
    }
    func discard() { onDiscard?(); text = ""; window?.orderOut(nil) }
    func copy() {
        guard !SecureInputProbe.isActive() else { discard(); return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if pasteboard.setString(text, forType: .string) { window?.orderOut(nil) }
        else { message = L10n.string("live.result.copy_failed", fallback: "Could not copy. Your text is still available here.") }
    }
}

private struct LiveRecoveryView: View {
    @ObservedObject var model: LiveRecoveryWindow
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.message).font(.headline).fixedSize(horizontal: false, vertical: true)
            if model.hasAudio {
                Text(L10n.string("live.recovery.retention", fallback: "The recording is kept in memory until discarded or Lamitype quits."))
                    .foregroundStyle(.secondary).font(.callout)
            } else {
                ScrollView { Text(model.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    .frame(minHeight: 80, maxHeight: 180)
            }
            HStack {
                Button(L10n.string("live.action.discard", fallback: "Discard")) { model.discard() }.keyboardShortcut(.cancelAction).accessibilityIdentifier("local-live-discard")
                Spacer()
                if model.hasAudio {
                    Button(L10n.string("live.action.save", fallback: "Save Audio…")) { model.onSave?() }.disabled(model.working).accessibilityIdentifier("local-live-save")
                    Button(L10n.string("live.action.retry", fallback: "Retry locally")) { model.onRetry?() }
                        .disabled(model.working).accessibilityIdentifier("local-live-retry")
                } else {
                    Button(L10n.string("common.button.copy", fallback: "Copy")) { model.copy() }.keyboardShortcut(.defaultAction).accessibilityIdentifier("local-live-copy")
                }
            }
        }.padding(20).frame(width: 420)
    }
}
