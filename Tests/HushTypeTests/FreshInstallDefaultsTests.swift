import Foundation
import XCTest
@testable import HushType

/// First launch decides the defaults profile once: a fresh install gets
/// Optimized with standard (non-live) local dictation and Auto Polish off; an
/// upgrade keeps the earlier defaults (Fast, Live preview on).
@MainActor
final class FreshInstallDefaultsTests: XCTestCase {
    private let noPriorInstall: () -> Bool = { false }

    private func withStore(
        _ values: [String: Any], fastOnDisk: Bool = false,
        _ body: (AppConfig, UserDefaults, String) throws -> Void
    ) throws {
        let suite = try TestDefaultsSuite(prefix: "com.felix.lamitype.fresh-install-test")
        defer { suite.destroy() }
        if !values.isEmpty { suite.defaults.setPersistentDomain(values, forName: suite.name) }
        let config = AppConfig.forUpgradeTesting(
            defaults: suite.defaults, domainName: suite.name, weightsOnDisk: { _ in fastOnDisk })
        try body(config, suite.defaults, suite.name)
    }

    func testFreshInstallGetsOptimizedStandardDictationAndNoAutoPolish() throws {
        try withStore([:]) { config, store, _ in
            XCTAssertTrue(config.stampFreshInstallDefaultsIfNeeded(priorInstallOnDisk: noPriorInstall))
            XCTAssertTrue(config.usesFreshInstallDefaults)
            XCTAssertEqual(config.localModel, .optimized)
            XCTAssertEqual(config.modelId, AppConfig.LocalModel.optimized.huggingFaceID)
            XCTAssertNil(config.fallbackModelSource, "no silent second download on a fresh Mac")
            XCTAssertEqual(config.dictationEngine, .local)
            XCTAssertFalse(config.localLivePreviewEnabled)
            XCTAssertFalse(config.hasExplicitLocalLiveChoice, "the default is not a user choice")
            XCTAssertFalse(config.autoPolishDictationEnabled)
            // Only the profile stamp is written; the defaults stay defaults.
            XCTAssertNil(store.object(forKey: "hushtype.localModel"))
            XCTAssertNil(store.object(forKey: "hushtype.localLivePreviewEnabled"))
            XCTAssertNil(store.object(forKey: "hushtype.autoPolishDictationEnabled"))
            // Later launches see a stamped store and do not restamp.
            let reopened = AppConfig.forUpgradeTesting(defaults: store, domainName: nil)
            XCTAssertTrue(reopened.usesFreshInstallDefaults)
            XCTAssertEqual(reopened.localModel, .optimized)
        }
    }

    func testUpgradeKeepsFastAndLivePreviewDefaults() throws {
        for prior: [String: Any] in [
            ["hushtype.onboardingCompleted": true],
            ["hushtype.interfaceLanguage": "zh-Hant-TW", "hushtype.numberConversionEnabled": false],
        ] {
            try withStore(prior) { config, store, domain in
                XCTAssertFalse(config.stampFreshInstallDefaultsIfNeeded(priorInstallOnDisk: noPriorInstall))
                XCTAssertFalse(config.usesFreshInstallDefaults)
                XCTAssertEqual(config.localModel, .fast)
                XCTAssertNil(config.fallbackModelSource)
                XCTAssertTrue(config.localLivePreviewEnabled)
                XCTAssertFalse(config.autoPolishDictationEnabled)
                XCTAssertTrue(NSDictionary(dictionary: store.persistentDomain(forName: domain)!).isEqual(to: prior),
                              "an upgrade must not write anything")
            }
        }
    }

    func testExplicitChoicesWinOverEitherProfile() throws {
        for stamped in [false, true] {
            var values: [String: Any] = ["hushtype.localModel": "fast", "hushtype.localLivePreviewEnabled": true,
                                         "hushtype.autoPolishDictationEnabled": true]
            if stamped { values["hushtype.defaultsProfile"] = AppConfig.freshInstallDefaultsProfile }
            try withStore(values) { config, _, _ in
                XCTAssertFalse(config.stampFreshInstallDefaultsIfNeeded(priorInstallOnDisk: noPriorInstall))
                XCTAssertEqual(config.localModel, .fast)
                XCTAssertTrue(config.localLivePreviewEnabled)
                XCTAssertTrue(config.autoPolishDictationEnabled)
            }
        }
    }

    func testAnyStoredKeyMarksAnUpgrade() throws {
        // Older releases could run without writing a `hushtype.` key (trusted
        // Accessibility skipped onboarding), but AppKit and the app still
        // stored other keys.
        try withStore(["NSStatusItem Preferred Position Item-0": 812.0]) { config, store, domain in
            XCTAssertFalse(config.stampFreshInstallDefaultsIfNeeded(priorInstallOnDisk: noPriorInstall))
            XCTAssertEqual(config.localModel, .fast)
            XCTAssertTrue(config.localLivePreviewEnabled)
            XCTAssertNil(store.persistentDomain(forName: domain)?["hushtype.defaultsProfile"])
        }
    }

    func testPriorInstallOnDiskMarksAnUpgradeWithAnEmptyDomain() throws {
        // App-support data or a Fast weight cache from an earlier release.
        try withStore([:]) { config, store, domain in
            XCTAssertFalse(config.stampFreshInstallDefaultsIfNeeded(priorInstallOnDisk: { true }))
            XCTAssertFalse(config.usesFreshInstallDefaults)
            XCTAssertEqual(config.localModel, .fast)
            XCTAssertTrue(config.localLivePreviewEnabled)
            XCTAssertNil(store.persistentDomain(forName: domain), "an upgrade must not write anything")
        }
    }

    func testFreshInstallFallsBackOnlyToAFastCacheAlreadyOnDisk() throws {
        try withStore([:], fastOnDisk: true) { config, _, _ in
            XCTAssertTrue(config.stampFreshInstallDefaultsIfNeeded(priorInstallOnDisk: noPriorInstall))
            XCTAssertEqual(config.fallbackModelSource, AppConfig.LocalModel.fast.huggingFaceID)
        }
        // Upgrades keep the reviewed fallback, cached or not.
        try withStore(["hushtype.localModel": "optimized"], fastOnDisk: false) { config, _, _ in
            XCTAssertEqual(config.fallbackModelSource, AppConfig.LocalModel.fast.huggingFaceID)
        }
    }
}
