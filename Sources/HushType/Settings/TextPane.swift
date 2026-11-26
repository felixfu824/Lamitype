import AppKit
import Settings
import SwiftUI

struct TextPane: View {
    @ObservedObject private var shortcuts = ShortcutSettingsModel.shared
    @ObservedObject private var model: TextSettingsModel

    init() {
        self.model = .shared
    }

    init(model: TextSettingsModel) {
        self.model = model
    }

    var body: some View {
        SettingsPage(height: 640, pane: .text) {
            Section {
                Toggle(isOn: Binding(
                    get: { model.polishEnabled },
                    set: { model.requestPolishEnabled($0) }
                )) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(L10n.string("settings.text.polish.cb", fallback: "Polish selected text"))
                        ShortcutKeycapHint(binding: shortcuts.bindings[.polish])
                    }
                    .accessibilityElement(children: .combine)
                }
                .toggleStyle(.switch)
                .modifier(SettingsActiveTint())
                .disabled(model.isValidatingPolish || (!model.polishAvailable && !model.polishEnabled))

                Toggle(isOn: Binding(
                    get: { model.autoPolishEnabled },
                    set: { model.requestAutoPolishEnabled($0) }
                )) {
                    SettingLabel(
                        title: L10n.string("settings.text.auto_polish.cb", fallback: "Polish dictation automatically"),
                        description: L10n.string("settings.text.auto_polish.scope", fallback: "Local dictation only. If polishing fails, the transcript is kept.")
                    )
                }
                .toggleStyle(.switch)
                .modifier(SettingsActiveTint())
                .disabled(model.isValidatingPolish || !model.polishEnabled
                          || (!model.polishAvailable && !model.autoPolishEnabled))

                SettingRow(L10n.string("settings.text.auto_polish.excluded_label", fallback: "Excluded apps")) {
                    HStack(spacing: 8) {
                        Text(excludedSummary)
                            .foregroundStyle(.secondary)
                        Button(L10n.string("settings.text.auto_polish.choose_apps", fallback: "Choose…")) {
                            AutoPolishExclusionPicker.present(model: model)
                        }
                        .disabled(!model.polishEnabled)
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    SettingRow(
                        L10n.string("settings.text.instructions", fallback: "Prompt"),
                        description: L10n.string("settings.text.instructions.note", fallback: "Shared by manual and automatic polishing.")
                    ) {
                        Button(L10n.string("settings.text.prompt.edit", fallback: "Edit…")) {
                            model.editPolishInstructions()
                        }
                        .disabled(!model.polishEnabled)
                    }
                }
            } header: {
                Text(L10n.string("settings.text.polish_title", fallback: "Text Polish"))
            } footer: {
                SettingsNote(L10n.string("settings.text.polish_sub", fallback: "On-device with Apple Foundation Models. Capability is limited."))
            }

            Section {
                Toggle(isOn: Binding(
                    get: { model.translationEnabled },
                    set: { model.setTranslationEnabled($0) }
                )) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(L10n.string("settings.text.translation.title", fallback: "Translate selected text"))
                        ShortcutKeycapHint(binding: shortcuts.bindings[.translate])
                    }
                    .accessibilityElement(children: .combine)
                }
                .toggleStyle(.switch)
                .modifier(SettingsActiveTint())

                VStack(alignment: .leading, spacing: 6) {
                    SettingRow(L10n.string("settings.text.translate_to", fallback: "Translate to")) {
                        Picker(
                            L10n.string("settings.text.translate_to", fallback: "Translate to"),
                            selection: Binding(
                                get: { model.translationTarget },
                                set: { model.setTranslationTarget($0) }
                            )
                        ) {
                            ForEach(Self.translationTargets, id: \.value) { choice in
                                Text(choice.title).tag(choice.value)
                            }
                        }
                        .settingsPopup()
                        .disabled(!model.translationEnabled)
                    }
                }
            } header: {
                Text(L10n.string("settings.text.translation.header", fallback: "Translation"))
            } footer: {
                SettingsNote(L10n.string("settings.text.translation_sub", fallback: "On-device with Apple Translation. Auto picks the opposite of the detected language."))
            }
        }
        .onAppear { model.refreshFromConfig() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshFromConfig(polishAvailability: TextPolisher.isAvailableCached)
        }
    }

    static func makeSettingsPane() -> AppSettings.Pane<TextPane> {
        let title = L10n.string("settings.tab.text", fallback: "Text")
        return AppSettings.Pane(
            identifier: .text,
            title: title,
            toolbarIcon: NSImage(
                systemSymbolName: "textformat",
                accessibilityDescription: title
            )!
        ) {
            TextPane(model: .shared)
        }
    }

    private static var translationTargets: [(title: String, value: String?)] {
        [
            (L10n.string("menu.choice.auto", fallback: "Auto"), nil),
            (L10n.string("picker.autonym.en", fallback: "English"), "en"),
            ("繁體中文", "zh-Hant-TW"),
            (L10n.string("picker.autonym.ja", fallback: "日本語"), "ja"),
            (L10n.string("picker.autonym.ko", fallback: "한국어"), "ko"),
            (L10n.string("picker.autonym.fr", fallback: "Français"), "fr"),
            (L10n.string("picker.autonym.de", fallback: "Deutsch"), "de"),
            (L10n.string("picker.autonym.es", fallback: "Español"), "es"),
        ]
    }

    private var excludedSummary: String {
        let count = model.excludedBundleIDs.count
        guard count > 0 else {
            return L10n.string("settings.text.auto_polish.excluded_none", fallback: "None")
        }
        return L10n.plural("settings.text.auto_polish.excluded_count", count,
                           fallback: count == 1 ? "%ld app" : "%ld apps")
    }
}
