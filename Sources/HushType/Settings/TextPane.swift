import AppKit
import Settings
import SwiftUI

struct TextPane: View {
    @ObservedObject private var model: TextSettingsModel

    init() {
        self.model = .shared
    }

    init(model: TextSettingsModel) {
        self.model = model
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsGrid.rowSpacing) {
            SettingsSectionHeader(
                title: L10n.string("settings.text.polish_title", fallback: "Text Polish"),
                subtitle: L10n.string(
                    "settings.text.polish_sub",
                    fallback: "Apple Foundation Models · on-device · limited capability"
                )
            )

            SettingsRow {
                Toggle(
                    L10n.string(
                        "settings.text.polish.cb",
                        fallback: "Proofread selection on double-tap Right ⌥"
                    ),
                    isOn: Binding(
                        get: { model.polishEnabled },
                        set: { model.requestPolishEnabled($0) }
                    )
                )
                .disabled(model.isValidatingPolish || (!model.polishAvailable && !model.polishEnabled))
            }

            SettingsRow {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle(
                        L10n.string(
                            "settings.text.auto_polish.cb",
                            fallback: "Polish dictated text automatically"
                        ),
                        isOn: Binding(
                            get: { model.autoPolishEnabled },
                            set: { model.requestAutoPolishEnabled($0) }
                        )
                    )
                    .disabled(
                        model.isValidatingPolish
                            || (!model.polishAvailable && !model.autoPolishEnabled)
                    )
                    Text(L10n.string(
                        "settings.text.auto_polish.note",
                        fallback: "Local dictation only. Runs the same on-device proofread before the text is inserted. The raw transcript is kept if polishing fails or times out."
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }

            SettingsRow(L10n.string(
                "settings.text.auto_polish.excluded_label",
                fallback: "Excluded apps:"
            )) {
                VStack(alignment: .leading, spacing: 6) {
                    Button(L10n.string(
                        "settings.text.auto_polish.choose_apps",
                        fallback: "Choose Apps…"
                    )) {
                        AutoPolishExclusionPicker.present(model: model)
                    }
                    .buttonStyle(.bordered)
                    .disabled(!model.autoPolishEnabled)
                    Text(excludedSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            SettingsRow(L10n.string("settings.text.instructions", fallback: "Polish instructions:")) {
                VStack(alignment: .leading, spacing: 6) {
                    Button(L10n.string("common.button.open_in_textedit", fallback: "Open in TextEdit")) {
                        model.editPolishInstructions()
                    }
                    .buttonStyle(.bordered)
                    Text(L10n.string(
                        "settings.text.instructions.note",
                        fallback: "Plain-text instructions sent with every proofread request."
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }

            SettingsDivider()

            SettingsSectionHeader(
                title: L10n.string("menu.text_translation", fallback: "Text Translation"),
                subtitle: L10n.string(
                    "settings.text.translation_sub",
                    fallback: "Apple Translation Framework · on-device · limited language support"
                )
            )

            SettingsRow {
                Toggle(
                    L10n.string(
                        "settings.text.translation.cb",
                        fallback: "Translate selection on tap Right ⌥"
                    ),
                    isOn: Binding(
                        get: { model.translationEnabled },
                        set: { model.setTranslationEnabled($0) }
                    )
                )
            }

            SettingsRow(L10n.string("settings.text.translate_to", fallback: "Translate to:")) {
                Picker(
                    "",
                    selection: Binding(
                        get: { model.translationTarget },
                        set: { model.setTranslationTarget($0) }
                    )
                ) {
                    ForEach(Self.translationTargets, id: \.value) { choice in
                        Text(choice.title).tag(choice.value)
                    }
                }
                .labelsHidden()
                .disabled(!model.translationEnabled)
            }
            .padding(.bottom, 8)

            SettingsRow {
                Text(L10n.string(
                    "settings.text.note",
                    fallback: "Auto picks the opposite of the detected language. Selection translation and selection proofreading share the Right ⌥ key: one tap translates, two taps proofread."
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .settingsPaneLayout()
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
        let bundleIDs = model.excludedBundleIDs
        guard !bundleIDs.isEmpty else {
            return L10n.string(
                "settings.text.auto_polish.excluded_none",
                fallback: "No apps excluded. Dictation is polished everywhere."
            )
        }
        var names = bundleIDs.prefix(4).map(AutoPolishAppNameResolver.displayName)
        if bundleIDs.count > 4 { names.append("…") }
        return L10n.plural(
            "settings.text.auto_polish.excluded_summary",
            count: bundleIDs.count,
            fallback: "%1$ld excluded: %2$@",
            arguments: [bundleIDs.count, names.joined(separator: ", ")]
        )
    }

}
