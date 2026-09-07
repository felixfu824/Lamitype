import AppKit
import Combine
import Foundation

@MainActor
final class TextSettingsModel: ObservableObject {
    struct Storage {
        var readPolishEnabled: () -> Bool
        var writePolishEnabled: (Bool) -> Void
        var readAutoPolishEnabled: () -> Bool
        var writeAutoPolishEnabled: (Bool) -> Void
        var readExcludedBundleIDs: () -> [String]
        var writeExcludedBundleIDs: ([String]) -> Void
        var readTranslationEnabled: () -> Bool
        var writeTranslationEnabled: (Bool) -> Void
        var readTranslationTarget: () -> String?
        var writeTranslationTarget: (String?) -> Void
        var readEvalCount: @MainActor () -> Int
        var readEvalBytes: @MainActor () -> Int64
        var deleteAllEval: @MainActor () -> Void
        var revealEval: @MainActor () -> Void
        var showEvalWindow: @MainActor (Bool) -> Void

        static let app = Storage(
            readPolishEnabled: { AppConfig.shared.textPolishEnabled },
            writePolishEnabled: { AppConfig.shared.textPolishEnabled = $0 },
            readAutoPolishEnabled: { AppConfig.shared.autoPolishDictationEnabled },
            writeAutoPolishEnabled: { AppConfig.shared.autoPolishDictationEnabled = $0 },
            readExcludedBundleIDs: { AppConfig.shared.autoPolishExcludedBundleIDs },
            writeExcludedBundleIDs: { AppConfig.shared.autoPolishExcludedBundleIDs = $0 },
            readTranslationEnabled: { AppConfig.shared.textTranslationEnabled },
            writeTranslationEnabled: { AppConfig.shared.textTranslationEnabled = $0 },
            readTranslationTarget: { AppConfig.shared.translateTargetLanguage },
            writeTranslationTarget: { AppConfig.shared.translateTargetLanguage = $0 },
            readEvalCount: { EvalStore.shared.count },
            readEvalBytes: { EvalStore.shared.bytesOnDisk },
            deleteAllEval: { EvalStore.shared.deleteAll() },
            revealEval: {
                EvalStore.shared.ensureDirectories()
                NSWorkspace.shared.activateFileViewerSelecting([AppSupportPaths.evalDirectoryURL])
            },
            showEvalWindow: { focusPromptEditor in
                NotificationCenter.default.post(
                    name: .evalShowWindowRequested,
                    object: nil,
                    userInfo: ["focusPromptEditor": focusPromptEditor]
                )
            }
        )
    }

    static let shared = TextSettingsModel(
        storage: .app,
        initialPolishAvailability: TextPolisher.isAvailableCached,
        validatePolish: { await TextPolisher.validate() },
        warmupPolish: {
            if #available(macOS 26.0, *) {
                Task { @MainActor in FoundationModelsPolisher.warmup() }
            }
        },
        releasePolish: {
            if #available(macOS 26.0, *) {
                Task { @MainActor in FoundationModelsPolisher.releaseSession() }
            }
        },
        presentUnavailable: { reason in
            Task { @MainActor in TextSettingsModel.showUnavailableAlert(reason: reason) }
        }
    )

    @Published private(set) var polishEnabled: Bool
    @Published private(set) var autoPolishEnabled: Bool
    @Published private(set) var excludedBundleIDs: [String]
    @Published private(set) var polishAvailable: Bool
    @Published private(set) var isValidatingPolish = false
    @Published private(set) var translationEnabled: Bool
    @Published private(set) var translationTarget: String?
    @Published private(set) var evalCount: Int
    @Published private(set) var evalBytes: Int64

    /// The status-bar controller uses this callback to refresh its native
    /// menu items. SwiftUI observes the published properties directly.
    var onMenuRefresh: (() -> Void)?

    private let storage: Storage
    private let validatePolish: () async -> TextPolisher.ValidationResult
    private let warmupPolish: () -> Void
    private let releasePolish: () -> Void
    private let presentUnavailable: (String) -> Void
    private var polishValidationGeneration: UInt = 0

    init(
        storage: Storage,
        initialPolishAvailability: Bool,
        validatePolish: @escaping () async -> TextPolisher.ValidationResult,
        warmupPolish: @escaping () -> Void,
        releasePolish: @escaping () -> Void,
        presentUnavailable: @escaping (String) -> Void
    ) {
        self.storage = storage
        self.validatePolish = validatePolish
        self.warmupPolish = warmupPolish
        self.releasePolish = releasePolish
        self.presentUnavailable = presentUnavailable
        let savedPolishEnabled = storage.readPolishEnabled()
        let savedAutoPolishEnabled = storage.readAutoPolishEnabled()
        polishEnabled = savedPolishEnabled
        autoPolishEnabled = savedPolishEnabled && savedAutoPolishEnabled
        if !savedPolishEnabled && savedAutoPolishEnabled {
            storage.writeAutoPolishEnabled(false)
        }
        excludedBundleIDs = AutoPolishPolicy.normalizedUnique(storage.readExcludedBundleIDs())
        polishAvailable = initialPolishAvailability
        translationEnabled = storage.readTranslationEnabled()
        translationTarget = storage.readTranslationTarget()
        evalCount = storage.readEvalCount()
        evalBytes = storage.readEvalBytes()
    }

    func refreshFromConfig(polishAvailability: Bool? = nil) {
        let savedPolishEnabled = storage.readPolishEnabled()
        let savedAutoPolishEnabled = storage.readAutoPolishEnabled()
        polishEnabled = savedPolishEnabled
        autoPolishEnabled = savedPolishEnabled && savedAutoPolishEnabled
        if !savedPolishEnabled && savedAutoPolishEnabled {
            storage.writeAutoPolishEnabled(false)
        }
        excludedBundleIDs = AutoPolishPolicy.normalizedUnique(storage.readExcludedBundleIDs())
        translationEnabled = storage.readTranslationEnabled()
        translationTarget = storage.readTranslationTarget()
        refreshEvalData()
        if let polishAvailability {
            polishAvailable = polishAvailability
        }
        onMenuRefresh?()
    }

    func refreshPolishAvailability(_ available: Bool) {
        if !available && isValidatingPolish {
            polishValidationGeneration &+= 1
            isValidatingPolish = false
        }
        polishAvailable = available
        onMenuRefresh?()
    }

    func togglePolish() {
        Task { @MainActor in await setPolishEnabled(!polishEnabled) }
    }

    func toggleAutoPolish() {
        Task { @MainActor in await setAutoPolishEnabled(!autoPolishEnabled) }
    }

    func requestPolishEnabled(_ enabled: Bool) {
        Task { @MainActor in await setPolishEnabled(enabled) }
    }

    func setPolishEnabled(_ enabled: Bool) async {
        guard enabled != polishEnabled
                || isValidatingPolish
                || (enabled && !polishAvailable) else {
            return
        }

        if !enabled {
            polishValidationGeneration &+= 1
            storage.writePolishEnabled(false)
            storage.writeAutoPolishEnabled(false)
            polishEnabled = false
            autoPolishEnabled = false
            isValidatingPolish = false
            releasePolish()
            onMenuRefresh?()
            return
        }

        polishValidationGeneration &+= 1
        let generation = polishValidationGeneration
        isValidatingPolish = true
        onMenuRefresh?()
        let result = await validatePolish()
        guard generation == polishValidationGeneration else { return }
        isValidatingPolish = false

        switch result {
        case .ok:
            storage.writePolishEnabled(true)
            polishEnabled = true
            polishAvailable = true
            warmupPolish()
        case .unavailable(let reason):
            polishAvailable = false
            presentUnavailable(reason)
        }
        onMenuRefresh?()
    }

    func requestAutoPolishEnabled(_ enabled: Bool) {
        Task { @MainActor in await setAutoPolishEnabled(enabled) }
    }

    func setAutoPolishEnabled(_ enabled: Bool) async {
        guard enabled != autoPolishEnabled
                || isValidatingPolish
                || (enabled && !polishAvailable) else {
            return
        }

        if !enabled {
            polishValidationGeneration &+= 1
            storage.writeAutoPolishEnabled(false)
            autoPolishEnabled = false
            isValidatingPolish = false
            if !polishEnabled { releasePolish() }
            onMenuRefresh?()
            return
        }

        guard polishEnabled else {
            storage.writeAutoPolishEnabled(false)
            autoPolishEnabled = false
            onMenuRefresh?()
            return
        }

        polishValidationGeneration &+= 1
        let generation = polishValidationGeneration
        isValidatingPolish = true
        onMenuRefresh?()
        let result = await validatePolish()
        guard generation == polishValidationGeneration,
              polishEnabled else { return }
        isValidatingPolish = false

        switch result {
        case .ok:
            storage.writeAutoPolishEnabled(true)
            autoPolishEnabled = true
            polishAvailable = true
            warmupPolish()
        case .unavailable(let reason):
            polishAvailable = false
            presentUnavailable(reason)
        }
        onMenuRefresh?()
    }

    func setExcluded(_ bundleID: String, excluded: Bool) {
        let normalized = AutoPolishPolicy.normalize(bundleID)
        guard !normalized.isEmpty else { return }
        var values = AutoPolishPolicy.normalizedUnique(excludedBundleIDs)
        if excluded {
            if !values.contains(normalized) { values.append(normalized) }
        } else {
            values.removeAll { $0 == normalized }
        }
        storage.writeExcludedBundleIDs(values)
        excludedBundleIDs = values
    }

    func removeExcluded(_ bundleID: String) {
        setExcluded(bundleID, excluded: false)
    }

    func toggleTranslation() {
        setTranslationEnabled(!translationEnabled)
    }

    func setTranslationEnabled(_ enabled: Bool) {
        storage.writeTranslationEnabled(enabled)
        translationEnabled = enabled
        onMenuRefresh?()
    }

    func setTranslationTarget(_ target: String?) {
        storage.writeTranslationTarget(target)
        translationTarget = target
        onMenuRefresh?()
    }

    func editPolishInstructions() {
        storage.showEvalWindow(true)
    }

    func refreshEvalData() {
        evalCount = storage.readEvalCount()
        evalBytes = storage.readEvalBytes()
    }

    func showEvalWindow() {
        storage.showEvalWindow(false)
    }

    func revealEvalData() {
        storage.revealEval()
    }

    func deleteAllEvalData() {
        storage.deleteAllEval()
        refreshEvalData()
    }

    @MainActor
    private static func showUnavailableAlert(reason: String) {
        let alert = NSAlert()
        alert.messageText = L10n.string(
            "alert.text_polish.unavailable.title",
            fallback: "Text Polish unavailable"
        )
        alert.informativeText = L10n.format(
            "alert.text_polish.unavailable.message",
            "Text Polish requires macOS 26 + Apple Intelligence.\n\n%1$@",
            arguments: [reason]
        )
        alert.alertStyle = .warning
        alert.icon = NSImage(named: "AppIcon")
            ?? NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)
        alert.addButton(withTitle: L10n.string("common.button.ok", fallback: "OK"))
        alert.runModal()
    }
}
