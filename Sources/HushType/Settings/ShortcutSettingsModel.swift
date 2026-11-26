import AppKit
import Combine

/// Shared by cached Settings panes so a General change also refreshes Text.
@MainActor
final class ShortcutSettingsModel: NSObject, ObservableObject {
    static let shared = ShortcutSettingsModel()
    @Published private(set) var bindings: ShortcutBindings
    @Published private(set) var captionAdjustment: ShortcutBindings?
    private let config: AppConfig

    init(config: AppConfig = .shared) {
        self.config = config
        bindings = config.shortcutBindings
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(refresh),
                                               name: .shortcutBindingsDidChange, object: config)
    }

    @objc private func refresh() {
        bindings = config.shortcutBindings
        captionAdjustment = nil
    }

    private weak var settingsWindow: NSWindow?

    func observeSettingsWindow(_ window: NSWindow) {
        NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification, object: settingsWindow)
        settingsWindow = window
        NotificationCenter.default.addObserver(self, selector: #selector(settingsWindowWillClose),
                                               name: NSWindow.willCloseNotification, object: window)
    }

    @objc private func settingsWindowWillClose() { captionAdjustment = nil }

    var unavailableCaptionShortcut: CaptionShortcut? {
        CaptionShortcut.allCases.first {
            ShortcutBindings(dictation: bindings.dictation, liveCaption: $0).hasConflict
        }
    }

    func select(dictation: DictationKey) {
        guard dictation != bindings.dictation else {
            captionAdjustment = nil
            return
        }
        var next = ShortcutBindings(dictation: dictation, liveCaption: bindings.liveCaption)
        let needsAdjustment = next.hasConflict
        if needsAdjustment {
            // Preset order prefers another active shortcut over turning it off.
            next.liveCaption = CaptionShortcut.allCases.first {
                !ShortcutBindings(dictation: dictation, liveCaption: $0).hasConflict
            } ?? .off
        }
        config.shortcutBindings = next
        captionAdjustment = needsAdjustment ? next : nil
    }

    func select(caption: CaptionShortcut) {
        let next = ShortcutBindings(dictation: bindings.dictation, liveCaption: caption)
        guard !next.hasConflict else { return }
        captionAdjustment = nil
        config.shortcutBindings = next
    }

    var canRestoreDefaults: Bool { bindings != .default }

    static func makeRestoreAlert() -> NSAlert {
        let alert = NSAlert()
        alert.messageText = L10n.string("shortcut.restore.title", fallback: "Restore Default Shortcuts?")
        alert.informativeText = L10n.string("shortcut.restore.message", fallback: "This restores the default key and gesture for every action.")
        alert.addButton(withTitle: L10n.string("common.button.cancel", fallback: "Cancel"))
        alert.addButton(withTitle: L10n.string("shortcut.restore.confirm", fallback: "Restore Defaults"))
        return alert
    }

    func restoreDefaults() {
        guard canRestoreDefaults else { return }
        guard Self.makeRestoreAlert().runModal() == .alertSecondButtonReturn else { return }
        captionAdjustment = nil
        config.shortcutBindings = .default
    }
}

extension ShortcutSettingsModel {
    var dictationShortcutMissing: Bool { bindings[.dictate].chord == nil }

    /// Invalid candidates leave the previous assignment in place.
    @discardableResult
    func assign(_ binding: ActionBinding, to action: ShortcutAction) -> String? {
        guard binding.chord?.valid != false, action.gestures.contains(binding.gesture) else {
            return L10n.string("shortcut.recorder.unsupported", fallback: "This shortcut is unsupported.")
        }
        if let other = bindings.conflict(for: action, binding: binding) {
            return L10n.format("shortcut.recorder.duplicate", "Already used by %1$@.", arguments: [other.title])
        }
        if binding.chord?.systemShortcut == true {
            return L10n.string("shortcut.recorder.system", fallback: "This shortcut is used by macOS.")
        }
        var next = bindings
        next[action] = binding
        config.shortcutBindings = next
        return nil
    }

    func clear(_ action: ShortcutAction) {
        var next = bindings
        next[action].chord = nil
        config.shortcutBindings = next
    }

    func reset(_ action: ShortcutAction) -> String? {
        assign(ShortcutBindings.default[action], to: action)
    }
}
