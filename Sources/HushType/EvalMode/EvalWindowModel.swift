import AppKit
import Combine
import Foundation

@MainActor
final class EvalWindowModel: ObservableObject {
    enum OutcomeFilter: String, CaseIterable {
        case all, polished, unchanged, keptOriginal, notPolished
    }

    enum LabelFilter: String, CaseIterable {
        case all, correct, overEdited, wrongOrMissed, unlabelled
    }

    struct PendingDeletion {
        let entry: EvalEntry
        let previousSelection: String?
    }

    @Published private(set) var entries: [EvalEntry] = []
    @Published var selectedID: String?
    @Published var outcomeFilter: OutcomeFilter = .all {
        didSet { reconcileSelection() }
    }
    @Published var labelFilter: LabelFilter = .all {
        didSet { reconcileSelection() }
    }
    @Published private(set) var evalEnabled = AppConfig.shared.evalModeEnabled
    @Published private(set) var suppressedCount = EvalCapture.suppressedCount
    @Published var instructionsText = "" {
        didSet {
            promptSaveError = nil
            if instructionsText != PolishPrompt.systemPrompt { draftRestoresDefault = false }
        }
    }
    @Published private(set) var promptSaveError: String?
    @Published var promptEditorPresented = false
    @Published private(set) var pendingDeletion: PendingDeletion?
    @Published private(set) var rerunBusy = false
    @Published private(set) var batchProgress: (completed: Int, total: Int)?
    @Published private(set) var batchStoppedForDictation = false
    @Published private(set) var appIdle: Bool

    private let store: EvalStore
    private let isAppIdle: () -> Bool
    private let requestEvalEnabled: (Bool) -> Void
    private var undoTask: Task<Void, Never>?
    private var batchTask: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private var savedPromptSnapshot = ""
    private var draftRestoresDefault = false

    init(
        store: EvalStore? = nil,
        isAppIdle: @escaping () -> Bool,
        requestEvalEnabled: @escaping (Bool) -> Void
    ) {
        self.store = store ?? .shared
        self.isAppIdle = isAppIdle
        self.requestEvalEnabled = requestEvalEnabled
        appIdle = isAppIdle()
        entries = self.store.entries
        selectedID = entries.first?.id
        let prompt = PolishPrompt.effectivePromptSnapshot()
        instructionsText = prompt
        savedPromptSnapshot = prompt

        observers.append(NotificationCenter.default.addObserver(
            forName: .evalModeDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.evalEnabled = AppConfig.shared.evalModeEnabled
                self?.suppressedCount = EvalCapture.suppressedCount
            }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: .evalStoreDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.syncFromStore() }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: .evalAppActivityDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.appIdle = self.isAppIdle()
            }
        })
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
        undoTask?.cancel()
        batchTask?.cancel()
    }

    var filteredEntries: [EvalEntry] {
        entries.filter { entry in
            guard pendingDeletion?.entry.id != entry.id else { return false }
            let outcomeMatches: Bool
            switch outcomeFilter {
            case .all: outcomeMatches = true
            case .polished: outcomeMatches = entry.outcome == .polished
            case .unchanged: outcomeMatches = entry.outcome == .unchanged
            case .keptOriginal: outcomeMatches = entry.outcome == .keptOriginal
            case .notPolished: outcomeMatches = entry.outcome == .notPolished
            }
            let labelMatches: Bool
            switch labelFilter {
            case .all: labelMatches = true
            case .correct: labelMatches = entry.label == .correct
            case .overEdited: labelMatches = entry.label == .overEdited
            case .wrongOrMissed: labelMatches = entry.label == .wrongOrMissed
            case .unlabelled: labelMatches = entry.label == nil
            }
            return outcomeMatches && labelMatches
        }
    }

    var selectedEntry: EvalEntry? {
        guard let selectedID else { return nil }
        return filteredEntries.first { $0.id == selectedID }
    }

    var labelledCounts: (correct: Int, overEdited: Int, wrongOrMissed: Int, unlabelled: Int) {
        (
            entries.filter { $0.label == .correct }.count,
            entries.filter { $0.label == .overEdited }.count,
            entries.filter { $0.label == .wrongOrMissed }.count,
            entries.filter { $0.label == nil }.count
        )
    }

    var rerunUnavailableReason: String? {
        guard CleanupPromptOverride.parseFullPrompt(contents: instructionsText) != nil else {
            return L10n.string(
                "eval.rerun.empty_prompt",
                fallback: "Enter a prompt before rerunning."
            )
        }
        guard appIdle else {
            return L10n.string(
                "eval.rerun.busy",
                fallback: "Paused while dictation or polish is running."
            )
        }
        guard TextPolisher.isAvailableCached else {
            return L10n.format(
                "eval.rerun.unavailable",
                "Rerun needs Apple Intelligence: %1$@",
                arguments: [TextPolisher.unavailableReasonCached]
            )
        }
        return nil
    }

    func open() async {
        await store.reload()
        syncFromStore()
        appIdle = isAppIdle()
        refreshPromptDraftIfClean()
    }

    func close() {
        commitPendingDelete()
        batchTask?.cancel()
    }

    var hasUnsavedPromptDraft: Bool {
        instructionsText != savedPromptSnapshot || draftRestoresDefault
    }

    func showPromptEditor() {
        refreshPromptDraftIfClean()
        promptEditorPresented = true
    }

    func requestClosePromptEditor() {
        promptEditorPresented = false
    }

    func confirmWindowClose() -> Bool {
        confirmDiscardPromptDraftIfNeeded()
    }

    func toggleEvalMode() {
        requestEvalEnabled(!evalEnabled)
    }

    func setLabel(_ label: EvalLabel?) {
        guard var entry = selectedEntry else { return }
        entry.label = entry.label == label ? nil : label
        store.update(entry)
        syncFromStore()
    }

    func deleteSelected() {
        guard let entry = selectedEntry else { return }
        commitPendingDelete()
        pendingDeletion = PendingDeletion(entry: entry, previousSelection: selectedID)
        selectedID = filteredEntries.first?.id
        undoTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }
            self?.commitPendingDelete()
        }
    }

    func undoDelete() {
        undoTask?.cancel()
        undoTask = nil
        if let pendingDeletion {
            selectedID = pendingDeletion.previousSelection
        }
        pendingDeletion = nil
        reconcileSelection()
    }

    func commitPendingDelete() {
        undoTask?.cancel()
        undoTask = nil
        guard let pendingDeletion else { return }
        _ = store.delete(id: pendingDeletion.entry.id)
        self.pendingDeletion = nil
        syncFromStore()
    }

    func rerunSelected() {
        guard let id = selectedEntry?.id, !rerunBusy, rerunUnavailableReason == nil else { return }
        let promptSnapshot = instructionsText
        batchStoppedForDictation = false
        rerunBusy = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.rerun(entryID: id, prompt: promptSnapshot)
            self.rerunBusy = false
        }
    }

    func rerunShown() {
        guard !rerunBusy, rerunUnavailableReason == nil else { return }
        let ids = filteredEntries.prefix(50).map(\.id)
        guard !ids.isEmpty else { return }
        batchTask?.cancel()
        rerunBusy = true
        batchStoppedForDictation = false
        batchProgress = (0, ids.count)
        let promptSnapshot = instructionsText
        batchTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for (index, id) in ids.enumerated() {
                guard !Task.isCancelled else { break }
                guard self.isAppIdle() else {
                    self.batchStoppedForDictation = true
                    break
                }
                await self.rerun(entryID: id, prompt: promptSnapshot)
                self.batchProgress = (index + 1, ids.count)
                guard self.isAppIdle() else {
                    self.batchStoppedForDictation = true
                    break
                }
            }
            self.batchProgress = nil
            self.rerunBusy = false
            self.batchTask = nil
        }
    }

    func cancelBatch() {
        batchTask?.cancel()
        // The current AFM response is not necessarily cancellation-aware.
        // Keep the batch busy until its task exits so a second batch cannot be
        // started and then have its state cleared by this older task.
    }

    @discardableResult
    func savePrompt() -> Bool {
        do {
            if draftRestoresDefault && instructionsText == PolishPrompt.systemPrompt {
                try PolishPrompt.restoreDefaultPrompt()
            } else {
                try PolishPrompt.saveCompletePrompt(instructionsText)
            }
            savedPromptSnapshot = PolishPrompt.effectivePromptSnapshot()
            instructionsText = savedPromptSnapshot
            draftRestoresDefault = false
            promptSaveError = nil
            if #available(macOS 26.0, *) { FoundationModelsPolisher.promptDidChange() }
            return true
        } catch {
            promptSaveError = error.localizedDescription
            return false
        }
    }

    func restoreDefaultDraft() {
        instructionsText = PolishPrompt.systemPrompt
        draftRestoresDefault = true
        promptSaveError = nil
    }

    func exportShown() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "lamitype-eval-cases-\(Self.exportDate()).json"
        guard panel.runModal() == .OK, let casesURL = panel.url else { return }
        do {
            let files = try EvalExport.makeFiles(
                entries: filteredEntries,
                appVersion: Bundle.main.object(
                    forInfoDictionaryKey: "CFBundleShortVersionString"
                ) as? String ?? "unknown"
            )
            try EvalExport.writeFiles(files, casesURL: casesURL)
        } catch {
            presentError(error)
        }
    }

    func revealInFinder() {
        store.ensureDirectories()
        NSWorkspace.shared.activateFileViewerSelecting([AppSupportPaths.evalDirectoryURL])
    }

    func deleteOldest100() {
        let alert = NSAlert()
        alert.messageText = L10n.string(
            "eval.delete_oldest.confirm",
            fallback: "Delete the oldest 100 entries? This cannot be undone."
        )
        alert.addButton(withTitle: L10n.string("eval.delete_oldest", fallback: "Delete Oldest 100"))
        alert.addButton(withTitle: L10n.string("common.button.cancel", fallback: "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        commitPendingDelete()
        _ = store.deleteOldest(100)
        syncFromStore()
    }

    func deleteAll() {
        let countText = L10n.plural(
            "eval.entries_count",
            store.count,
            fallback: "%ld entries"
        )
        let size = ByteCountFormatter.string(fromByteCount: store.bytesOnDisk, countStyle: .file)
        let alert = NSAlert()
        alert.messageText = L10n.format(
            "eval.delete_all.confirm",
            "Delete %1$@ (%2$@)? This cannot be undone.",
            arguments: [countText, size]
        )
        alert.addButton(withTitle: L10n.string("eval.delete_all.button", fallback: "Delete"))
        alert.addButton(withTitle: L10n.string("common.button.cancel", fallback: "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        pendingDeletion = nil
        store.deleteAll()
        syncFromStore()
    }

    private func rerun(entryID: String, prompt: String) async {
        guard var entry = entries.first(where: { $0.id == entryID }) else { return }
        let started = Date()
        let result = await TextPolisher.rerun(
            entry.original,
            instructions: prompt,
            budget: entry.source.rerunBudget
        )
        let elapsed = Int((Date().timeIntervalSince(started) * 1_000).rounded())
        let rerun: EvalRerun
        switch result {
        case .success(let output, let changed):
            rerun = EvalRerun(
                at: Date(),
                instructions: prompt,
                output: changed ? output : entry.original,
                outcome: changed ? .polished : .unchanged,
                reason: nil,
                elapsedMS: elapsed
            )
        case .failure(let error):
            rerun = EvalRerun(
                at: Date(),
                instructions: prompt,
                output: entry.original,
                outcome: .keptOriginal,
                reason: error.stableToken,
                elapsedMS: elapsed
            )
        }
        entry.appendRerun(rerun)
        store.update(entry)
        syncFromStore()
    }

    private func presentError(_ error: Error) {
        NSAlert(error: error).runModal()
    }

    private func refreshPromptDraftIfClean() {
        guard !hasUnsavedPromptDraft else { return }
        let current = PolishPrompt.effectivePromptSnapshot()
        savedPromptSnapshot = current
        instructionsText = current
        draftRestoresDefault = false
    }

    private func confirmDiscardPromptDraftIfNeeded() -> Bool {
        guard hasUnsavedPromptDraft else { return true }
        let alert = NSAlert()
        alert.messageText = L10n.string(
            "eval.prompt.unsaved.title",
            fallback: "Discard unsaved prompt changes?"
        )
        alert.informativeText = L10n.string(
            "eval.prompt.unsaved.body",
            fallback: "Your draft has not been saved and will be lost."
        )
        alert.addButton(withTitle: L10n.string("eval.prompt.keep_editing", fallback: "Keep Editing"))
        alert.addButton(withTitle: L10n.string("eval.prompt.discard", fallback: "Discard"))
        return alert.runModal() == .alertSecondButtonReturn
    }

    private func syncFromStore() {
        entries = store.entries
        evalEnabled = AppConfig.shared.evalModeEnabled
        suppressedCount = EvalCapture.suppressedCount
        reconcileSelection()
    }

    private func reconcileSelection() {
        if selectedEntry == nil {
            selectedID = filteredEntries.first?.id
        }
    }

    private static func exportDate() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }
}
