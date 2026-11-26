import AppKit
import AVFoundation
import ApplicationServices
import Combine

typealias SettingsPane = LamitypeSettingsWindowController.Pane

enum PaneStatus: Equatable {
    case ok(PaneStatusDetail)
    case attention(PaneStatusDetail)
}

enum PaneStatusDetail: Equatable {
    case permissionsGranted, needsAccessibility, needsMicrophone, needsBoth, microphoneRestricted
    case localModel(LocalModelKind)
    case cloudEngine(CloudProvider, hasKey: Bool)
    case captionOff, captionMicrophone, captionSystem(appName: String?)
    case keys(openAI: KeyState, gemini: KeyState)
    case polishAvailable, polishChecking, polishUnavailable
    case iosServerRunning, iosServerStopped
}

enum LocalModelKind: Equatable {
    case fast, optimized, custom(String)

    init(modelID: String) {
        switch modelID {
        case AppConfig.LocalModel.fast.huggingFaceID: self = .fast
        case AppConfig.LocalModel.optimized.huggingFaceID: self = .optimized
        default: self = .custom((modelID as NSString).lastPathComponent)
        }
    }
}

enum CloudProvider: Equatable {
    case openAI, gemini
}

enum KeyState: Equatable {
    case loaded, missing, unusualFormat
}

@MainActor
final class SettingsStatusModel: ObservableObject {
    struct Providers {
        var permissions: () -> (accessibility: Bool, microphone: AVAuthorizationStatus)
        var dictationEngine: () -> AppConfig.DictationEngine
        var localModel: () -> LocalModelKind
        var captionSource: () -> AudioSourceKind?
        var captionAppName: (String) -> String?
        var keyState: (CloudProvider) -> KeyState
        var polish: () -> (available: Bool, checking: Bool)
        var iosServerRunning: () -> Bool
    }

    static let shared: SettingsStatusModel = {
        let text = TextSettingsModel.shared
        let model = SettingsStatusModel(providers: Providers(
            permissions: { (AXIsProcessTrusted(), AVCaptureDevice.authorizationStatus(for: .audio)) },
            dictationEngine: { AppConfig.shared.dictationEngine },
            localModel: {
                let config = AppConfig.shared
                let configuredID = config.modelId
                let chosenID = config.modelSource(for: config.localModel)
                // A launch fallback may leave the stored choice different from the active model.
                let modelID = configuredID == chosenID
                    ? config.modelSource(for: LocalModelSwitcher.shared.active) : configuredID
                return LocalModelKind(modelID: modelID)
            },
            captionSource: { nil },
            captionAppName: {
                NSRunningApplication.runningApplications(withBundleIdentifier: $0).first?.localizedName
            },
            keyState: { provider in
                let url = switch provider {
                case .openAI: AppSupportPaths.openAIKeyFileURL
                case .gemini: AppSupportPaths.geminiKeyFileURL
                }
                return keyState(provider, at: url)
            },
            polish: { (text.polishAvailable, text.isValidatingPolish) },
            iosServerRunning: { LamitypeSettingsWindowController.shared.isIOSServerRunning?() ?? false }
        ))
        text.$polishAvailable.combineLatest(text.$isValidatingPolish)
            // Published values arrive before storage changes. Refresh on the next main-queue turn.
            .receive(on: DispatchQueue.main)
            .sink { [weak model] _ in model?.refresh(.text) }
            .store(in: &model.observations)
        return model
    }()

    @Published private(set) var status: [SettingsPane: PaneStatus] = [:]

    private static let panes: [SettingsPane] = [.general, .dictation, .caption, .text, .cloud, .ios]
    private var providers: Providers
    private var observations = Set<AnyCancellable>()

    init(providers: Providers, notifications: NotificationCenter = .default) {
        self.providers = providers
        refresh()

        notifications.publisher(for: NSApplication.didBecomeActiveNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &observations)

        for (name, pane) in [
            (Notification.Name.lamitypeDictationEngineDidChange, SettingsPane.dictation),
            (.lamitypeLocalModelDidChange, .dictation),
            (.iosServerStatusDidChange, .ios),
        ] {
            notifications.publisher(for: name)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.refresh(pane) }
                .store(in: &observations)
        }
    }

    func bindCaptionManager(_ manager: LiveCaptionManager) {
        providers.captionSource = { [weak manager] in
            guard let manager, manager.isActive else { return nil }
            return manager.currentSource
        }
        refresh(.caption)
    }

    func refresh() {
        let updated = Dictionary(uniqueKeysWithValues: Self.panes.compactMap { pane in
            status(for: pane).map { (pane, $0) }
        })
        if status != updated { status = updated }
    }

    func refresh(_ pane: SettingsPane) {
        guard let updated = status(for: pane), status[pane] != updated else { return }
        status[pane] = updated
    }

    private func status(for pane: SettingsPane) -> PaneStatus? {
        switch pane {
        case .general:
            let (accessibility, microphone) = providers.permissions()
            if microphone == .restricted { return .attention(.microphoneRestricted) }
            switch (accessibility, microphone == .authorized) {
            case (true, true): return .ok(.permissionsGranted)
            case (false, true): return .attention(.needsAccessibility)
            case (true, false): return .attention(.needsMicrophone)
            case (false, false): return .attention(.needsBoth)
            }
        case .dictation:
            switch providers.dictationEngine() {
            case .local: return .ok(.localModel(providers.localModel()))
            case .openai: return cloudEngineStatus(.openAI)
            case .gemini: return cloudEngineStatus(.gemini)
            }
        case .caption:
            switch providers.captionSource() {
            case nil: return .ok(.captionOff)
            case .mic: return .ok(.captionMicrophone)
            case .system(let bundleID): return .ok(.captionSystem(appName: providers.captionAppName(bundleID)))
            }
        case .text:
            let (available, checking) = providers.polish()
            if checking { return .ok(.polishChecking) }
            return available ? .ok(.polishAvailable) : .attention(.polishUnavailable)
        case .cloud:
            let openAI = providers.keyState(.openAI)
            let gemini = providers.keyState(.gemini)
            let detail = PaneStatusDetail.keys(openAI: openAI, gemini: gemini)
            return openAI == .loaded && gemini == .loaded ? .ok(detail) : .attention(detail)
        case .ios:
            return providers.iosServerRunning() ? .ok(.iosServerRunning) : .ok(.iosServerStopped)
        case .about:
            return nil
        }
    }

    private func cloudEngineStatus(_ provider: CloudProvider) -> PaneStatus {
        // Both stores let the engine use a nonempty key with an unusual prefix.
        let hasKey = providers.keyState(provider) != .missing
        let detail = PaneStatusDetail.cloudEngine(provider, hasKey: hasKey)
        return hasKey ? .ok(detail) : .attention(detail)
    }

    static func keyState(_ provider: CloudProvider, at url: URL) -> KeyState {
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
        switch provider {
        case .openAI:
            switch OpenAIKeyStore.readExisting(at: url) {
            case .ok: return .loaded
            case .empty: return .missing
            case .unusualFormat: return .unusualFormat
            }
        case .gemini:
            switch GeminiKeyStore.readExisting(at: url) {
            case .ok: return .loaded
            case .empty: return .missing
            case .unusualFormat: return .unusualFormat
            }
        }
    }
}
