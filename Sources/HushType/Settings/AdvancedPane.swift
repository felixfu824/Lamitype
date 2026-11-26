import AppKit
import Settings
import SwiftUI

extension Notification.Name {
    static let iosServerStatusDidChange = Notification.Name(
        "com.felix.hushtype.iosServerStatusDidChange"
    )
}

struct AdvancedPane: View {
    static let runningUserInfoKey = "isRunning"

    private let onToggle: () -> Void
    private let isRunningProvider: () -> Bool
    @State private var isRunning: Bool

    init(onToggle: @escaping () -> Void, isRunning: @escaping () -> Bool) {
        self.onToggle = onToggle
        isRunningProvider = isRunning
        _isRunning = State(initialValue: isRunning())
    }

    @ObservedObject private var model = TextSettingsModel.shared

    var body: some View {
        SettingsPage(height: 500, pane: .ios) {
            Section {
                SettingRow(L10n.string("settings.text.eval.entries_label", fallback: "Entries")) {
                    HStack(spacing: 8) {
                        Text(evalSummary)
                            .foregroundStyle(.secondary)
                        Button(L10n.string("settings.button.open", fallback: "Open…")) {
                            model.showEvalWindow()
                        }
                        Button(L10n.string("settings.text.eval.reveal", fallback: "Reveal")) {
                            model.revealEvalData()
                        }
                    }
                }
                SettingRow(L10n.string("settings.advanced.eval.stored", fallback: "Stored examples")) {
                    Button(L10n.string("settings.text.eval.delete_all", fallback: "Delete all entries…"),
                           role: .destructive, action: confirmDeleteAllEvalData)
                        .disabled(model.evalCount == 0)
                }
            } header: {
                Text(L10n.string("settings.text.eval.header", fallback: "Eval Mode"))
            } footer: {
                SettingsNote(L10n.string("settings.text.eval.note", fallback: "Text only, never uploaded. Entries are cleared when Lamitype quits. Export cases to keep them."))
            }

            Section(L10n.string("settings.advanced.caption", fallback: "Caption engine")) {
                FileSettingRow(title: L10n.string("settings.caption.advanced", fallback: "Tuning file"),
                               url: LiveCaptionTuning.fileURL) {
                    SettingsNote(L10n.string("settings.caption.advanced.note", fallback: "VAD thresholds, token limit and cache cap."))
                } open: {
                    openAdvancedTuning()
                }
            }

            Section {
                SettingRow(L10n.string("settings.ios.status", fallback: "Server")) {
                    HStack(spacing: 8) {
                        SettingsStatusLabel(
                            kind: isRunning ? .available : .inactive,
                            text: isRunning
                                ? L10n.string("settings.ios.status.running", fallback: "Running on port 8000")
                                : L10n.string("settings.ios.status.stopped", fallback: "Stopped")
                        )
                        Button(isRunning
                               ? L10n.string("settings.ios.stop", fallback: "Stop")
                               : L10n.string("settings.ios.start", fallback: "Start"),
                               action: onToggle)
                    }
                }
            } header: {
                Text(L10n.string("settings.ios.title", fallback: "iOS Server (untested)"))
            } footer: {
                SettingsNote(L10n.string("settings.ios.note", fallback: "Experimental and untested. Needs Python dependencies and port 8000, uses the local model on this Mac, and cannot run alongside Live Caption."))
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .evalStoreDidChange)) { _ in
            model.refreshEvalData()
        }
        .onAppear {
            isRunning = isRunningProvider()
            model.refreshEvalData()
        }
        .onReceive(NotificationCenter.default.publisher(for: .iosServerStatusDidChange)) { note in
            if let running = note.userInfo?[Self.runningUserInfoKey] as? Bool {
                isRunning = running
            } else {
                isRunning = isRunningProvider()
            }
        }
    }

    static func makeSettingsPane(
        onToggle: @escaping () -> Void,
        isRunning: @escaping () -> Bool
    ) -> AppSettings.Pane<AdvancedPane> {
        let title = L10n.string("settings.tab.advanced", fallback: "Advanced")
        return AppSettings.Pane(
            identifier: .ios,
            title: title,
            toolbarIcon: NSImage(
                systemSymbolName: "slider.horizontal.3",
                accessibilityDescription: title
            )!
        ) {
            AdvancedPane(onToggle: onToggle, isRunning: isRunning)
        }
    }

    private func openAdvancedTuning() {
        LiveCaptionTuning.createTemplateIfMissing()
        let url = LiveCaptionTuning.fileURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            let alert = NSAlert()
            alert.messageText = L10n.string(
                "alert.file_create.live_caption.title",
                fallback: "Could not open Live Caption settings"
            )
            alert.informativeText = L10n.format(
                "alert.file_create.live_caption.message",
                "Failed to create the Live Caption settings file at:\n%1$@",
                arguments: [url.path]
            )
            alert.alertStyle = .warning
            alert.addButton(withTitle: L10n.string("common.button.ok", fallback: "OK"))
            alert.runModal()
            return
        }
        NSWorkspace.shared.open(url)
    }

    private var evalSummary: String {
        let count = L10n.plural(
            "eval.entries_count",
            model.evalCount,
            fallback: "%ld entries"
        )
        let bytes = formattedEvalBytes
        return L10n.format(
            "settings.text.eval.entries_summary",
            "%1$@, %2$@",
            arguments: [count, bytes]
        )
    }

    private func confirmDeleteAllEvalData() {
        let count = L10n.plural(
            "eval.entries_count",
            model.evalCount,
            fallback: "%ld entries"
        )
        let bytes = formattedEvalBytes
        let alert = NSAlert()
        alert.messageText = L10n.format(
            "eval.delete_all.confirm",
            "Delete %1$@ (%2$@)? This cannot be undone.",
            arguments: [count, bytes]
        )
        alert.addButton(withTitle: L10n.string("eval.delete_all.button", fallback: "Delete"))
        alert.addButton(withTitle: L10n.string("common.button.cancel", fallback: "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        model.deleteAllEvalData()
    }
    private var formattedEvalBytes: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.allowsNonnumericFormatting = false
        return formatter.string(fromByteCount: model.evalBytes)
    }
}
