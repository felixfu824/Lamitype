import Foundation
import XCTest
@testable import HushType

@MainActor
final class EvalStoreTests: XCTestCase {
    private var roots: [URL] = []

    override func tearDown() {
        for root in roots { try? FileManager.default.removeItem(at: root) }
        roots.removeAll()
        super.tearDown()
    }

    func testRoundTripPermissionsUpdateAndRerunCap() async throws {
        let (root, store) = makeStore()
        var entry = sampleEntry(id: "20260904-091422-3f9a1c2d")
        XCTAssertTrue(store.append(entry))
        await store.waitForPendingIO()

        let directoryMode = try permissions(root.appendingPathComponent("entries"))
        let file = root.appendingPathComponent("entries/\(entry.id).json")
        XCTAssertEqual(directoryMode, 0o700)
        XCTAssertEqual(try permissions(file), 0o600)
        XCTAssertEqual(store.bytesOnDisk, try allocatedSize(file))

        for index in 0..<12 {
            entry.appendRerun(EvalRerun(
                at: Date(timeIntervalSince1970: TimeInterval(1_700_000_000 + index)),
                instructions: "rule \(index)",
                output: "output \(index)",
                outcome: .polished,
                reason: nil,
                elapsedMS: index
            ))
        }
        entry.label = .wrongOrMissed
        try FileManager.default.removeItem(at: file)
        XCTAssertTrue(store.update(entry))
        // The backing file is absent here, so this assertion can only come from the in-place cache update.
        XCTAssertEqual(store.entries.first?.reruns.count, 10)
        XCTAssertEqual(store.entries.first?.label, .wrongOrMissed)
        await store.waitForPendingIO()

        let reloaded = EvalStore(directory: root)
        await reloaded.reload()
        XCTAssertEqual(reloaded.count, 1)
        XCTAssertEqual(reloaded.entries[0].id, entry.id)
        XCTAssertEqual(reloaded.entries[0].source, .dictation)
        XCTAssertEqual(reloaded.entries[0].appBundleID, "com.example.app")
        XCTAssertEqual(reloaded.entries[0].original, "original")
        XCTAssertEqual(reloaded.entries[0].output, "output")
        XCTAssertEqual(reloaded.entries[0].outcome, .polished)
        XCTAssertEqual(reloaded.entries[0].elapsedMS, 812)
        XCTAssertEqual(reloaded.entries[0].label, .wrongOrMissed)
        XCTAssertEqual(reloaded.entries[0].reruns.first?.instructions, "rule 2")
    }

    func testDeleteOldestDeleteAllAndCorruptSkip() async throws {
        let (root, store) = makeStore()
        XCTAssertTrue(store.append(sampleEntry(id: "old", at: 100)))
        XCTAssertTrue(store.append(sampleEntry(id: "middle", at: 200)))
        XCTAssertTrue(store.append(sampleEntry(id: "new", at: 300)))
        await store.waitForPendingIO()

        XCTAssertEqual(store.deleteOldest(2).map(\.id), ["old", "middle"])
        XCTAssertEqual(store.entries.map(\.id), ["new"])
        await store.waitForPendingIO()

        let corrupt = root.appendingPathComponent("entries/corrupt.json")
        try Data("not json".utf8).write(to: corrupt)
        await store.reload()
        XCTAssertEqual(store.entries.map(\.id), ["new"])

        XCTAssertEqual(store.delete(id: "new")?.id, "new")
        XCTAssertEqual(store.count, 0)
        XCTAssertEqual(store.bytesOnDisk, 0)
        XCTAssertTrue(store.append(sampleEntry(id: "again")))
        store.deleteAll()
        XCTAssertEqual(store.count, 0)
        XCTAssertEqual(store.bytesOnDisk, 0)
        await store.waitForPendingIO()
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(
            at: root.appendingPathComponent("entries"),
            includingPropertiesForKeys: nil
        ).isEmpty)
    }

    func testCapRefusesEntry501() async {
        let (_, store) = makeStore()
        for index in 0..<EvalStore.maximumEntries {
            XCTAssertTrue(store.append(sampleEntry(id: "entry-\(index)")))
        }
        XCTAssertTrue(store.isFull)
        XCTAssertFalse(store.append(sampleEntry(id: "entry-500")))
        XCTAssertEqual(store.count, 500)
        await store.waitForPendingIO()
    }

    private func makeStore() -> (URL, EvalStore) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("eval-store-tests-\(UUID().uuidString)", isDirectory: true)
        roots.append(root)
        return (root, EvalStore(directory: root))
    }

    private func sampleEntry(id: String, at: TimeInterval = 1_700_000_000) -> EvalEntry {
        EvalEntry(
            id: id,
            capturedAt: Date(timeIntervalSince1970: at),
            source: .dictation,
            appBundleID: "com.example.app",
            original: "original",
            output: "output",
            outcome: .polished,
            reason: nil,
            elapsedMS: 812,
            abandoned: false
        )
    }

    private func permissions(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    private func allocatedSize(_ url: URL) throws -> Int64 {
        let value = try url.resourceValues(forKeys: [.totalFileAllocatedSizeKey])
            .totalFileAllocatedSize
        return Int64(try XCTUnwrap(value))
    }
}
