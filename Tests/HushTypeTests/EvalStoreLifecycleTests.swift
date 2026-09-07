import Foundation
import XCTest
@testable import HushType

@MainActor
final class EvalStoreLifecycleTests: XCTestCase {
    private var roots: [URL] = []

    override func tearDown() {
        roots.forEach { try? FileManager.default.removeItem(at: $0) }
        roots.removeAll()
        super.tearDown()
    }

    func testNormalTerminationClearsManagedDataAndRejectsLateWrites() async throws {
        let support = makeRoot()
        let managed = support.appendingPathComponent("eval.noindex", isDirectory: true)
        let store = EvalStore(directory: managed)
        var entry = sampleEntry(id: "active")
        XCTAssertTrue(store.append(entry))

        XCTAssertTrue(store.endSessionAndClear())
        XCTAssertFalse(store.acceptsWrites)
        XCTAssertEqual(store.count, 0)
        XCTAssertEqual(store.bytesOnDisk, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: managed.appendingPathComponent("entries").path))

        entry.label = .correct
        XCTAssertFalse(store.append(sampleEntry(id: "late-append")))
        XCTAssertFalse(store.update(entry))
        await store.waitForPendingIO()
        XCTAssertFalse(FileManager.default.fileExists(atPath: managed.appendingPathComponent("entries").path))
        XCTAssertEqual(store.count, 0)
    }

    func testNextLaunchClearsOrphanedSessionButPreservesSiblingFiles() async throws {
        let support = makeRoot()
        let managed = support.appendingPathComponent("eval.noindex", isDirectory: true)
        let oldStore = EvalStore(directory: managed)
        XCTAssertTrue(oldStore.append(sampleEntry(id: "orphan")))
        await oldStore.waitForPendingIO()
        let corruptEntry = managed.appendingPathComponent("entries/corrupt.json")
        try Data("not valid Eval JSON".utf8).write(to: corruptEntry)

        let prompt = support.appendingPathComponent("polish_prompt_custom.txt")
        let export = support.appendingPathComponent("user-export.json")
        let exportInsideEvalRoot = managed.appendingPathComponent("manual-export.json")
        try "# Saved prompt".write(to: prompt, atomically: true, encoding: .utf8)
        try "exported data".write(to: export, atomically: true, encoding: .utf8)
        try "manual export".write(to: exportInsideEvalRoot, atomically: true, encoding: .utf8)

        let relaunched = EvalStore(directory: managed)
        XCTAssertTrue(relaunched.beginNewSessionClearingOrphans())
        await relaunched.reload()
        XCTAssertTrue(relaunched.acceptsWrites)
        XCTAssertEqual(relaunched.count, 0)
        XCTAssertEqual(relaunched.bytesOnDisk, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: corruptEntry.path))
        XCTAssertEqual(try String(contentsOf: prompt, encoding: .utf8), "# Saved prompt")
        XCTAssertEqual(try String(contentsOf: export, encoding: .utf8), "exported data")
        XCTAssertEqual(
            try String(contentsOf: exportInsideEvalRoot, encoding: .utf8),
            "manual export"
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: managed.appendingPathComponent("entries").path))
    }

    func testStartupCleanupReplacesMalformedManagedPath() async throws {
        let support = makeRoot()
        let managed = support.appendingPathComponent("eval.noindex")
        try Data("malformed managed data".utf8).write(to: managed)

        let store = EvalStore(directory: managed)
        XCTAssertFalse(store.acceptsWrites)
        XCTAssertTrue(store.beginNewSessionClearingOrphans())
        await store.reload()
        XCTAssertTrue(store.acceptsWrites)
        XCTAssertTrue(store.entries.isEmpty)
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: managed.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
    }

    func testStartupCleanupReplacesMalformedEntriesAndPreservesRootExport() throws {
        let support = makeRoot()
        let managed = support.appendingPathComponent("eval.noindex", isDirectory: true)
        try FileManager.default.createDirectory(at: managed, withIntermediateDirectories: true)
        let malformedEntries = managed.appendingPathComponent("entries")
        let export = managed.appendingPathComponent("manual-export.json")
        try Data("not a directory".utf8).write(to: malformedEntries)
        try "keep me".write(to: export, atomically: true, encoding: .utf8)

        let store = EvalStore(directory: managed)
        XCTAssertFalse(store.acceptsWrites)
        XCTAssertTrue(store.beginNewSessionClearingOrphans())
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: malformedEntries.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
        XCTAssertEqual(try String(contentsOf: export, encoding: .utf8), "keep me")
    }

    func testUnrecoverableStartupPreparationFailsClosed() async throws {
        let support = makeRoot()
        let blockingFile = support.appendingPathComponent("not-a-directory")
        try Data("block".utf8).write(to: blockingFile)
        let impossibleManaged = blockingFile.appendingPathComponent("eval.noindex")
        let store = EvalStore(directory: impossibleManaged)

        XCTAssertFalse(store.beginNewSessionClearingOrphans())
        XCTAssertFalse(store.acceptsWrites)
        XCTAssertFalse(store.append(sampleEntry(id: "must-not-write")))
        await store.reload()
        XCTAssertEqual(store.count, 0)
        XCTAssertEqual(store.bytesOnDisk, 0)
        XCTAssertEqual(try String(contentsOf: blockingFile, encoding: .utf8), "block")
    }

    func testSymlinkedEvalRootFailsClosedAndPreservesExternalEntries() async throws {
        let support = makeRoot()
        let external = makeRoot()
        let externalEntries = external.appendingPathComponent("entries", isDirectory: true)
        try FileManager.default.createDirectory(at: externalEntries, withIntermediateDirectories: true)
        let sentinel = externalEntries.appendingPathComponent("sentinel.json")
        try "external sentinel".write(to: sentinel, atomically: true, encoding: .utf8)
        let managedLink = support.appendingPathComponent("eval.noindex")
        try FileManager.default.createSymbolicLink(at: managedLink, withDestinationURL: external)

        let store = EvalStore(directory: managedLink)
        XCTAssertFalse(store.acceptsWrites)
        XCTAssertFalse(store.beginNewSessionClearingOrphans())
        XCTAssertFalse(store.append(sampleEntry(id: "escape")))
        await store.reload()
        XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "external sentinel")
        XCTAssertTrue(FileManager.default.fileExists(atPath: managedLink.path))
    }

    func testSymlinkedEntriesFailsClosedBeforePreparationOrRuntimeWrite() async throws {
        let support = makeRoot()
        let managed = support.appendingPathComponent("eval.noindex", isDirectory: true)
        let external = makeRoot()
        try FileManager.default.createDirectory(at: managed, withIntermediateDirectories: true)
        let sentinel = external.appendingPathComponent("sentinel.json")
        try "external sentinel".write(to: sentinel, atomically: true, encoding: .utf8)
        let entriesLink = managed.appendingPathComponent("entries")
        try FileManager.default.createSymbolicLink(at: entriesLink, withDestinationURL: external)

        let linkedAtInit = EvalStore(directory: managed)
        XCTAssertFalse(linkedAtInit.acceptsWrites)
        XCTAssertFalse(linkedAtInit.beginNewSessionClearingOrphans())
        XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "external sentinel")

        try FileManager.default.removeItem(at: entriesLink)
        let swappedAfterInit = EvalStore(directory: managed)
        XCTAssertTrue(swappedAfterInit.acceptsWrites)
        try FileManager.default.removeItem(at: entriesLink)
        try FileManager.default.createSymbolicLink(at: entriesLink, withDestinationURL: external)
        XCTAssertFalse(swappedAfterInit.append(sampleEntry(id: "runtime-escape")))
        XCTAssertFalse(swappedAfterInit.acceptsWrites)
        await swappedAfterInit.reload()
        XCTAssertEqual(swappedAfterInit.count, 0)
        XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "external sentinel")
    }

    private func makeRoot() -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("eval-lifecycle-\(UUID().uuidString)", isDirectory: true)
        roots.append(root)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func sampleEntry(id: String) -> EvalEntry {
        EvalEntry(
            id: id,
            source: .dictation,
            appBundleID: "com.example.lifecycle",
            original: "original",
            output: "output",
            outcome: .polished,
            reason: nil,
            elapsedMS: 10,
            abandoned: false
        )
    }
}
