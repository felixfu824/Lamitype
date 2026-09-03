import AppKit
import Combine
import Foundation

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
            writeTranslationTarget: { AppConfig.shared.translateTargetLanguage = $0 }
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
        },
        openInstructions: {
            Task { @MainActor in TextSettingsModel.openInstructionsFile() }
        }
    )

    @Published private(set) var polishEnabled: Bool
    @Published private(set) var autoPolishEnabled: Bool
    @Published private(set) var excludedBundleIDs: [String]
    @Published private(set) var polishAvailable: Bool
    @Published private(set) var isValidatingPolish = false
    @Published private(set) var translationEnabled: Bool
    @Published private(set) var translationTarget: String?

    /// The status-bar controller uses this callback to refresh its native
    /// menu items. SwiftUI observes the published properties directly.
    var onMenuRefresh: (() -> Void)?

    private let storage: Storage
    private let validatePolish: () async -> TextPolisher.ValidationResult
    private let warmupPolish: () -> Void
    private let releasePolish: () -> Void
    private let presentUnavailable: (String) -> Void
    private let openInstructions: () -> Void

    init(
        storage: Storage,
        initialPolishAvailability: Bool,
        validatePolish: @escaping () async -> TextPolisher.ValidationResult,
        warmupPolish: @escaping () -> Void,
        releasePolish: @escaping () -> Void,
        presentUnavailable: @escaping (String) -> Void,
        openInstructions: @escaping () -> Void
    ) {
        self.storage = storage
        self.validatePolish = validatePolish
        self.warmupPolish = warmupPolish
        self.releasePolish = releasePolish
        self.presentUnavailable = presentUnavailable
        self.openInstructions = openInstructions
        polishEnabled = storage.readPolishEnabled()
        autoPolishEnabled = storage.readAutoPolishEnabled()
        excludedBundleIDs = AutoPolishPolicy.normalizedUnique(storage.readExcludedBundleIDs())
        polishAvailable = initialPolishAvailability
        translationEnabled = storage.readTranslationEnabled()
        translationTarget = storage.readTranslationTarget()
    }

    func refreshFromConfig(polishAvailability: Bool? = nil) {
        polishEnabled = storage.readPolishEnabled()
        autoPolishEnabled = storage.readAutoPolishEnabled()
        excludedBundleIDs = AutoPolishPolicy.normalizedUnique(storage.readExcludedBundleIDs())
        translationEnabled = storage.readTranslationEnabled()
        translationTarget = storage.readTranslationTarget()
        if let polishAvailability {
            polishAvailable = polishAvailability
        }
        onMenuRefresh?()
    }

    func refreshPolishAvailability(_ available: Bool) {
        polishAvailable = available
        onMenuRefresh?()
    }

    func togglePolish() {
        Task { @MainActor in await setPolishEnabled(!polishEnabled) }
    }

    func requestPolishEnabled(_ enabled: Bool) {
        Task { @MainActor in await setPolishEnabled(enabled) }
    }

    func setPolishEnabled(_ enabled: Bool) async {
        guard enabled != polishEnabled || (enabled && !polishAvailable) else {
            return
        }

        if !enabled {
            storage.writePolishEnabled(false)
            polishEnabled = false
            isValidatingPolish = false
            if !autoPolishEnabled { releasePolish() }
            onMenuRefresh?()
            return
        }

        isValidatingPolish = true
        onMenuRefresh?()
        let result = await validatePolish()
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
        guard enabled != autoPolishEnabled || (enabled && !polishAvailable) else {
            return
        }

        if !enabled {
            storage.writeAutoPolishEnabled(false)
            autoPolishEnabled = false
            isValidatingPolish = false
            if !polishEnabled { releasePolish() }
            onMenuRefresh?()
            return
        }

        isValidatingPolish = true
        onMenuRefresh?()
        let result = await validatePolish()
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
        openInstructions()
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

    @MainActor
    private static func openInstructionsFile() {
        PolishPrompt.createRulesTemplateIfMissing()
        let url = PolishPrompt.rulesFileURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            let alert = NSAlert()
            alert.messageText = L10n.string(
                "alert.file_create.polish.title",
                fallback: "Could not open Polish instructions"
            )
            alert.informativeText = L10n.format(
                "alert.file_create.polish.message",
                "Failed to create the instructions file at:\n%1$@",
                arguments: [url.path]
            )
            alert.alertStyle = .warning
            alert.addButton(withTitle: L10n.string("common.button.ok", fallback: "OK"))
            alert.runModal()
            return
        }
        NSWorkspace.shared.open(url)
    }
}
