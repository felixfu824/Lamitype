import AppKit
import SwiftUI

extension Notification.Name {
    static let shortcutRecorderChanged = Notification.Name("LamitypeShortcutRecorderChanged")
}

/// A local monitor sees key equivalents before the Settings window's menu or text controls.
@MainActor
private final class ShortcutRecorder: ObservableObject {
    @Published var action: ShortcutAction?
    @Published var warning: (ShortcutAction, String)?
    private var monitor: Any?
    private var modifierCandidate: ShortcutChord?
    private var pending: ShortcutChord?

    func begin(_ action: ShortcutAction, model: ShortcutSettingsModel) {
        stop()
        self.action = action
        warning = nil
        NotificationCenter.default.post(name: .shortcutRecorderChanged, object: true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
            guard let self, self.action == action else { return event }
            let flags = CGEventFlags(rawValue: UInt64(event.modifierFlags.rawValue))
            let code = event.keyCode
            // F-keys and navigation keys intrinsically carry the function flag.
            let intrinsicFunction = (event.type == .keyDown || event.type == .keyUp) && event.specialKey != nil
            if code == 63 || (flags.contains(.maskSecondaryFn) && !intrinsicFunction) {
                self.stop()
                self.warning = (action, L10n.string("shortcut.recorder.unsupported", fallback: "This shortcut is unsupported."))
                return nil
            }
            if event.type == .keyDown {
                guard !event.isARepeat else { return nil }
                if flags.intersection(ShortcutChord.families).isEmpty {
                    if code == ShortcutChord.escape.keyCode { self.stop(); return nil }
                    if code == ShortcutChord.delete.keyCode || code == 117 { model.clear(action); self.stop(); return nil }
                }
                self.pending = ShortcutChord.recorded(code: code, flags: flags)
            } else if event.type == .keyUp {
                if let chord = self.pending, chord.keyCode == code { self.finish(chord, action, model) }
            } else if self.pending == nil {
                if let modifier = ShortcutChord.modifier(code), flags.rawValue & modifier.bit != 0 {
                    self.modifierCandidate = ShortcutChord.recorded(code: code, flags: flags)
                } else if let candidate = self.modifierCandidate {
                    self.finish(candidate, action, model)
                } else if code == 57 {
                    self.finish(ShortcutChord(keyCode: code), action, model)
                }
            }
            return nil
        }
    }

    private func finish(_ chord: ShortcutChord, _ action: ShortcutAction, _ model: ShortcutSettingsModel) {
        var candidate = model.bindings[action]
        candidate.chord = chord
        stop()
        warning = model.assign(candidate, to: action).map { (action, $0) }
    }

    func stop() {
        guard action != nil else { return }
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        modifierCandidate = nil
        pending = nil
        action = nil
        NotificationCenter.default.post(name: .shortcutRecorderChanged, object: false)
    }
}

@MainActor
struct ShortcutsSection: View {
    @ObservedObject private var model: ShortcutSettingsModel
    @ObservedObject private var textSettings: TextSettingsModel
    @StateObject private var recorder = ShortcutRecorder()

    init(model: ShortcutSettingsModel, textSettings: TextSettingsModel) {
        self.model = model
        self.textSettings = textSettings
    }

    var body: some View {
        Section {
            ForEach(ShortcutAction.allCases, id: \.self) { action in
                row(action)
            }
            if model.dictationShortcutMissing {
                Label(ShortcutDisplay.missingDictation, systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                Button(L10n.string("shortcut.restore.confirm", fallback: "Restore Defaults")) {
                    recorder.stop()
                    recorder.warning = nil
                    model.restoreDefaults()
                }.disabled(!model.canRestoreDefaults)
            }
        } header: {
            Text(L10n.string("shortcut.section.title", fallback: "Shortcuts"))
        } footer: {
            SettingsNote(L10n.format(
                "shortcut.recorder.footer",
                "Press %1$@ to cancel or %2$@ to clear. Fn and Globe keys aren't supported. Shortcuts may pause in password fields and other places that use Secure Input.",
                arguments: [ShortcutChord.escape.title, ShortcutChord.delete.title]
            ))
        }
        .onDisappear { recorder.stop() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in recorder.stop() }
    }

    private func row(_ action: ShortcutAction) -> some View {
        let binding = model.bindings[action]
        let recording = recorder.action == action
        return HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 3) {
                Text(action.title)
                if let warning = recorder.warning, warning.0 == action {
                    Label(warning.1, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.caption)
                } else if binding.chord == nil {
                    Text(ShortcutDisplay.off).font(.caption).foregroundStyle(.secondary)
                } else if (action == .translate && !textSettings.translationEnabled) || (action == .polish && !textSettings.polishEnabled) {
                    Text(L10n.string("shortcut.recorder.feature_off", fallback: "Off in Text settings"))
                        .font(.caption).foregroundStyle(.secondary)
                } else if action == .dictate {
                    Text(L10n.string("shortcut.recorder.hold", fallback: "Hold to talk, release to insert."))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 4)
            if action.gestures.count > 1 {
                Picker(action.title, selection: Binding(get: { binding.gesture }, set: { gesture in
                    recorder.stop()
                    var candidate = binding
                    candidate.gesture = gesture
                    recorder.warning = model.assign(candidate, to: action).map { (action, $0) }
                })) {
                    ForEach(action.gestures, id: \.self) { Text($0.title).tag($0) }
                }.labelsHidden().fixedSize()
            }
            Button {
                if recording { recorder.stop() } else { recorder.begin(action, model: model) }
            } label: {
                Group {
                    if recording {
                        Text(L10n.string("shortcut.recorder.prompt", fallback: "Type shortcut…"))
                    } else if let chord = binding.chord {
                        KeycapView(chord: chord)
                    } else {
                        Text(L10n.string("shortcut.caption.off", fallback: "Off"))
                    }
                }
                .padding(.horizontal, 5)
                .frame(width: 150, height: 30)
                .background(SettingsPalette.recorder, in: RoundedRectangle(cornerRadius: 5))
                .overlay {
                    if recording {
                        RoundedRectangle(cornerRadius: 5)
                            .strokeBorder(SettingsPalette.focus, lineWidth: 2)
                    }
                }
            }.buttonStyle(.plain).accessibilityLabel(Text(action.title)).accessibilityValue(Text(binding.hint))
            icon("xmark.circle", L10n.string("shortcut.recorder.clear", fallback: "Clear shortcut")) {
                recorder.stop()
                recorder.warning = nil
                model.clear(action)
            }.disabled(binding.chord == nil)
            let dirty = binding != ShortcutBindings.default[action]
            icon("arrow.counterclockwise", L10n.string("shortcut.recorder.reset", fallback: "Reset shortcut")) {
                recorder.stop()
                recorder.warning = model.reset(action).map { (action, $0) }
            }.disabled(!dirty).opacity(dirty ? 1 : 0)
        }
    }

    private func icon(_ symbol: String, _ label: String, perform: @escaping () -> Void) -> some View {
        Button(action: perform) { Image(systemName: symbol).frame(width: 20, height: 24) }
            .buttonStyle(.borderless).help(label).accessibilityLabel(Text(label))
    }
}

#if DEBUG
struct ShortcutsSectionPreview: PreviewProvider {
    static var previews: some View {
        Form { ShortcutsSection(model: .shared, textSettings: .shared) }.formStyle(.grouped).frame(width: 620, height: 420)
    }
}
#endif
