import AppKit
import Settings
import SwiftUI

@MainActor
final class GeneralSettingsModel: ObservableObject {
    @Published private(set) var selectedLanguage = AppConfig.shared.interfaceLanguage
    @Published var floatingIndicatorEnabled = AppConfig.shared.floatingOverlayEnabled {
        didSet { AppConfig.shared.floatingOverlayEnabled = floatingIndicatorEnabled }
    }

    func selectInterfaceLanguage(_ selected: InterfaceLanguage) {
        guard selected != AppConfig.shared.interfaceLanguage else { return }
        AppConfig.shared.interfaceLanguage = selected
        selectedLanguage = selected
    }
}

@MainActor
struct GeneralPane: View {
    @StateObject private var model = GeneralSettingsModel()
    private let shortcuts: ShortcutSettingsModel
    private let textSettings: TextSettingsModel

    init() {
        self.init(shortcuts: .shared, textSettings: .shared)
    }

    init(shortcuts: ShortcutSettingsModel, textSettings: TextSettingsModel) {
        self.shortcuts = shortcuts
        self.textSettings = textSettings
    }

    static let height: CGFloat = 560

    var body: some View {
        SettingsPage(height: Self.height, pane: .general) {
            Section(L10n.string("settings.general.appearance", fallback: "Appearance")) {
                SettingRow(
                    L10n.string("settings.general.language", fallback: "Language"),
                    description: L10n.string("settings.general.language.note", fallback: "Applies the next time you open Lamitype.")
                ) {
                    Picker(
                        L10n.string("settings.general.language", fallback: "Language"),
                        selection: Binding(
                            get: { model.selectedLanguage },
                            set: { model.selectInterfaceLanguage($0) }
                        )
                    ) {
                        Text(followSystemLabel).tag(InterfaceLanguage.system)
                        Text(L10n.string("menu.interface_language.english", fallback: "English"))
                            .tag(InterfaceLanguage.english)
                        Text(L10n.string("menu.interface_language.traditional_chinese_taiwan", fallback: "繁體中文（台灣）"))
                            .tag(InterfaceLanguage.traditionalChineseTaiwan)
                    }
                    .settingsPopup()
                }

                Toggle(isOn: $model.floatingIndicatorEnabled) {
                    SettingLabel(
                        title: L10n.string("settings.general.indicator", fallback: "Floating indicator"),
                        description: L10n.string("settings.general.indicator.note", fallback: "Shows Listening and Transcribing near the bottom of the screen.")
                    )
                }
                .toggleStyle(.switch)
                .modifier(SettingsActiveTint())
            }

            ShortcutsSection(model: shortcuts, textSettings: textSettings)
        }
    }

    static func makeSettingsPane() -> AppSettings.Pane<GeneralPane> {
        let title = L10n.string("settings.tab.general", fallback: "General")
        return AppSettings.Pane(
            identifier: .general,
            title: title,
            toolbarIcon: NSImage(
                systemSymbolName: "gearshape",
                accessibilityDescription: title
            )!
        ) {
            GeneralPane()
        }
    }

    private var followSystemLabel: String {
        let systemTag = InterfaceLocale.effectiveTag(
            preferences: InterfaceLocale.processPreferredTags
        )
        let systemLanguageNames = [
            "en": "English",
            "zh-Hant-TW": "繁體中文（台灣）",
        ]
        guard let effectiveName = systemLanguageNames[systemTag] else {
            return L10n.string(
                "menu.interface_language.follow_system",
                fallback: "Follow System"
            )
        }
        return L10n.format(
            "settings.general.language.value",
            "Follow System (%1$@)",
            arguments: [effectiveName]
        )
    }

}
