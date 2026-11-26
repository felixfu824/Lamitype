import AppKit
import Settings
import SwiftUI

extension Notification.Name {
    static let lamitypeDictationEngineDidChange = Notification.Name(
        "com.felix.hushtype.dictationEngineDidChange"
    )
}

@MainActor
final class DictationSettingsModel: ObservableObject {
    @Published var engine: AppConfig.DictationEngine {
        didSet {
            guard engine != oldValue else { return }
            onSwitchEngine(engine)
        }
    }

    @Published private(set) var livePreviewEnabled: Bool
    @Published private(set) var livePreviewCanChange: Bool
    @Published var liveBusy = false

    @Published var openAIModel: String {
        didSet { AppConfig.shared.cloudDictationModelOpenAI = openAIModel }
    }

    @Published var geminiModel: String {
        didSet { AppConfig.shared.cloudDictationModelGemini = geminiModel }
    }

    @Published var speechLanguage: String? {
        didSet { AppConfig.shared.language = speechLanguage }
    }

    @Published var numberConversionEnabled: Bool {
        didSet { AppConfig.shared.numberConversionEnabled = numberConversionEnabled }
    }

    @Published var punctuationMode: PunctuationMode {
        didSet { AppConfig.shared.punctuationMode = punctuationMode }
    }

    @Published private(set) var dictionaryStatus = ""

    private let onSwitchEngine: (AppConfig.DictationEngine) -> Void
    private let previewController: LocalLivePreviewController

    init(onSwitchEngine: @escaping (AppConfig.DictationEngine) -> Void, previewController: LocalLivePreviewController? = nil) {
        self.onSwitchEngine = onSwitchEngine
        let previewController = previewController ?? .shared
        self.previewController = previewController
        engine = AppConfig.shared.dictationEngine
        livePreviewEnabled = previewController.isEnabled
        livePreviewCanChange = previewController.canChange
        liveBusy = LocalLiveOwnership.isBusy
        openAIModel = AppConfig.shared.cloudDictationModelOpenAI
        geminiModel = AppConfig.shared.cloudDictationModelGemini
        speechLanguage = AppConfig.shared.language
        numberConversionEnabled = AppConfig.shared.numberConversionEnabled
        punctuationMode = AppConfig.shared.punctuationMode
        refreshDictionaryStatus()
    }

    var openAIRate: Double {
        CloudUsageTracker.dictationRate(provider: .openai, model: openAIModel)
    }

    var geminiRate: Double {
        CloudUsageTracker.dictationRate(provider: .gemini, model: geminiModel)
    }

    func refresh() {
        engine = AppConfig.shared.dictationEngine
        refreshLivePreview()
        openAIModel = AppConfig.shared.cloudDictationModelOpenAI
        geminiModel = AppConfig.shared.cloudDictationModelGemini
        speechLanguage = AppConfig.shared.language
        numberConversionEnabled = AppConfig.shared.numberConversionEnabled
        punctuationMode = AppConfig.shared.punctuationMode
        refreshDictionaryStatus()
    }

    func refreshLivePreview() {
        livePreviewEnabled = previewController.isEnabled
        livePreviewCanChange = previewController.canChange
        liveBusy = LocalLiveOwnership.isBusy
    }

    func requestLivePreviewEnabled(_ enabled: Bool, from source: LocalLivePreviewController.Source) {
        previewController.request(enabled, from: source)
        refreshLivePreview()
    }

    func openDictionary() {
        DictionaryReplacer.createTemplateIfMissing()
        let url = AppConfig.dictionaryFileURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            let alert = NSAlert()
            alert.messageText = L10n.string(
                "alert.file_create.dictionary.title",
                fallback: "Could not open dictionary"
            )
            alert.informativeText = L10n.format(
                "alert.file_create.dictionary.message",
                "Failed to create the dictionary file at:\n%1$@",
                arguments: [url.path]
            )
            alert.alertStyle = .warning
            alert.addButton(withTitle: L10n.string("common.button.ok", fallback: "OK"))
            alert.runModal()
            return
        }
        NSWorkspace.shared.open(url)
        refreshDictionaryStatus()
    }

    private func refreshDictionaryStatus() {
        let count = DictionaryReplacer.entryCount
        dictionaryStatus = L10n.plural(
            "settings.dictation.dictionary.entries",
            count,
            fallback: count == 1 ? "%ld entry. Applies to every engine." : "%ld entries. Applies to every engine."
        )
    }
}

struct DictationPane: View {
    @StateObject private var model: DictationSettingsModel

    init(onSwitchEngine: @escaping (AppConfig.DictationEngine) -> Void) {
        _model = StateObject(
            wrappedValue: DictationSettingsModel(onSwitchEngine: onSwitchEngine)
        )
    }

    var body: some View {
        SettingsPage(height: 640, pane: .dictation) {
            Section {
                HStack {
                    Picker(L10n.string("settings.dictation.engine_label", fallback: "Engine"), selection: $model.engine) {
                        SettingLabel(
                            title: L10n.string("menu.engine.local_qwen", fallback: "Local (Qwen3-ASR)"),
                            description: L10n.string("settings.engine.local.detail", fallback: "On-device · Free")
                        )
                        .tag(AppConfig.DictationEngine.local)
                        SettingLabel(
                            title: L10n.string("menu.engine.openai_cloud", fallback: "OpenAI Cloud"),
                            description: cloudRate(model.openAIRate)
                        )
                        .tag(AppConfig.DictationEngine.openai)
                        SettingLabel(
                            title: L10n.string("menu.engine.gemini_cloud", fallback: "Gemini Cloud"),
                            description: cloudRate(model.geminiRate)
                        )
                        .tag(AppConfig.DictationEngine.gemini)
                    }
                    .labelsHidden()
                    .pickerStyle(.radioGroup)
                    .horizontalRadioGroupLayout()
                    .modifier(SettingsActiveTint())
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } header: {
                HStack(spacing: 8) {
                    Text(L10n.string("settings.dictation.engine_label", fallback: "Engine"))
                    Spacer()
                    SettingsInfoButton(
                        title: L10n.string("settings.engine.local.memory", fallback: "Local memory"),
                        detail: L10n.string("settings.engine.local.memory.detail", fallback: "Uses about 2.1 GB of memory, including a 1 GB cache cap.")
                    )
                }
            }

            switch model.engine {
            case .local:
                Section(L10n.string("settings.dictation.local_model", fallback: "Local model")) {
                    LocalModelPicker(switcher: LocalModelSwitcher.shared)
                    livePreview
                }
            case .openai:
                cloudModelSection("OpenAI", selection: $model.openAIModel) {
                    Text(L10n.string("settings.model.recommended", fallback: "gpt-4o-mini-transcribe (recommended)"))
                        .tag("gpt-4o-mini-transcribe")
                    Text(L10n.string("settings.model.gpt_transcribe", fallback: "gpt-transcribe"))
                        .tag("gpt-transcribe")
                }
            case .gemini:
                cloudModelSection("Gemini", selection: $model.geminiModel) {
                    Text(L10n.string("settings.model.quality", fallback: "gemini-3.7-flash (quality)"))
                        .tag("gemini-3.7-flash")
                    Text(L10n.string("settings.model.budget", fallback: "gemini-3.5-flash-lite (budget)"))
                        .tag("gemini-3.5-flash-lite")
                }
            }

            Section(L10n.string("settings.dictation.output", fallback: "Output")) {
                SettingRow(L10n.string("settings.dictation.spoken_language", fallback: "Spoken language")) {
                    Picker(L10n.string("settings.dictation.spoken_language", fallback: "Spoken language"),
                           selection: $model.speechLanguage) {
                        Text(L10n.string("menu.choice.auto", fallback: "Auto")).tag(nil as String?)
                        Text(L10n.string("picker.autonym.en", fallback: "English")).tag("english" as String?)
                        Text(L10n.string("picker.autonym.zh", fallback: "中文")).tag("chinese" as String?)
                        Text(L10n.string("picker.autonym.ja", fallback: "日本語")).tag("japanese" as String?)
                    }
                    .settingsPopup()
                }

                VStack(alignment: .leading, spacing: 6) {
                    Toggle(isOn: $model.numberConversionEnabled) {
                        SettingLabel(
                            title: L10n.string("settings.dictation.number_conversion", fallback: "Convert numbers to digits"),
                            description: L10n.string("settings.dictation.number_conversion.note", fallback: "Chinese and English only.")
                        )
                    }
                    .toggleStyle(.switch)
                    .modifier(SettingsActiveTint())

                    if model.numberConversionEnabled {
                        SampleRow(before: "今天三十二度", after: "今天32度")
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    SettingRow(
                        L10n.string("settings.dictation.punctuation", fallback: "Punctuation cleanup"),
                        description: L10n.string("settings.dictation.punctuation.note", fallback: "Chinese text only.")
                    ) {
                        Picker(L10n.string("settings.dictation.punctuation", fallback: "Punctuation cleanup"),
                               selection: $model.punctuationMode) {
                            Text(L10n.string("menu.punctuation.soft", fallback: "Soft: trim inline commas")).tag(PunctuationMode.soft)
                            Text(L10n.string("menu.punctuation.hard", fallback: "Hard: trim all marks")).tag(PunctuationMode.hard)
                            Text(L10n.string("menu.punctuation.off", fallback: "Off: keep model output")).tag(PunctuationMode.off)
                        }
                        .settingsPopup()
                    }

                    switch model.punctuationMode {
                    case .soft:
                        SampleRow(before: "你好，世界。真的嗎？對！", after: "你好世界。真的嗎？對！")
                    case .hard:
                        SampleRow(before: "你好，世界。再見！", after: "你好世界 再見")
                    case .off:
                        EmptyView()
                    }
                }

                FileSettingRow(title: L10n.string("settings.dictation.dictionary", fallback: "Custom dictionary"),
                               url: AppConfig.dictionaryFileURL) {
                    SettingsNote(model.dictionaryStatus)
                } open: {
                    model.openDictionary()
                }
            }
        }
        .disabled(model.liveBusy)
        .onReceive(NotificationCenter.default.publisher(for: .localLiveActivityChanged)) { _ in model.refreshLivePreview() }
        .onReceive(NotificationCenter.default.publisher(for: .localLivePreviewControlsChanged)) { _ in model.refreshLivePreview() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
            guard let window = note.object as? NSWindow,
                  window === LamitypeSettingsWindowController.shared.reminderParentWindow else { return }
            DispatchQueue.main.async { model.refreshLivePreview() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEndSheetNotification)) { note in
            guard let window = note.object as? NSWindow,
                  window === LamitypeSettingsWindowController.shared.reminderParentWindow else { return }
            DispatchQueue.main.async { model.refreshLivePreview() }
        }
        .onAppear { model.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: .lamitypeDictationEngineDidChange)) { _ in
            model.refresh()
        }
    }

    static func makeSettingsPane(
        onSwitchEngine: @escaping (AppConfig.DictationEngine) -> Void
    ) -> AppSettings.Pane<DictationPane> {
        let title = L10n.string("settings.tab.dictation", fallback: "Dictation")
        return AppSettings.Pane(
            identifier: .dictation,
            title: title,
            toolbarIcon: NSImage(
                systemSymbolName: "mic",
                accessibilityDescription: title
            )!
        ) {
            DictationPane(onSwitchEngine: onSwitchEngine)
        }
    }

    private var livePreview: some View {
        Toggle(isOn: Binding(
            get: { model.livePreviewEnabled },
            set: {
                model.requestLivePreviewEnabled($0, from: .settings(LamitypeSettingsWindowController.shared.reminderParentWindow))
            }
        )) {
            SettingLabel(
                title: L10n.string("settings.dictation.preview", fallback: "Live preview"),
                description: livePreviewDescription,
                badge: L10n.string("settings.dictation.experimental", fallback: "Experimental")
            )
        }
        .toggleStyle(.switch)
        .modifier(SettingsActiveTint())
        .disabled(!model.livePreviewCanChange)
        .accessibilityIdentifier("local-live-preview-toggle")
    }

    private var livePreviewDescription: String {
        if model.liveBusy {
            return L10n.string("live.settings.busy", fallback: "Finish or cancel live dictation before changing these settings.")
        }
        if !model.livePreviewCanChange {
            return L10n.string("live.cap_reminder.busy", fallback: "Finish the current action before changing live preview.")
        }
        return L10n.string("live.settings.detail", fallback: "Shows draft text while you speak. Stops after 60 seconds.")
    }

    private func cloudModelSection<Choices: View>(
        _ provider: String, selection: Binding<String>, @ViewBuilder choices: () -> Choices
    ) -> some View {
        Section {
            SettingRow(L10n.string("settings.dictation.model", fallback: "Model")) {
                Picker(L10n.string("settings.dictation.model", fallback: "Model"), selection: selection, content: choices)
                    .settingsPopup()
            }
        } header: {
            Text(provider)
        } footer: {
            SettingsNote(L10n.format(
                "settings.engine.cloud_unloads_local",
                "Audio goes directly to %1$@ with your key. The local model stays unloaded.",
                arguments: [provider]
            ))
        }
    }

    private func cloudRate(_ rate: Double) -> String {
        let formattedRate = L10n.format("format.usd_rate_per_minute", "$%1$.3f/min", arguments: [rate])
        return L10n.format("settings.engine.cloud.detail", "%1$@ · Your own key", arguments: [formattedRate])
    }
}
