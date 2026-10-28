import Foundation
import CryptoKit
import XCTest
@testable import HushType

/// Serialized prior-release profiles, interpreted through production config and
/// migration code. Every defaults suite/file tree is disposable and synthetic.
@MainActor
final class UpgradeCompatibilityTests: XCTestCase {
    private let modelID = "aufklarer/Qwen3-ASR-0.6B-MLX-4bit"
    private func profile(version: String, engine: String?, indicator: Bool?) -> [String: Any] {
        var values: [String: Any] = [
            "fixture.priorRelease": version, "hushtype.modelId": modelID,
            "hushtype.language": "zh", "hushtype.interfaceLanguage": "zh-Hant-TW",
            "hushtype.chineseConversionEnabled": false, "hushtype.numberConversionEnabled": false,
            "hushtype.onboardingCompleted": true, "hushtype.textPolishEnabled": true,
            "hushtype.autoPolishDictationEnabled": true,
            "hushtype.autoPolishExcludedBundleIDs": ["com.example.private-editor"],
            "hushtype.cloudDictationModelOpenAI": "gpt-transcribe",
            "hushtype.cloudDictationModelGemini": "gemini-3.7-flash",
            "hushtype.cloudDailyCapDollars": 7.5, "hushtype.cloudOnboardingShown": true,
            "fixture.unknownLegacyKey": "preserve me"
        ]
        if let engine { values["hushtype.dictationEngine"] = engine }
        if let indicator { values["hushtype.floatingOverlayEnabled"] = indicator }
        return values
    }
    private func withStore(_ values: [String: Any], _ body: (AppConfig, UserDefaults, String) throws -> Void) throws {
        let suite = try TestDefaultsSuite(prefix: "com.felix.lamitype.upgrade-test")
        defer { suite.destroy() }
        let domain = suite.name
        let store = suite.defaults
        let data = try PropertyListSerialization.data(fromPropertyList: values, format: .binary, options: 0)
        let decoded = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        store.setPersistentDomain(decoded, forName: domain)
        try body(AppConfig.forUpgradeTesting(defaults: store), store, domain)
    }
    func testPriorReleaseProfileMatrixPreservesChoicesAndDefaultsLiveOn() throws {
        for version in ["v0.5.13", "v0.5.14"] {
            for engine: String? in [nil, "local", "openai", "gemini"] {
                for indicator: Bool? in [nil, false, true] {
                    let values = profile(version: version, engine: engine, indicator: indicator)
                    try withStore(values) { config, store, domain in
                        XCTAssertEqual(config.dictationEngine.rawValue, engine ?? "local")
                        XCTAssertEqual(config.floatingOverlayEnabled, indicator ?? true)
                        XCTAssertTrue(config.localLivePreviewEnabled, "new default must be ON")
                        XCTAssertFalse(config.hasExplicitLocalLiveChoice)
                        XCTAssertEqual(config.localLiveCapReminderAcknowledgedVersion, 0)
                        XCTAssertEqual(config.modelId, modelID)
                        XCTAssertEqual(config.language, "zh")
                        XCTAssertEqual(config.interfaceLanguageRaw, "zh-Hant-TW")
                        XCTAssertFalse(config.chineseConversionEnabled)
                        XCTAssertFalse(config.numberConversionEnabled)
                        XCTAssertTrue(config.onboardingCompleted)
                        XCTAssertTrue(config.textPolishEnabled)
                        XCTAssertTrue(config.autoPolishDictationEnabled)
                        XCTAssertEqual(config.autoPolishExcludedBundleIDs, ["com.example.private-editor"])
                        XCTAssertEqual(config.cloudDictationModelOpenAI, "gpt-transcribe")
                        XCTAssertEqual(config.cloudDictationModelGemini, "gemini-3.7-flash")
                        XCTAssertEqual(config.cloudDailyCapDollars, 7.5)
                        XCTAssertTrue(config.cloudOnboardingShown)
                        XCTAssertFalse(config.liveCaptionEnabled)
                        XCTAssertEqual(config.liveCaptionEngine, .local)
                        XCTAssertTrue(NSDictionary(dictionary: store.persistentDomain(forName: domain)!).isEqual(to: values), "reads must not rewrite prior settings")
                    }
                }
            }
        }
    }
    func testExplicitStandardAndLiveChoicesSurviveReopen() throws {
        for enabled in [false, true] {
            var values = profile(version: "post-upgrade", engine: "local", indicator: false)
            values["hushtype.localLivePreviewEnabled"] = enabled
            values["hushtype.localLiveCapReminderAcknowledgedVersion"] = 1
            try withStore(values) { config, store, _ in
                XCTAssertTrue(config.hasExplicitLocalLiveChoice)
                XCTAssertEqual(config.localLivePreviewEnabled, enabled)
                let reopened = AppConfig.forUpgradeTesting(defaults: store)
                XCTAssertEqual(reopened.localLivePreviewEnabled, enabled)
                XCTAssertEqual(reopened.localLiveCapReminderAcknowledgedVersion, 1)
            }
        }
    }
    func testMinimalOldProfileDoesNotInventConsentOrOverwriteInvalidLegacyChoice() throws {
        try withStore(["hushtype.onboardingCompleted": true, "hushtype.dictationEngine": "retired-value"]) { config, store, _ in
            XCTAssertEqual(config.dictationEngine, .local)
            XCTAssertEqual(store.string(forKey: "hushtype.dictationEngine"), "retired-value")
            XCTAssertTrue(config.localLivePreviewEnabled)
            XCTAssertFalse(config.hasExplicitLocalLiveChoice)
            XCTAssertFalse(config.cloudOnboardingShown)
            XCTAssertFalse(config.liveCaptionEnabled)
            XCTAssertEqual(config.modelId, modelID)
            XCTAssertNil(store.object(forKey: "hushtype.localLivePreviewEnabled"))
        }
    }
    private func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    func testPriorReleaseSupportAssetsAndExternalModelCacheSurviveMigration() throws {
        for version in ["v0.5.13", "v0.5.14"] {
            for legacyOnly in [false, true] {
                let root = FileManager.default.temporaryDirectory.appendingPathComponent("lamitype-upgrade-" + UUID().uuidString)
                defer { try? FileManager.default.removeItem(at: root) }
                let paths = AppSupportMigrator.productionRoots(in: root.appendingPathComponent("Application Support"))
                let source = legacyOnly ? paths.old : paths.new
                let files = ["openai.json": "{\"api_key\":\"NOT-A-REAL-KEY-openai\"}",
                    "gemini.json": "{\"api_key\":\"NOT-A-REAL-KEY-gemini\"}",
                    "dictionary.txt": "QN -> Qwen\n", "polish_prompt.txt": "Keep both languages.",
                    "polish_rules.txt": "Keep names unchanged.", "live_caption.json": "{\"mlxCacheLimitMB\":1024}",
                    "exports/keep.txt": "Explicit user export " + version, "unknown/nested.bin": "unrecognized extension must survive"]
                for (path, text) in files {
                    let url = source.appendingPathComponent(path)
                    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try Data(text.utf8).write(to: url)
                }
                let cache = root.appendingPathComponent("Caches/qwen3-speech/models/" + modelID + "/sentinel.safetensors")
                try FileManager.default.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
                let cached = Data("synthetic cached model sentinel".utf8); try cached.write(to: cache)
                for _ in 0..<2 {
                    XCTAssertEqual(try AppSupportMigrator.migrate(oldRoot: paths.old, newRoot: paths.new).get(), paths.new.standardizedFileURL)
                    for (path, text) in files {
                        XCTAssertEqual(hash(try Data(contentsOf: paths.new.appendingPathComponent(path))), hash(Data(text.utf8)))
                    }
                    XCTAssertEqual(hash(try Data(contentsOf: cache)), hash(cached))
                }
            }
        }
    }
}
