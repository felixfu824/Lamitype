import Foundation
import XCTest
@testable import HushType

@MainActor
final class EvalWindowSelectionTests: XCTestCase {
    func testPromptEditorWorksWithEmptyStoreAndBlankDraftCannotRerun() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        AppSupportPaths.resetForTesting()
        AppSupportPaths.configure(root: root)
        defer {
            AppSupportPaths.resetForTesting()
            try? FileManager.default.removeItem(at: root)
        }
        let store = EvalStore(directory: root.appendingPathComponent("eval.noindex"))
        let model = EvalWindowModel(store: store, isAppIdle: { true }, requestEvalEnabled: { _ in })
        await model.open()
        XCTAssertTrue(model.entries.isEmpty)
        model.showPromptEditor()
        XCTAssertTrue(model.promptEditorPresented)
        XCTAssertFalse(model.hasUnsavedPromptDraft)
        model.instructionsText = " \n\t"
        XCTAssertTrue(model.hasUnsavedPromptDraft)
        XCTAssertNotNil(model.rerunUnavailableReason)
        model.requestClosePromptEditor()
        XCTAssertFalse(model.promptEditorPresented)
        XCTAssertEqual(model.instructionsText, " \n\t", "Done must preserve the draft for a later rerun")
    }

    func testFiltersMoveSelectionAndPreventHiddenEntryActions() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        AppSupportPaths.resetForTesting()
        AppSupportPaths.configure(root: root)
        defer {
            AppSupportPaths.resetForTesting()
            try? FileManager.default.removeItem(at: root)
        }
        let store = EvalStore(directory: root.appendingPathComponent("eval.noindex"))
        for (id, outcome, label) in [("changed", EvalOutcome.polished, EvalLabel.correct),
                                     ("same", EvalOutcome.unchanged, EvalLabel.wrongOrMissed)] {
            XCTAssertTrue(store.append(EvalEntry(
                id: id, source: .polishService, appBundleID: "com.example.test",
                original: "Synthetic fixture", output: "Synthetic fixture",
                outcome: outcome, reason: nil, elapsedMS: 1, abandoned: false, label: label
            )))
        }
        await store.waitForPendingIO()
        let model = EvalWindowModel(store: store, isAppIdle: { true }, requestEvalEnabled: { _ in })
        await model.open()
        model.selectedID = "changed"
        model.outcomeFilter = .unchanged
        XCTAssertEqual(model.selectedEntry?.id, "same")
        model.labelFilter = .correct
        XCTAssertTrue(model.filteredEntries.isEmpty)
        XCTAssertNil(model.selectedID)
        XCTAssertNil(model.selectedEntry)
        model.setLabel(.overEdited)
        model.deleteSelected()
        XCTAssertNil(model.pendingDeletion)
        XCTAssertEqual(store.count, 2)
        XCTAssertEqual(store.entries.first { $0.id == "same" }?.label, .wrongOrMissed)
        model.labelFilter = .all
        XCTAssertEqual(model.selectedEntry?.id, "same")
        model.close()
        await store.waitForPendingIO()
    }

    func testRelabellingAndUndoKeepSelectionInsideFilters() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        AppSupportPaths.resetForTesting()
        AppSupportPaths.configure(root: root)
        defer {
            AppSupportPaths.resetForTesting()
            try? FileManager.default.removeItem(at: root)
        }
        let store = EvalStore(directory: root.appendingPathComponent("eval.noindex"))
        XCTAssertTrue(store.append(EvalEntry(
            id: "entry", source: .dictation, appBundleID: "com.example.test",
            original: "Synthetic fixture", output: "Synthetic fixture",
            outcome: .unchanged, reason: nil, elapsedMS: 1, abandoned: false
        )))
        await store.waitForPendingIO()
        let model = EvalWindowModel(store: store, isAppIdle: { true }, requestEvalEnabled: { _ in })
        await model.open()
        model.labelFilter = .unlabelled
        model.setLabel(.correct)
        XCTAssertNil(model.selectedEntry)
        model.labelFilter = .all
        XCTAssertEqual(model.selectedEntry?.label, .correct)
        model.deleteSelected()
        XCTAssertNil(model.selectedEntry)
        model.undoDelete()
        XCTAssertEqual(model.selectedEntry?.id, "entry")
        model.deleteSelected()
        model.outcomeFilter = .polished
        model.undoDelete()
        XCTAssertNil(model.selectedEntry)
        XCTAssertNil(model.selectedID)
        XCTAssertEqual(store.count, 1)
        model.close()
        await store.waitForPendingIO()
    }
}
