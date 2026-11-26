import AppKit
import CoreText
import SwiftUI
import XCTest
@testable import HushType

/// Opt-in: renders every Settings pane, in English and Traditional Chinese,
/// in light and dark appearances to PNGs and checks the grouped forms for scrolling.
/// The rendering window stays offscreen.
///
///     LAMITYPE_SNAPSHOT_DIR=<dir> /usr/bin/lockf -k /tmp/lamitype-swift.lock swift test --disable-sandbox -j 4 --filter SettingsPanesSnapshotTests
@MainActor
final class SettingsPanesSnapshotTests: XCTestCase {
    func testRenderAllPanes() throws {
        let environment = ProcessInfo.processInfo.environment
        let shortcutsDirectory = environment["LAMITYPE_SHORTCUT_SNAPSHOT_DIR"]
        guard let dir = shortcutsDirectory ?? environment["LAMITYPE_SNAPSHOT_DIR"] else {
            throw XCTSkip("Set LAMITYPE_SNAPSHOT_DIR to render the Settings panes")
        }
        let out = URL(fileURLWithPath: dir, isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SettingsPanesSnapshot-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        AppSupportPaths.resetForTesting()
        AppSupportPaths.configure(root: root)
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let plistData = try Data(contentsOf: sourceRoot.appendingPathComponent("Resources/Info.plist"))
        let bundleInfo = try XCTUnwrap(PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any])
        let icon = NSImage(contentsOf: sourceRoot.appendingPathComponent("Resources/Lamitype.png"))
        let registeredIcon = icon?.setName("AppIcon") ?? false
        let fontURL = sourceRoot.appendingPathComponent("Resources/Fonts/Fraunces.ttf") as CFURL
        var fontError: Unmanaged<CFError>?
        let registeredFont = CTFontManagerRegisterFontsForURL(fontURL, .process, &fontError)
        let font = CTFontCreateWithName("Fraunces-9ptBlack" as CFString, 36, nil)
        XCTAssertEqual(CTFontCopyPostScriptName(font) as String, "Fraunces-9ptBlack",
                       "Fraunces was unavailable: \(String(describing: fontError?.takeRetainedValue()))")

        let defaults = UserDefaults.standard
        let keys = ["hushtype.interfaceLanguage", "hushtype.dictationEngine", "hushtype.textPolishEnabled",
                    "hushtype.autoPolishDictationEnabled", "hushtype.textTranslationEnabled",
                    "hushtype.numberConversionEnabled", "hushtype.punctuationMode",
                    "hushtype.localModel", "hushtype.modelId", "hushtype.localLivePreviewEnabled"]
        let savedPreferences = keys.compactMap { key in defaults.object(forKey: key).map { (key, $0) } }
        let config = AppConfig.shared
        config.dictationEngine = environment["LAMITYPE_SNAPSHOT_ENGINE"]
            .flatMap(AppConfig.DictationEngine.init(rawValue:)) ?? .local
        config.textPolishEnabled = true
        config.autoPolishDictationEnabled = false
        config.textTranslationEnabled = true
        config.numberConversionEnabled = true
        config.localModel = .fast
        config.modelId = AppConfig.LocalModel.fast.huggingFaceID
        config.localLivePreviewEnabled = false
        let preview = LocalLivePreviewController.shared
        let savedActivity = preview.activityIsIdle
        preview.activityIsIdle = { true }
        defer {
            preview.activityIsIdle = savedActivity
            if registeredIcon { icon?.setName(nil) }
            if registeredFont { CTFontManagerUnregisterFontsForURL(fontURL, .process, nil) }
            keys.forEach { defaults.removeObject(forKey: $0) }
            savedPreferences.forEach { defaults.set($0.1, forKey: $0.0) }
            TextSettingsModel.shared.refreshFromConfig()
            L10n.resetLaunchStateForTests()
            AppSupportPaths.resetForTesting()
            try? FileManager.default.removeItem(at: root)
        }

        for language in ["en", "zh-Hant-TW"] {
            AppConfig.shared.interfaceLanguageRaw = language
            L10n.resetLaunchStateForTests()
            for (appearance, tag) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
                if shortcutsDirectory != nil {
                    try render(ShortcutsSectionPreview.previews, "\(language)_shortcuts_\(tag)", appearance, out)
                    continue
                }
                try render(GeneralPane(), "\(language)_1_general_\(tag)", appearance, out)
                config.punctuationMode = .soft
                try render(DictationPane(onSwitchEngine: { _ in }), "\(language)_2_dictation_\(tag)", appearance, out)
                config.punctuationMode = .hard
                try render(DictationPane(onSwitchEngine: { _ in }), "\(language)_2_dictation_\(tag)_hard", appearance, out)
                try render(CaptionPane(onResetPanelFrame: {}), "\(language)_3_caption_\(tag)", appearance, out)
                try render(TextPane(), "\(language)_4_text_\(tag)", appearance, out)
                try render(CloudPane(), "\(language)_5_cloud_\(tag)", appearance, out)
                try render(AdvancedPane(onToggle: {}, isRunning: { false }), "\(language)_6_advanced_\(tag)", appearance, out)
                try render(AboutPane(onCheckForUpdates: {}, bundleInfo: bundleInfo), "\(language)_7_about_\(tag)", appearance, out)
            }
        }
    }

    private func render<V: View>(_ pane: V, _ name: String, _ appearance: NSAppearance.Name, _ dir: URL) throws {
        let host = NSHostingView(rootView: pane.background(Color(nsColor: .windowBackgroundColor)))
        host.appearance = NSAppearance(named: appearance)
        let size = host.fittingSize
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.contentView = host
        defer { window.contentView = nil }
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))

        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try png.write(to: dir.appendingPathComponent("\(name).png"))
        let scroll = try XCTUnwrap(formScrollView(in: host), "No grouped-form scroll view in \(name)")
        let document = try XCTUnwrap(scroll.documentView, "No grouped-form document view in \(name)")
        let content = document.frame.height
        let viewport = scroll.contentSize.height
        let surroundingHeight = host.bounds.height - viewport
        print("SETTINGS-FIT \(name): document=\(content) viewport=\(viewport) pane=\(host.bounds.height)")
        XCTAssertLessThanOrEqual(content, viewport, "\(name) scrolls by \(content - viewport) pt")
        XCTAssertLessThanOrEqual(content + surroundingHeight, 640, "\(name) requires more than 640 pt")
        XCTAssertLessThanOrEqual(host.bounds.height, 640, "\(name) window exceeds 640 pt")
    }

    private func formScrollView(in view: NSView) -> NSScrollView? {
        if let scrollView = view as? NSScrollView { return scrollView }
        for child in view.subviews {
            if let scrollView = formScrollView(in: child) { return scrollView }
        }
        return nil
    }
}
