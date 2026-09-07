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
                        fallback: "Enable Text Polish"
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
                            || !model.polishEnabled
                            || (!model.polishAvailable && !model.autoPolishEnabled)
                    )
                    Text(L10n.string(
                        "settings.text.auto_polish.note",
                        fallback: "Local dictation only. When off, double-tap Right ⌥ to polish a selection. If automatic polishing fails, the transcript is kept."
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
                    Text(excludedSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            SettingsRow(L10n.string("settings.text.instructions", fallback: "Polish prompt:")) {
                VStack(alignment: .leading, spacing: 6) {
                    Button(L10n.string("settings.text.prompt.edit", fallback: "Edit Polish Prompt…")) {
                        model.editPolishInstructions()
                    }
                    .buttonStyle(.bordered)
                    Text(L10n.string(
                        "settings.text.instructions.note",
                        fallback: "Edit the complete prompt shared by manual and automatic polishing. Test changes in Eval Mode before saving."
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }

            SettingsDivider()

            SettingsSectionHeader(
                title: L10n.string("settings.text.eval.header", fallback: "Eval Mode"),
                subtitle: L10n.string(
                    "settings.text.eval.note",
                    fallback: "Inspect local dictation and polish results, then try your own prompt. Text only, never uploaded. Entries are cleared on normal quit, or next launch after a crash or force quit. Export cases before quitting to keep them. Saved prompts and exports remain."
                )
            )

            SettingsRow(L10n.string("settings.text.eval.entries_label", fallback: "Entries:")) {
                VStack(alignment: .leading, spacing: 7) {
                    Text(evalSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        Button(L10n.string(
                            "settings.text.eval.show_window",
                            fallback: "Show Window…"
                        )) { model.showEvalWindow() }
                        Button(L10n.string(
                            "settings.text.eval.reveal",
                            fallback: "Reveal in Finder"
                        )) { model.revealEvalData() }
                    }
                }
            }

            SettingsRow {
                Button(
                    L10n.string(
                        "settings.text.eval.delete_all",
                        fallback: "Delete All Eval Data…"
                    ),
                    role: .destructive
                ) { confirmDeleteAllEvalData() }
                .disabled(model.evalCount == 0)
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
        .onReceive(NotificationCenter.default.publisher(for: .evalStoreDidChange)) { _ in
            model.refreshEvalData()
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
                fallback: "No apps excluded. Exclusions apply to Auto Polish and Eval Mode."
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

    private var evalSummary: String {
        let count = L10n.plural(
            "eval.entries_count",
            model.evalCount,
            fallback: "%ld entries"
        )
        let bytes = ByteCountFormatter.string(fromByteCount: model.evalBytes, countStyle: .file)
        return L10n.format(
            "settings.text.eval.entries_summary",
            "%1$@, %2$@ on disk",
            arguments: [count, bytes]
        )
    }

    private func confirmDeleteAllEvalData() {
        let count = L10n.plural(
            "eval.entries_count",
            model.evalCount,
            fallback: "%ld entries"
        )
        let bytes = ByteCountFormatter.string(fromByteCount: model.evalBytes, countStyle: .file)
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

}
