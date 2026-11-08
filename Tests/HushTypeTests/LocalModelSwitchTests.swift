import XCTest
@testable import HushType

@MainActor
final class LocalModelSwitchTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var config: AppConfig!

    override func setUp() async throws {
        suiteName = "LocalModelSwitchTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        config = AppConfig.forUpgradeTesting(defaults: defaults)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testDefaultsToFast() {
        XCTAssertEqual(config.localModel, .fast)
        XCTAssertEqual(config.modelId, "aufklarer/Qwen3-ASR-0.6B-MLX-4bit")
    }

    func testModelIdFollowsChoiceAndLocalFolderOverride() {
        config.localModel = .optimized
        XCTAssertEqual(config.modelId, "felixfu824/Qwen3-ASR-0.6B-MLX-mixed-6-8bit")
        defaults.set("/tmp/optimized-model", forKey: "hushtype.optimizedModelPath")
        XCTAssertEqual(config.modelId, "/tmp/optimized-model")
        XCTAssertEqual(config.modelSource(for: .fast), "aufklarer/Qwen3-ASR-0.6B-MLX-4bit")
    }

    func testExplicitModelIdStillWins() {
        config.localModel = .optimized
        config.modelId = "custom/model"
        XCTAssertEqual(config.modelId, "custom/model")
    }

    func testUnknownStoredChoiceFallsBackToFast() {
        defaults.set("turbo", forKey: "hushtype.localModel")
        XCTAssertEqual(config.localModel, .fast)
    }

    func testWeightsOnDiskForLocalFolder() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("lamitype-model-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        XCTAssertFalse(LocalModelSwitcher.weightsOnDisk(source: folder.path))
        try Data([0]).write(to: folder.appendingPathComponent("model.safetensors"))
        XCTAssertTrue(LocalModelSwitcher.weightsOnDisk(source: folder.path))
        XCTAssertFalse(LocalModelSwitcher.weightsOnDisk(source: folder.appendingPathComponent("missing").path))
    }

    func testSelectWithoutLoadedModelSavesChoiceForNextLoad() {
        let switcher = LocalModelSwitcher(config: config)
        switcher.engine = Qwen3TranscriptionEngine()
        XCTAssertTrue(switcher.select(.optimized))
        XCTAssertEqual(switcher.active, .optimized)
        XCTAssertEqual(config.localModel, .optimized)
        XCTAssertEqual(switcher.phase, .idle)
    }

    func testSelectRefusedWhileBusy() {
        let switcher = LocalModelSwitcher(config: config)
        switcher.engine = Qwen3TranscriptionEngine()
        switcher.isBusy = { true }
        XCTAssertFalse(switcher.select(.optimized))
        XCTAssertEqual(switcher.active, .fast)
        XCTAssertEqual(config.localModel, .fast)
    }

    func testSelectingActiveModelIsNoOp() {
        let switcher = LocalModelSwitcher(config: config)
        switcher.isBusy = { true }
        XCTAssertTrue(switcher.select(.fast))
        XCTAssertEqual(switcher.phase, .idle)
        XCTAssertNil(switcher.statusText)
    }

    func testFallbackSourceOnlyForOptimizedWithoutOverride() {
        XCTAssertNil(config.fallbackModelSource)
        config.localModel = .optimized
        XCTAssertEqual(config.fallbackModelSource, "aufklarer/Qwen3-ASR-0.6B-MLX-4bit")
        config.modelId = "custom/model"
        XCTAssertNil(config.fallbackModelSource)
    }

    func testLoadFallbackShowsFailureAndKeepsSavedChoice() {
        config.localModel = .optimized
        let switcher = LocalModelSwitcher(config: config)
        XCTAssertEqual(switcher.active, .optimized)
        switcher.noteLoadFallback(failed: .optimized, using: .fast)
        XCTAssertEqual(switcher.active, .fast)
        XCTAssertEqual(switcher.shownSelection, .fast)
        XCTAssertEqual(switcher.phase, .failed(.optimized))
        XCTAssertNotNil(switcher.statusText)
        XCTAssertEqual(config.localModel, .optimized, "The next launch tries the saved model again")
    }

    func testChoosingModelInUseAfterFallbackSavesIt() {
        config.localModel = .optimized
        let switcher = LocalModelSwitcher(config: config)
        switcher.noteLoadFallback(failed: .optimized, using: .fast)
        XCTAssertTrue(switcher.select(.fast))
        XCTAssertEqual(switcher.phase, .idle)
        XCTAssertEqual(config.localModel, .fast)
    }

    func testEngineSwitchRequiresLoadedModel() async {
        let engine = Qwen3TranscriptionEngine()
        do {
            try await engine.switchModel(to: "unused/model")
            XCTFail("Expected notLoaded")
        } catch {
            XCTAssertEqual(error as? Qwen3TranscriptionEngine.SwitchError, .notLoaded)
        }
        XCTAssertNil(engine.loadedModelID)
    }

    func testDisplayNamesHaveNoLanguageClaims() {
        for model in AppConfig.LocalModel.allCases {
            for text in [model.displayName, model.shortName] {
                for word in ["Mandarin", "Taiwan", "accent", "English", "Chinese", "%"] {
                    XCTAssertFalse(text.contains(word), "\(text) mentions \(word)")
                }
            }
        }
    }
}
