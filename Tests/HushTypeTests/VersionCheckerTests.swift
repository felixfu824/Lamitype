import XCTest
@testable import HushType

/// Version parse/compare only; `VersionChecker.check()` hits the network and is
/// intentionally not exercised here.
final class VersionCheckerTests: XCTestCase {

    func testEqualVersions() {
        XCTAssertEqual(VersionChecker.compareVersions("0.4.1", "0.4.1"), 0)
    }

    func testOrderingPerComponent() {
        XCTAssertEqual(VersionChecker.compareVersions("0.4.1", "0.4.2"), -1)
        XCTAssertEqual(VersionChecker.compareVersions("0.5.0", "0.4.9"), 1)
        XCTAssertEqual(VersionChecker.compareVersions("1.0.0", "0.99.99"), 1)
    }

    func testComparesNumericallyNotLexicographically() {
        XCTAssertEqual(VersionChecker.compareVersions("0.10.0", "0.9.0"), 1)
        XCTAssertEqual(VersionChecker.compareVersions("0.9.0", "0.10.0"), -1)
    }

    func testShorterVersionIsZeroPadded() {
        XCTAssertEqual(VersionChecker.compareVersions("0.4", "0.4.0"), 0)
        XCTAssertEqual(VersionChecker.compareVersions("0.4", "0.4.1"), -1)
        XCTAssertEqual(VersionChecker.compareVersions("1", "0.9.9"), 1)
    }

    func testPrereleaseSuffixIsIgnored() {
        XCTAssertEqual(VersionChecker.compareVersions("0.4.1-beta", "0.4.1"), 0)
        XCTAssertEqual(VersionChecker.compareVersions("0.4.1-beta", "0.4.2"), -1)
    }

    func testNonNumericAndEmptyComponentsCountAsZero() {
        XCTAssertEqual(VersionChecker.compareVersions("", ""), 0)
        XCTAssertEqual(VersionChecker.compareVersions("", "0.0.1"), -1)
        XCTAssertEqual(VersionChecker.compareVersions("a.b", "0.0"), 0)
    }

    func testCompareIsAntisymmetric() {
        let versions = ["0.4", "0.4.1", "0.10.0", "1.0.0", "0.4.1-beta"]
        for a in versions {
            for b in versions {
                XCTAssertEqual(VersionChecker.compareVersions(a, b), -VersionChecker.compareVersions(b, a), "\(a) vs \(b)")
            }
        }
    }

    func testErrorDescriptions() {
        XCTAssertTrue(VersionChecker.CheckError.invalidResponse(status: 404).errorDescription?.contains("404") == true)
        XCTAssertFalse(VersionChecker.CheckError.malformedJSON.errorDescription?.isEmpty ?? true)
        XCTAssertFalse(VersionChecker.CheckError.missingTagName.errorDescription?.isEmpty ?? true)
    }
}
