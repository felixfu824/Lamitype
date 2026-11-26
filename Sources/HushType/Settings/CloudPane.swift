import AppKit
import Settings
import SwiftUI

@MainActor
final class CloudSettingsModel: ObservableObject {
    @Published var dailyCap: Double {
        didSet { AppConfig.shared.cloudDailyCapDollars = dailyCap }
    }

    @Published private(set) var usage: CloudUsageTracker.Snapshot?
    @Published private(set) var openAIKeyStatus: OpenAIKeyStore.LoadStatus = .empty
    @Published private(set) var geminiKeyStatus: GeminiKeyStore.LoadStatus = .empty

    init() {
        dailyCap = AppConfig.shared.cloudDailyCapDollars
    }

    func refreshDerived() {
        dailyCap = AppConfig.shared.cloudDailyCapDollars
        openAIKeyStatus = OpenAIKeyStore.load()
        geminiKeyStatus = GeminiKeyStore.load()
        Task { [weak self] in
            let snapshot = await CloudUsageTracker.shared.snapshot()
            await MainActor.run {
                self?.usage = snapshot
            }
        }
    }

    func resetCounter() {
        Task { [weak self] in
            await CloudUsageTracker.shared.resetDailyCounter()
            await MainActor.run { self?.refreshDerived() }
        }
    }

    func confirmAndResetCounter() {
        let alert = Self.makeResetCounterAlert()
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        resetCounter()
    }

    static func makeResetCounterAlert() -> NSAlert {
        let alert = NSAlert()
        alert.messageText = L10n.string(
            "alert.cloud.reset_counter.title",
            fallback: "Reset today's usage counter?"
        )
        alert.informativeText = L10n.string(
            "alert.cloud.reset_counter.message",
            fallback: "This resets only Lamitype's estimate of today's cloud usage. It does not change usage or charges reported by OpenAI or Gemini. Cloud uploads will be allowed again today."
        )
        alert.alertStyle = .warning
        alert.addButton(withTitle: L10n.string("common.button.cancel", fallback: "Cancel"))
        alert.addButton(withTitle: L10n.string(
            "alert.cloud.reset_counter.confirm",
            fallback: "Reset Counter"
        ))
        alert.buttons[0].keyEquivalent = "\r"
        alert.buttons[1].keyEquivalent = ""
        alert.buttons[1].hasDestructiveAction = true
        return alert
    }

    func openKeyFile(provider: CloudUsageTracker.Provider) {
        switch provider {
        case .openai:
            OpenAIKeyStore.openInDefaultEditor()
        case .gemini:
            GeminiKeyStore.openInDefaultEditor()
        }
    }

}

struct CloudPane: View {
    @StateObject private var model = CloudSettingsModel()

    var body: some View {
        SettingsPage(height: 480, pane: .cloud) {
            Section {
                SettingRow(L10n.string("settings.cloud.cap", fallback: "Daily spend cap")) {
                    Stepper(value: Binding(
                        get: { model.dailyCap },
                        set: { model.dailyCap = max(0.5, min(100.0, $0)) }
                    ), in: 0.5...100.0, step: 0.5) {
                        Text(CloudUsageTracker.formatDollars(model.dailyCap))
                            .monospacedDigit()
                    }
                }
                SettingRow(L10n.string("settings.cloud.today", fallback: "Today")) {
                    HStack(spacing: 8) {
                        if let usage = model.usage {
                            Text(CloudUsageTracker.formatDollars(usage.dayDollars))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                            SettingsInfoButton(
                                title: L10n.string("settings.cloud.usage_details", fallback: "Usage breakdown"),
                                detail: CloudUsageTracker.formatDailyBreakdown(usage)
                            )
                        }
                        Button(L10n.string("settings.button.reset_confirm", fallback: "Reset…"), role: .destructive) {
                            model.confirmAndResetCounter()
                        }
                    }
                }
            } header: {
                Text(L10n.string("settings.cloud.spending", fallback: "Spending"))
            } footer: {
                SettingsNote(L10n.string("settings.cloud.spending.note", fallback: "At the cap, dictation stops uploading for the day. A running caption session gets a notice and continues."))
            }

            Section {
                FileSettingRow(title: "OpenAI", url: URL(fileURLWithPath: OpenAIKeyStore.displayPath)) {
                    switch model.openAIKeyStatus {
                    case .ok: keyStatus(.available)
                    case .empty: keyStatus(.inactive)
                    case .unusualFormat: keyStatus(.warning)
                    }
                } open: {
                    model.openKeyFile(provider: .openai)
                }
                FileSettingRow(title: "Gemini", url: URL(fileURLWithPath: GeminiKeyStore.displayPath)) {
                    switch model.geminiKeyStatus {
                    case .ok: keyStatus(.available)
                    case .empty: keyStatus(.inactive)
                    case .unusualFormat: keyStatus(.warning)
                    }
                } open: {
                    model.openKeyFile(provider: .gemini)
                }
            } header: {
                Text(L10n.string("settings.cloud.keys", fallback: "API keys"))
            } footer: {
                SettingsNote(L10n.string("settings.cloud.key.note", fallback: "Keys stay in local files and go only to their provider."))
            }
        }
        .onAppear { model.refreshDerived() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshDerived()
        }
    }

    static func makeSettingsPane() -> AppSettings.Pane<CloudPane> {
        let title = L10n.string("settings.tab.cloud", fallback: "Cloud")
        return AppSettings.Pane(
            identifier: .cloud,
            title: title,
            toolbarIcon: NSImage(systemSymbolName: "dollarsign.circle", accessibilityDescription: title)!
        ) {
            CloudPane()
        }
    }

    private func keyStatus(_ kind: SettingsStatusLabel.Kind) -> some View {
        let text: String
        switch kind {
        case .available:
            text = L10n.string("settings.key.status.loaded", fallback: "Key loaded")
        case .inactive:
            text = L10n.string("settings.key.status.empty", fallback: "No key")
        case .warning:
            text = L10n.string("settings.key.status.unusual", fallback: "Unusual format, used as is")
        }
        return SettingsStatusLabel(kind: kind, text: text)
            .font(.caption)
    }
}
