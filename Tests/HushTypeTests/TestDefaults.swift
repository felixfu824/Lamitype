import Foundation
import XCTest

/// A throwaway `UserDefaults` suite for tests that leaves nothing behind in
/// `~/Library/Preferences`.
///
/// Why not a plain `UserDefaults(suiteName: "some.name")`: even after
/// `removePersistentDomain(forName:)`, macOS leaves an empty ~42-byte
/// `~/Library/Preferences/<suite>.plist`. cfprefsd writes that file
/// asynchronously (4-6 s after the call, and it recreates the file if you
/// delete it earlier), so deleting it from the test is a race that cannot be
/// won without multi-second waits.
///
/// Instead the suite name is an absolute path inside a per-suite temporary
/// directory. CFPreferences stores such a domain at `<path>.plist`, so the file
/// never touches `~/Library/Preferences`, and `destroy()` can delete the whole
/// directory (verified: nothing is recreated afterwards).
///
/// Usage in an `XCTestCase`:
///     let suite = try makeTestDefaultsSuite(prefix: "Lamitype-MyTests")
///     let defaults = suite.defaults   // torn down automatically
/// or, when a suite is created repeatedly inside one test:
///     let suite = try TestDefaultsSuite(prefix: "...")
///     defer { suite.destroy() }
/// Code that needs the domain name (e.g. `persistentDomain(forName:)` or a
/// second `UserDefaults(suiteName:)` handle) should use `suite.name`.
final class TestDefaultsSuite {
    /// Domain name; an absolute path (without the `.plist` extension).
    let name: String
    let defaults: UserDefaults
    private let directory: URL
    private var destroyed = false

    init(prefix: String) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix).\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = directory.appendingPathComponent("defaults").path
        guard let defaults = UserDefaults(suiteName: name) else {
            try? FileManager.default.removeItem(at: directory)
            throw NSError(domain: "TestDefaultsSuite", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Could not create UserDefaults suite \(name)"])
        }
        self.directory = directory
        self.name = name
        self.defaults = defaults
    }

    /// Where CFPreferences persists this suite.
    var plistURL: URL { URL(fileURLWithPath: name + ".plist") }

    /// Removes the domain and deletes its backing directory. Idempotent; safe to
    /// call from `defer` and again from a teardown block.
    func destroy() {
        guard !destroyed else { return }
        destroyed = true
        defaults.removePersistentDomain(forName: name)
        defaults.synchronize()
        CFPreferencesAppSynchronize(name as CFString)
        try? FileManager.default.removeItem(at: directory)
    }

    deinit { destroy() }
}

extension XCTestCase {
    /// Creates an isolated defaults suite that is destroyed when the test ends.
    func makeTestDefaultsSuite(prefix: String) throws -> TestDefaultsSuite {
        let suite = try TestDefaultsSuite(prefix: prefix)
        addTeardownBlock { suite.destroy() }
        return suite
    }
}

final class TestDefaultsSuiteTests: XCTestCase {
    func testSuiteRoundTripsAndDestroyLeavesNoFiles() throws {
        let suite = try TestDefaultsSuite(prefix: "Lamitype-TestDefaultsSuiteTests")
        let uniqueDirectoryName = URL(fileURLWithPath: suite.name).deletingLastPathComponent().lastPathComponent
        suite.defaults.set("value", forKey: "key")
        XCTAssertEqual(suite.defaults.string(forKey: "key"), "value")
        XCTAssertEqual(suite.defaults.persistentDomain(forName: suite.name)?["key"] as? String, "value")
        XCTAssertTrue(FileManager.default.fileExists(atPath: suite.plistURL.path))

        suite.destroy()
        suite.destroy() // idempotent
        XCTAssertNil(suite.defaults.string(forKey: "key"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: suite.plistURL.path))

        let prefs = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Preferences")
        let leaked = (try? FileManager.default.contentsOfDirectory(atPath: prefs.path))?
            .filter { $0.contains(uniqueDirectoryName) } ?? []
        XCTAssertEqual(leaked, [], "suite leaked into ~/Library/Preferences")
    }
}
