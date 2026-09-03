import XCTest
@testable import HushType

final class AutoPolishExclusionCatalogTests: XCTestCase {
    func testOwnBundleRemovedAndDuplicatesKeepFirstName() {
        let groups = AutoPolishExclusionCatalog.groups(
            running: [
                .init(bundleID: "com.lamitype.app", name: "Lamitype"),
                .init(bundleID: "COM.EXAMPLE.NOTES", name: "First Notes"),
                .init(bundleID: "com.example.notes", name: "Second Notes"),
            ],
            excludedBundleIDs: [],
            ownBundleID: "COM.LAMITYPE.APP",
            resolveName: { _ in nil }
        )
        XCTAssertEqual(groups.running, [
            .init(bundleID: "com.example.notes", name: "First Notes")
        ])
    }

    func testRunningAppsSortCaseInsensitively() {
        let groups = AutoPolishExclusionCatalog.groups(
            running: [
                .init(bundleID: "z", name: "Zulu"),
                .init(bundleID: "a2", name: "alpha"),
                .init(bundleID: "a1", name: "Alpha"),
            ],
            excludedBundleIDs: [],
            ownBundleID: nil,
            resolveName: { _ in nil }
        )
        XCTAssertEqual(groups.running.map(\.bundleID), ["a1", "a2", "z"])
    }

    func testExcludedNotRunningUsesResolverAndBundleFallback() {
        let groups = AutoPolishExclusionCatalog.groups(
            running: [.init(bundleID: "com.example.running", name: "Running")],
            excludedBundleIDs: [
                "com.example.running", "com.example.resolved", "com.example.fallback"
            ],
            ownBundleID: nil,
            resolveName: { $0 == "com.example.resolved" ? "Resolved App" : nil }
        )
        XCTAssertEqual(groups.excludedNotRunning, [
            .init(bundleID: "com.example.fallback", name: "com.example.fallback"),
            .init(bundleID: "com.example.resolved", name: "Resolved App"),
        ])
        XCTAssertEqual(groups.running.map(\.bundleID), ["com.example.running"])
    }
}
