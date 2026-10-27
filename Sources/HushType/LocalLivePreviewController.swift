import AppKit

extension Notification.Name {
    static let localLivePreviewControlsChanged = Notification.Name("com.felix.hushtype.localLivePreviewControlsChanged")
}

/// Explicit user-action gate shared by Settings and the menu. Config reads,
/// refreshes and launch restoration never present this reminder. An explicit
/// first-use recording press confirms an unsaved default before capture.
@MainActor
final class LocalLivePreviewController {
    static let shared = LocalLivePreviewController()
    static let reminderVersion = 1

    enum Source { case menu, settings(NSWindow?) }
    struct Choice {
        let enable: Bool
        let dontShowAgain: Bool
        static let cancel = Choice(enable: false, dontShowAgain: false)
    }
    typealias Presenter = (NSWindow?, @escaping (Choice) -> Void) -> Void
    typealias Scheduler = (@escaping () -> Void) -> Void

    @MainActor private final class Request {
        let settings: Bool
        var selectLocal: (() -> Void)?
        var expectedEnabled = false
        var expectedExplicitChoice = true
        weak var host: NSWindow?
        init(_ source: Source) {
            switch source {
            case .menu: settings = false
            case .settings(let window): settings = true; host = window
            }
        }
        var hostIsValid: Bool { !settings || (host?.isVisible == true && host?.isMiniaturized == false) }
    }

    var activityIsIdle: () -> Bool
    private let isLocal: () -> Bool
    private let hasOwnershipWork: () -> Bool
    private let readEnabled: () -> Bool
    private let writeEnabled: (Bool) -> Void
    private let hasExplicitChoice: () -> Bool
    private let readAcknowledgement: () -> Int
    private let writeAcknowledgement: (Int) -> Void
    private let presenter: Presenter
    private let schedule: Scheduler
    private let presentationAllowed: (NSWindow?) -> Bool
    private let refresh: () -> Void
    private var pending: Request?

    init(
        activityIsIdle: @escaping () -> Bool = { false },
        isLocal: @escaping () -> Bool = { AppConfig.shared.dictationEngine == .local },
        hasOwnershipWork: (() -> Bool)? = nil,
        readEnabled: @escaping () -> Bool = { AppConfig.shared.localLivePreviewEnabled },
        writeEnabled: @escaping (Bool) -> Void = { AppConfig.shared.localLivePreviewEnabled = $0 },
        hasExplicitChoice: @escaping () -> Bool = { AppConfig.shared.hasExplicitLocalLiveChoice },
        readAcknowledgement: @escaping () -> Int = { AppConfig.shared.localLiveCapReminderAcknowledgedVersion },
        writeAcknowledgement: @escaping (Int) -> Void = { AppConfig.shared.localLiveCapReminderAcknowledgedVersion = $0 },
        presenter: Presenter? = nil,
        schedule: Scheduler? = nil,
        presentationAllowed: ((NSWindow?) -> Bool)? = nil,
        refresh: @escaping () -> Void = { NotificationCenter.default.post(name: .localLivePreviewControlsChanged, object: nil) }
    ) {
        self.activityIsIdle = activityIsIdle; self.isLocal = isLocal
        self.hasOwnershipWork = hasOwnershipWork ?? { LocalLiveOwnership.isBusy || LocalLiveOwnership.captionTransitions != 0 }
        self.readEnabled = readEnabled; self.writeEnabled = writeEnabled
        self.hasExplicitChoice = hasExplicitChoice
        self.readAcknowledgement = readAcknowledgement; self.writeAcknowledgement = writeAcknowledgement
        self.presenter = presenter ?? { LocalLiveCapReminderAlert.present(parent: $0, completion: $1) }
        self.schedule = schedule ?? { action in DispatchQueue.main.async(execute: action) }
        self.presentationAllowed = presentationAllowed ?? { host in
            NSApp.modalWindow == nil && host?.attachedSheet == nil && !NSApp.windows.contains { $0.attachedSheet != nil }
        }
        self.refresh = refresh
    }

    var isEnabled: Bool { readEnabled() }
    var isRequestPending: Bool { pending != nil }
    var needsDefaultConfirmation: Bool { readEnabled() && !hasExplicitChoice() }
    var reminderAlreadyAcknowledged: Bool { readAcknowledgement() == Self.reminderVersion }
    private var activityAllowsSelection: Bool { activityIsIdle() && !hasOwnershipWork() }
    private var activityAllowsChange: Bool { isLocal() && activityAllowsSelection }
    var canSelectMode: Bool { !isRequestPending && activityAllowsSelection && presentationAllowed(nil) }
    var canChange: Bool { isLocal() && canSelectMode }
    private func allows(_ request: Request) -> Bool {
        activityAllowsSelection && (request.selectLocal != nil || isLocal())
    }
    private func selectionUnchanged(_ request: Request) -> Bool {
        readEnabled() == request.expectedEnabled && hasExplicitChoice() == request.expectedExplicitChoice
    }

    static func availabilityDidChange() {
        // Observe the completed app/hotkey transition, not an intermediate state.
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .localLivePreviewControlsChanged, object: nil)
        }
    }

    func request(_ enabled: Bool, from source: Source) {
        request(enabled, from: source, selectLocal: nil)
    }

    /// A mode radio may enter Local from Cloud. Keep the old engine and mode
    /// untouched until the explicit reminder has been accepted.
    func requestLocalMode(_ enabled: Bool, selectLocal: @escaping () -> Void) {
        request(enabled, from: .menu, selectLocal: selectLocal)
    }

    private func request(_ enabled: Bool, from source: Source, selectLocal: (() -> Void)?) {
        guard canSelectMode, selectLocal != nil || isLocal() else { refresh(); return }
        if enabled == readEnabled(), !(enabled && needsDefaultConfirmation) { selectLocal?(); refresh(); return }
        if !enabled { writeEnabled(false); selectLocal?(); refresh(); return }
        if readAcknowledgement() == Self.reminderVersion {
            writeEnabled(true)
            if readEnabled() { selectLocal?() }
            refresh(); return
        }
        let request = Request(source)
        request.selectLocal = selectLocal
        request.expectedEnabled = readEnabled()
        request.expectedExplicitChoice = hasExplicitChoice()
        guard request.hostIsValid, presentationAllowed(request.host) else { refresh(); return }
        pending = request; refresh()
        schedule { [weak self, weak request] in
            guard let self, let request, self.pending === request else { return }
            guard self.allows(request), self.selectionUnchanged(request), request.hostIsValid,
                  self.presentationAllowed(request.host) else { self.finish(request); return }
            self.presenter(request.host) { [weak self, weak request] choice in
                guard let self, let request else { return }
                // Let the native sheet/modal finish detaching before checking
                // other modal ownership and committing the preference.
                self.schedule { [weak self, weak request] in
                    guard let self, let request, self.pending === request else { return }
                    if choice.enable, self.allows(request), self.selectionUnchanged(request),
                       request.hostIsValid, self.presentationAllowed(request.host) {
                        self.writeEnabled(true)
                        if self.readEnabled() {
                            if choice.dontShowAgain { self.writeAcknowledgement(Self.reminderVersion) }
                            request.selectLocal?()
                        }
                    }
                    self.finish(request)
                }
            }
        }
    }

    private func finish(_ request: Request) {
        guard pending === request else { return }
        pending = nil
        refresh() // Cancellation refreshes truth without writing OFF.
    }
}

@MainActor
enum LocalLiveCapReminderAlert {
    static let windowIdentifier = NSUserInterfaceItemIdentifier("local-live-cap-reminder")
    #if DEBUG
    static private(set) var currentForNativeTesting: NSAlert?
    #endif

    static func makeAlert() -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.icon = NSImage(named: "AppIcon") ?? NSApp.applicationIconImage
        alert.messageText = L10n.string("live.cap_reminder.title", fallback: "Live preview has a 60-second limit")
        alert.informativeText = L10n.string("live.cap_reminder.message", fallback: "Recording stops at 60 seconds, then Lamitype prepares the final text.\n\nFor longer uninterrupted recording, turn Live preview off.")
        alert.addButton(withTitle: L10n.string("live.cap_reminder.enable", fallback: "Enable Live Preview"))
        alert.addButton(withTitle: L10n.string("common.button.cancel", fallback: "Cancel"))
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = L10n.string("live.cap_reminder.dont_show", fallback: "Don’t show again")
        alert.suppressionButton?.state = .off
        alert.window.identifier = windowIdentifier
        return alert
    }

    static func present(parent: NSWindow?, completion: @escaping (LocalLivePreviewController.Choice) -> Void) {
        let alert = makeAlert()
        #if DEBUG
        currentForNativeTesting = alert
        #endif
        var completed = false
        var closeObserver: NSObjectProtocol?
        func finish(_ response: NSApplication.ModalResponse) {
            guard !completed else { return }
            completed = true
            if let observer = closeObserver {
                NotificationCenter.default.removeObserver(observer)
                closeObserver = nil
            }
            if let parent, parent.attachedSheet === alert.window { parent.endSheet(alert.window, returnCode: response) }
            alert.window.orderOut(nil)
            #if DEBUG
            currentForNativeTesting = nil
            #endif
            completion(.init(enable: response == .alertFirstButtonReturn, dontShowAgain: alert.suppressionButton?.state == .on))
        }
        if let parent {
            closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: parent, queue: .main) { _ in
                MainActor.assumeIsolated { finish(.alertSecondButtonReturn) }
            }
            alert.beginSheetModal(for: parent, completionHandler: finish)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            finish(alert.runModal())
        }
    }
}
