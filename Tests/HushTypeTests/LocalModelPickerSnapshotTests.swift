import AppKit
import SwiftUI
import XCTest
@testable import HushType

/// Opt-in: renders the Settings › Dictation "Local model" row in every state,
/// in English and Traditional Chinese, to PNGs. Uses an offscreen window that
/// is never ordered front.
///
///     LAMITYPE_SNAPSHOT_DIR=<dir> swift test --disable-sandbox --filter LocalModelPickerSnapshotTests
@MainActor
final class LocalModelPickerSnapshotTests: XCTestCase {
    func testRenderAllStates() throws {
        guard let dir = ProcessInfo.processInfo.environment["LAMITYPE_SNAPSHOT_DIR"] else {
            throw XCTSkip("Set LAMITYPE_SNAPSHOT_DIR to render the Local model row")
        }
        let out = URL(fileURLWithPath: dir, isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let savedLanguage = AppConfig.shared.interfaceLanguageRaw
        defer {
            AppConfig.shared.interfaceLanguageRaw = savedLanguage
            L10n.resetLaunchStateForTests()
        }

        for language in ["en", "zh-Hant-TW"] {
            AppConfig.shared.interfaceLanguageRaw = language
            L10n.resetLaunchStateForTests()
            let suite = "LocalModelPickerSnapshot-\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let switcher = LocalModelSwitcher(config: AppConfig.forUpgradeTesting(defaults: defaults))

            try render(switcher, enabled: true, name: "\(language)_1_fast_active", into: out)
            switcher.setPhaseForTesting(.switching(to: .optimized, downloading: true, progress: 0.336))
            try render(switcher, enabled: true, name: "\(language)_2_downloading", into: out)
            switcher.setPhaseForTesting(.switching(to: .optimized, downloading: true, progress: 0.9))
            try render(switcher, enabled: true, name: "\(language)_3_loading", into: out)
            switcher.setPhaseForTesting(.failed(.optimized))
            try render(switcher, enabled: true, name: "\(language)_4_failed", into: out)
            switcher.setPhaseForTesting(.idle)
            XCTAssertTrue(switcher.select(.optimized))
            try render(switcher, enabled: true, name: "\(language)_5_optimized_active", into: out)
            try render(switcher, enabled: false, name: "\(language)_6_cloud_engine_dimmed", into: out)
        }
    }

    private func render(_ switcher: LocalModelSwitcher, enabled: Bool, name: String, into dir: URL) throws {
        let row = SettingsRow(L10n.string("settings.dictation.local_model", fallback: "Local model:")) {
            LocalModelPicker(switcher: switcher, enabled: enabled)
        }
        .padding(20)
        .frame(width: 640, alignment: .leading)
        .background(Color(nsColor: .windowBackgroundColor))

        let host = NSHostingView(rootView: row)
        host.appearance = NSAppearance(named: .aqua)
        let size = host.fittingSize
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try png.write(to: dir.appendingPathComponent("\(name).png"))
        window.contentView = nil
    }
}
