import AppKit
import SwiftUI
import XCTest
@testable import HushType

/// Opt-in regression captures. The windows are never ordered on screen.
/// Behind-window materials are flattened before adding the simulated backdrop.
///
/// Set LAMITYPE_SURFACE_SNAPSHOT_DIR and filter to FloatingSurfaceSnapshotTests.
@MainActor
final class FloatingSurfaceSnapshotTests: XCTestCase {
    private let cornerSize: CGFloat = 28
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    func testRenderAllSurfaces() throws {
        guard let directory = ProcessInfo.processInfo.environment["LAMITYPE_SURFACE_SNAPSHOT_DIR"] else {
            throw XCTSkip("Set LAMITYPE_SURFACE_SNAPSHOT_DIR to render the floating surfaces")
        }
        let output = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        _ = NSApplication.shared

        let language = AppConfig.shared.interfaceLanguageRaw
        AppConfig.shared.interfaceLanguage = .english
        L10n.resetLaunchStateForTests()
        defer {
            AppConfig.shared.interfaceLanguageRaw = language
            L10n.resetLaunchStateForTests()
        }
        XCTAssertEqual(L10n.launchTag, "en")

        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let icon = try XCTUnwrap(NSImage(contentsOf: sourceRoot.appendingPathComponent("Resources/Lamitype.png")))
        var manifest = ["file,appearance,backdrop,width_pt,height_pt,width_px,height_px,corner_width_px,corner_height_px"]
        for (appearance, name) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            let appearance = try XCTUnwrap(NSAppearance(named: appearance))
            var result: Result<Void, Error> = .success(())
            appearance.performAsCurrentDrawingAppearance {
                result = Result {
                    for (name, state) in [
                        ("listening", OverlayState.recording(level: 0.35, provider: nil)),
                        ("transcribing", .transcribing(provider: nil)),
                        ("polishing", .polishing),
                        ("provider", .transcribing(provider: "OpenAI Whisper")),
                        ("failure", .notice(message: "The microphone became unavailable. Try recording again.")),
                        ("information", .notice(message: "Your dictation is on the clipboard.",
                                                 style: .information(heading: "Ready to paste"))),
                    ] {
                        let model = OverlayStateModel()
                        model.state = state
                        try capture(FloatingOverlayWindow(stateModel: model), "pill-\(name)")
                    }

                    for (name, phase) in [("recording", LiveDictationPhase.recording), ("finalizing", .finalizing)] {
                        let model = OverlayStateModel()
                        model.liveLevel = 0.35
                        model.live = LiveOverlayState(phase: phase, draft: "The draft appears here as you speak.", elapsed: 12)
                        try capture(FloatingOverlayWindow(stateModel: model), "live-preview-\(name)")
                    }

                    let captions = LiveCaptionViewModel()
                    captions.currentSourceLine = "Bonjour, la réunion commence maintenant."
                    captions.currentTargetLine = "Hello, the meeting is starting now."
                    for (name, size) in [("default", LiveCaptionPanelFrameStore.defaultSize),
                                         ("minimum", LiveCaptionPanelFrameStore.minimumSize)] {
                        let panel = LiveCaptionWindow(viewModel: captions, onStop: {})
                        panel.delegate = nil
                        try capture(panel, "caption-\(name)", size: size)
                    }

                    let original = "The meeting start at noon."
                    try captureView(PolishCardView(originalText: original, polishedText: "The meeting starts at noon.", changed: true),
                                    "polish-changed")
                    try captureView(PolishCardView(originalText: original, polishedText: original, changed: false),
                                    "polish-unchanged")
                    try captureView(TranslationCardView(sourceLanguage: "French",
                                                        sourceText: "La réunion commence à midi.",
                                                        translatedText: "The meeting starts at noon."), "translation")
                    try captureView(PermissionSettingsGuideView(
                        title: "Drag Lamitype into the permission list",
                        detail: "Turn on the switch in System Settings.",
                        appURL: URL(fileURLWithPath: "/Applications/Lamitype.app"),
                        onDismiss: {}
                    ), "permission-guide", size: NSSize(width: 500, height: 126))
                    try captureView(SystemAudioPermissionView(
                        model: SystemAudioPermissionViewModel(), appIcon: icon,
                        onOpenSettings: {}, onRestart: {}, onResetStaleEntries: {}, onCancel: {}
                    ), "system-audio", initialTitledSize: NSSize(width: SystemAudioPermissionWindowController.panelWidth,
                                                               height: SystemAudioPermissionWindowController.panelHeight))
                    try captureView(OnboardingSetupView(
                        model: OnboardingSetupViewModel(microphoneStatus: .notDetermined), appIcon: icon,
                        onOpenAccessibilitySettings: {}, onResetOldAccessibilityEntry: {}, onRequestMicrophone: {},
                        onOpenMicrophoneSettings: {}, onRestart: {}, onQuit: {}
                    ), "onboarding", initialTitledSize: NSSize(width: OnboardingSetupWindowController.panelWidth,
                                                              height: OnboardingSetupWindowController.panelHeight))
                }
            }
            try result.get()

            func captureView<V: View>(_ view: V, _ surface: String, size: NSSize? = nil,
                                      initialTitledSize: NSSize? = nil) throws {
                let panel = NSPanel(
                    contentRect: NSRect(origin: .zero, size: initialTitledSize ?? size ?? NSSize(width: 280, height: 56)),
                    styleMask: initialTitledSize == nil ? .borderless : [.titled, .fullSizeContentView],
                    backing: .buffered, defer: false
                )
                panel.isOpaque = false
                panel.backgroundColor = .clear
                panel.hasShadow = false
                if initialTitledSize != nil {
                    panel.titleVisibility = .hidden
                    panel.titlebarAppearsTransparent = true
                    panel.standardWindowButton(.closeButton)?.isHidden = true
                    panel.contentViewController = NSHostingController(rootView: view)
                } else {
                    panel.contentView = NSHostingView(rootView: view)
                }
                try capture(panel, surface, size: size, logFrame: initialTitledSize != nil && name == "light")
            }

            func capture(_ panel: NSPanel, _ surface: String, size: NSSize? = nil, logFrame: Bool = false) throws {
                try save(panel, surface: surface, appearance: appearance, appearanceName: name,
                         size: size, logFrame: logFrame, output: output, manifest: &manifest)
            }
        }
        try (manifest.joined(separator: "\n") + "\n").write(
            to: output.appendingPathComponent("captures.csv"), atomically: true, encoding: .utf8
        )
    }

    private func save(_ panel: NSPanel, surface: String, appearance: NSAppearance, appearanceName: String,
                      size: NSSize?, logFrame: Bool, output: URL, manifest: inout [String]) throws {
        let view = try XCTUnwrap(panel.contentView)
        panel.appearance = appearance
        view.appearance = appearance
        view.layoutSubtreeIfNeeded()
        let initialFrame = panel.frame
        let fittingSize = size ?? view.fittingSize
        XCTAssertGreaterThan(fittingSize.width, 0, surface)
        XCTAssertGreaterThan(fittingSize.height, 0, surface)
        let integralSize = NSSize(width: ceil(fittingSize.width), height: ceil(fittingSize.height))
        panel.setContentSize(integralSize)
        view.frame.size = integralSize
        view.needsLayout = true
        view.layoutSubtreeIfNeeded()
        XCTAssertFalse(panel.isVisible, surface)
        if logFrame {
            print("Floating surface \(surface) offscreen titled panel: initial frame \(initialFrame), fittingSize \(fittingSize), capture frame \(panel.frame)")
        }

        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds), surface)
        view.cacheDisplay(in: view.bounds, to: rep)
        let image = try XCTUnwrap(rep.cgImage, surface)
        let cornerWidth = Int((cornerSize * CGFloat(image.width) / integralSize.width).rounded())
        let cornerHeight = Int((cornerSize * CGFloat(image.height) / integralSize.height).rounded())
        let backdropContrasts: [(String, CGFloat, CGFloat)] = [("white", 1, 1), ("dark", 30 / 255, 32 / 255)]

        for (backdrop, redGreen, blue) in backdropContrasts {
            let filename = "\(surface)_\(appearanceName)_\(backdrop)"
            let context = try bitmap(width: image.width, height: image.height)
            let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
            context.setFillColor(CGColor(srgbRed: redGreen, green: redGreen, blue: blue, alpha: 1))
            context.fill(bounds)
            context.draw(image, in: bounds)
            let composite = try XCTUnwrap(context.makeImage(), filename)
            try write(composite, to: output.appendingPathComponent("\(filename).png"))

            let crop = try XCTUnwrap(composite.cropping(to: CGRect(x: 0, y: 0, width: cornerWidth, height: cornerHeight)))
            let zoom = try bitmap(width: cornerWidth * 4, height: cornerHeight * 4)
            zoom.interpolationQuality = .none
            zoom.draw(crop, in: CGRect(x: 0, y: 0, width: cornerWidth * 4, height: cornerHeight * 4))
            try write(try XCTUnwrap(zoom.makeImage()), to: output.appendingPathComponent("\(filename)_corner4x.png"))
            manifest.append("\(filename).png,\(appearanceName),\(backdrop),\(Int(integralSize.width)),\(Int(integralSize.height)),\(image.width),\(image.height),\(cornerWidth),\(cornerHeight)")
        }
    }

    private func bitmap(width: Int, height: Int) throws -> CGContext {
        try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                               space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    }

    private func write(_ image: CGImage, to url: URL) throws {
        let rep = NSBitmapImageRep(cgImage: image)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
    }
}
