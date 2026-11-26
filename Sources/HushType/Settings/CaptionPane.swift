import AppKit
import Settings
import SwiftUI

@MainActor
final class CaptionSettingsModel: ObservableObject {
    @Published var targetLanguage: String {
        didSet { AppConfig.shared.cloudTargetLanguage = targetLanguage }
    }

    @Published var showSourceLine: Bool {
        didSet { AppConfig.shared.cloudShowSourceLine = showSourceLine }
    }

    @Published var autoStopMinutes: Int {
        didSet { AppConfig.shared.cloudAutoStopMinutes = autoStopMinutes }
    }

    private let onResetPanelFrame: () -> Void

    init(onResetPanelFrame: @escaping () -> Void) {
        self.onResetPanelFrame = onResetPanelFrame
        targetLanguage = AppConfig.shared.cloudTargetLanguage
        showSourceLine = AppConfig.shared.cloudShowSourceLine
        autoStopMinutes = AppConfig.shared.cloudAutoStopMinutes
    }

    func refresh() {
        targetLanguage = AppConfig.shared.cloudTargetLanguage
        showSourceLine = AppConfig.shared.cloudShowSourceLine
        autoStopMinutes = AppConfig.shared.cloudAutoStopMinutes
    }

    func resetPanelFrame() {
        onResetPanelFrame()
    }
}

struct CaptionPane: View {
    @StateObject private var model: CaptionSettingsModel

    init(onResetPanelFrame: @escaping () -> Void) {
        _model = StateObject(wrappedValue: CaptionSettingsModel(
            onResetPanelFrame: onResetPanelFrame
        ))
    }

    private static var targetLanguages: [(value: String, label: String)] {[
        ("en", L10n.string("picker.autonym.en", fallback: "English")),
        ("zh-Hant", L10n.string("picker.target.traditional_chinese_autonym", fallback: "繁體中文")),
        ("zh-Hans", L10n.string("picker.target.simplified_chinese_autonym", fallback: "简体中文")),
        ("ja", L10n.string("picker.autonym.ja", fallback: "日本語")),
        ("ko", L10n.string("picker.autonym.ko", fallback: "한국어")),
        ("es", L10n.string("picker.autonym.es", fallback: "Español")),
        ("pt", L10n.string("picker.autonym.pt", fallback: "Português")),
        ("fr", L10n.string("picker.autonym.fr", fallback: "Français")),
        ("de", L10n.string("picker.autonym.de", fallback: "Deutsch")),
        ("ru", L10n.string("picker.autonym.ru", fallback: "Русский")),
        ("hi", L10n.string("picker.autonym.hi", fallback: "हिन्दी")),
        ("id", L10n.string("picker.autonym.id", fallback: "Bahasa Indonesia")),
        ("vi", L10n.string("picker.autonym.vi", fallback: "Tiếng Việt")),
        ("it", L10n.string("picker.autonym.it", fallback: "Italiano")),
    ]}

    var body: some View {
        SettingsPage(height: 480, pane: .caption) {
            Section(L10n.string("settings.caption.panel_title", fallback: "Caption panel")) {
                SettingRow(
                    L10n.string("settings.caption.panel_geometry", fallback: "Size and position"),
                    description: L10n.string("settings.caption.panel_size", fallback: "Lamitype remembers where you put the panel.")
                ) {
                    Button(L10n.string("settings.button.reset", fallback: "Reset")) {
                        model.resetPanelFrame()
                    }
                }
            }

            Section {
                SettingRow(L10n.string("settings.translated_caption.target", fallback: "Target language")) {
                    Picker(L10n.string("settings.translated_caption.target", fallback: "Target language"),
                           selection: $model.targetLanguage) {
                        ForEach(Self.targetLanguages, id: \.value) { language in
                            Text(language.label).tag(language.value)
                        }
                    }
                    .settingsPopup()
                }
                Toggle(L10n.string("settings.translated_caption.show_source", fallback: "Show source text"),
                       isOn: $model.showSourceLine)
                    .toggleStyle(.switch)
                    .modifier(SettingsActiveTint())
                SettingRow(L10n.string("settings.cost_guardrails.auto_stop", fallback: "Stop automatically after")) {
                    Stepper(value: Binding(
                        get: { model.autoStopMinutes },
                        set: { model.autoStopMinutes = max(5, min(480, $0)) }
                    ), in: 5...480, step: 5) {
                        Text(L10n.plural(
                            "settings.duration.minutes",
                            count: model.autoStopMinutes,
                            fallback: "%1$d min",
                            arguments: [Int32(model.autoStopMinutes)]
                        ))
                        .monospacedDigit()
                    }
                }
            } header: {
                Text(L10n.string("settings.caption.translation", fallback: "Translated captions"))
            } footer: {
                SettingsNote(L10n.string("settings.caption.note", fallback: "OpenAI realtime, about $2 per hour. Audio goes directly from this Mac to OpenAI and counts toward the daily cap."))
            }
        }
        .onAppear { model.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refresh()
        }
    }

    static func makeSettingsPane(
        onResetPanelFrame: @escaping () -> Void
    ) -> AppSettings.Pane<CaptionPane> {
        let title = L10n.string("settings.tab.caption", fallback: "Caption")
        return AppSettings.Pane(
            identifier: .caption,
            title: title,
            toolbarIcon: NSImage(
                systemSymbolName: "captions.bubble",
                accessibilityDescription: title
            )!
        ) {
            CaptionPane(onResetPanelFrame: onResetPanelFrame)
        }
    }

}
