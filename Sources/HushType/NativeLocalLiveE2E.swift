#if DEBUG
import AppKit
import AVFoundation

@MainActor
enum NativeLocalLiveCounters {
    static var lastFinalGeneratedTokens = 0
    static var lastFinalEndedByEOS = false
    static var forceNextFinalIncomplete = false
    static var captionShortcutRoutes = 0
    static var gestureProbeOnly = false
    static var translationRoutes = 0
    static var polishRoutes = 0
    static var polishCalls = 0
    static var finalCalls = 0
    static var results = 0
    static var pasteDispatches = 0
}

/// Explicit opt-in native harness in DEBUG builds of the authorized test app.
/// It exercises the real global hotkey, mic, model, overlay and paste.
@MainActor
final class NativeLocalLiveE2E {
    let inspect: () -> [String: Any]
    let snapshot: (String) -> Void
    let setPreview: (Bool) -> Void
    let setEngine: (AppConfig.DictationEngine) -> Void
    let dismissResult: () -> Void
    let openLastResult: () -> Bool
    let readMemory: () -> [String: Any]
    let performMenuAction: (String) -> Bool
    let clearPrivateState: () -> Void
    let interruptHotkey: (() -> Void)?
    let staleHotkey: (() -> Void)?
    let output: URL
    let audio: URL
    let capAudio: URL
    private var window: NSWindow!
    private let first = NSTextView(), second = NSTextView()
    private var rows: [[String: Any]] = []
    private var player: Process?

    init(output: URL, audio: URL, capAudio: URL, inspect: @escaping () -> [String: Any], snapshot: @escaping (String) -> Void, openLastResult: @escaping () -> Bool, readMemory: @escaping () -> [String: Any], performMenuAction: @escaping (String) -> Bool, clearPrivateState: @escaping () -> Void, setPreview: @escaping (Bool) -> Void, setEngine: @escaping (AppConfig.DictationEngine) -> Void, dismissResult: @escaping () -> Void, interruptHotkey: (() -> Void)? = nil, staleHotkey: (() -> Void)? = nil) {
        self.interruptHotkey = interruptHotkey; self.staleHotkey = staleHotkey
        self.output = output; self.audio = audio; self.capAudio = capAudio
        self.inspect = inspect; self.snapshot = snapshot; self.openLastResult = openLastResult; self.readMemory = readMemory; self.performMenuAction = performMenuAction; self.clearPrivateState = clearPrivateState; self.setPreview = setPreview; self.setEngine = setEngine; self.dismissResult = dismissResult
    }
    private func record(_ event: String, _ extra: [String: Any] = [:]) {
        var row = inspect()
        row["event"] = event; row["time"] = ISO8601DateFormatter().string(from: Date())
        row["inputMode"] = NativeFixtureAudioInput.isEnabled ? "paced WAV through CaptureDriver at 48kHz" : "physical microphone"
        row["interfaceLocale"] = L10n.launchTag
        for (key, value) in extra { row[key] = value }
        row["firstField"] = first.string; row["secondField"] = second.string
        rows.append(row)
        snapshot(event)
        try? FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: rows, options: [.sortedKeys, .prettyPrinted]) { try? data.write(to: output, options: .atomic) }
    }
    private func wait(_ seconds: Double) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
    private func key(_ down: Bool) {
        let event = CGEvent(keyboardEventSource: CGEventSource(stateID: .hidSystemState), virtualKey: 61, keyDown: down)!
        event.type = .flagsChanged; event.flags = down ? CGEventFlags(rawValue: CGEventFlags.maskAlternate.rawValue | 0x40) : []
        event.post(tap: .cghidEventTap)
    }
    private func focusAndClear() {
        dismissResult(); NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil); window.makeFirstResponder(first)
        first.string = ""; second.string = ""
    }
    private func play(_ url: URL) {
        stopPlayback()
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/afplay"); process.arguments = [url.path]
        do { try process.run(); player = process }
        catch { record("playback_error", ["error": error.localizedDescription]) }
    }
    private func stopPlayback() {
        if player?.isRunning == true { player?.terminate() }; player = nil
    }
    private func beginAudio(_ url: URL) async -> Bool {
        if NativeFixtureAudioInput.isEnabled { NativeFixtureAudioInput.nextURL = url }
        key(true)
        guard await admitRecording() else { return false }
        if !NativeFixtureAudioInput.isEnabled { play(url) }
        return true
    }
    private func admitRecording() async -> Bool {
        for _ in 0..<50 {
            if inspect()["appState"] as? String == "recording" { await wait(0.3); return true }
            await wait(0.1)
        }
        record("recording_admission_failed"); key(false); return false
    }
    private func terminal() async -> Bool {
        for _ in 0..<300 {
            if (inspect()["livePhase"] as? String) == "none" || (inspect()["livePhase"] as? String) == "recovery" { return true }
            await wait(0.1)
        }
        record("terminal_timeout"); return false
    }
    func run() async {
        guard ["com.felix.lamitype.localLiveQA", "com.felix.hushtype"].contains(Bundle.main.bundleIdentifier ?? ""), CommandLine.arguments.contains("--native-e2e") else { return }
        guard AXIsProcessTrusted(), CGPreflightPostEventAccess() else {
            record("blocked_permissions", ["accessibility": AXIsProcessTrusted(), "postEvents": CGPreflightPostEventAccess()]); return
        }
        window = NSWindow(contentRect: NSRect(x: 160, y: 220, width: 640, height: 330), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Lamitype native E2E - disposable document"
        for (index, view) in [first, second].enumerated() {
            view.frame = NSRect(x: 20, y: 175 - index * 145, width: 600, height: 120)
            view.font = .systemFont(ofSize: 15); view.isRichText = false
            view.setAccessibilityLabel(index == 0 ? "Original test field" : "Alternate test field")
            window.contentView?.addSubview(view)
        }
        NSApp.setActivationPolicy(.regular)
        // A menu-bar app has no normal Edit menu. Give this disposable editor
        // the standard responder-chain Paste command that real editors expose.
        let savedMenu = NSApp.mainMenu
        let menu = NSMenu()
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editItem.submenu = editMenu; menu.addItem(editItem); NSApp.mainMenu = menu
        let savedPreview = AppConfig.shared.localLivePreviewEnabled
        let savedOverlay = AppConfig.shared.floatingOverlayEnabled
        defer {
            key(false); stopPlayback(); setPreview(savedPreview)
            AppConfig.shared.floatingOverlayEnabled = savedOverlay
            NSApp.mainMenu = savedMenu
        }
        setPreview(true); AppConfig.shared.floatingOverlayEnabled = false
        focusAndClear(); await wait(0.5)
        record("start", ["accessibility": AXIsProcessTrusted(), "audio": audio.lastPathComponent])
        if CommandLine.arguments.contains("--native-memory-pattern") {
            await memoryPatternChecks()
            return
        }
        if CommandLine.arguments.contains("--native-e2e-clips-only") {
            await clipChecks()
            return
        }

        if CommandLine.arguments.contains("--native-e2e-reload-first") {
            record("unloaded_before_hotkey", ["unloaded": inspect()["appState"] as? String == "unloaded", "modelAbsent": inspect()["modelLoaded"] as? Bool == false])
            key(true); await wait(0.4); key(false)
            for _ in 0..<300 {
                if inspect()["appState"] as? String == "idle", inspect()["modelLoaded"] as? Bool == true { break }
                await wait(0.1)
            }
            let ready = inspect()["appState"] as? String == "idle" && inspect()["modelLoaded"] as? Bool == true
            record("hotkey_reloaded_model", ["ready": ready])
            guard ready else { return }
        }

        let normalFinalCalls = NativeLocalLiveCounters.finalCalls
        let normalPasteDispatches = NativeLocalLiveCounters.pasteDispatches
        guard await beginAudio(audio) else { return }
        await wait(3)
        record("live_preview", ["noEarlyInsertion": first.string.isEmpty && second.string.isEmpty])
        await wait(3); record("live_preview_later")
        await wait(3); key(false); stopPlayback(); guard await terminal() else { return }; await wait(0.7)
        record("normal_release", ["pasteObserved": !first.string.isEmpty && first.string == inspect()["result"] as? String,
                                  "noAutomaticResultWindow": inspect()["resultVisible"] as? Bool == false,
                                  "oneFinalCall": NativeLocalLiveCounters.finalCalls == normalFinalCalls + 1,
                                  "onePasteDispatch": NativeLocalLiveCounters.pasteDispatches == normalPasteDispatches + 1,
                                  "alternateUntouched": second.string.isEmpty])

        if let interruptHotkey, let staleHotkey {
            focusAndClear(); await wait(0.5)
            let finals = NativeLocalLiveCounters.finalCalls, results = NativeLocalLiveCounters.results, pastes = NativeLocalLiveCounters.pasteDispatches
            guard await beginAudio(audio) else { return }
            var busy = false
            for _ in 0..<120 { if inspect()["recognitionBusy"] as? Bool == true { busy = true; break }; await wait(0.05) }
            interruptHotkey(); key(false); stopPlayback(); guard await terminal() else { return }; await wait(0.5)
            record("interrupted_hook_drained", ["busyObserved": busy,
                "noFinal": NativeLocalLiveCounters.finalCalls == finals,
                "noResult": NativeLocalLiveCounters.results == results,
                "noPaste": NativeLocalLiveCounters.pasteDispatches == pastes && first.string.isEmpty,
                "audioReleased": inspect()["failedAudioFrames"] as? Int == 0,
                "leaseReleased": inspect()["cacheLease"] as? Bool == false,
                "listenerEnabled": inspect()["tapEnabled"] as? Bool == true])
            focusAndClear(); await wait(0.5)
            let newFinals = NativeLocalLiveCounters.finalCalls, newPastes = NativeLocalLiveCounters.pasteDispatches
            guard await beginAudio(audio) else { return }
            staleHotkey()
            record("stale_disable_fresh_hold", ["stillRecording": inspect()["appState"] as? String == "recording",
                "held": inspect()["managerKeyDown"] as? Bool == true])
            await wait(8); key(false); stopPlayback(); guard await terminal() else { return }; await wait(0.7)
            record("stale_disable_fresh_result", ["oneFinal": NativeLocalLiveCounters.finalCalls == newFinals + 1,
                "onePaste": NativeLocalLiveCounters.pasteDispatches == newPastes + 1,
                "pasteObserved": !first.string.isEmpty && first.string == inspect()["result"] as? String])
        }

        focusAndClear(); await wait(0.5)
        let changedPasteDispatches = NativeLocalLiveCounters.pasteDispatches
        guard await beginAudio(audio) else { return }
        await wait(1); window.makeFirstResponder(second)
        await wait(7); key(false); stopPlayback(); guard await terminal() else { return }; await wait(0.7)
        record("field_changed", ["noUnexpectedPaste": first.string.isEmpty && second.string.isEmpty,
                                 "nonemptyCopyResult": !(inspect()["result"] as? String ?? "").isEmpty,
                                 "noAutomaticResultWindow": inspect()["resultVisible"] as? Bool == false,
                                 "neutralNoticeVisible": inspect()["noticeVisible"] as? Bool == true && inspect()["failureNotice"] as? Bool == false,
                                 "noPasteDispatch": NativeLocalLiveCounters.pasteDispatches == changedPasteDispatches])

        let retained = inspect()["result"] as? String ?? ""
        let opened = openLastResult(); await wait(0.3)
        record("manual_result_open", ["menuActionInvoked": opened,
            "windowVisible": inspect()["resultVisible"] as? Bool == true,
            "sameRetainedText": !retained.isEmpty && inspect()["result"] as? String == retained])

        focusAndClear(); await wait(0.5)
        let cancelledFinalCalls = NativeLocalLiveCounters.finalCalls
        let cancelledResults = NativeLocalLiveCounters.results
        let cancelledPasteDispatches = NativeLocalLiveCounters.pasteDispatches
        guard await beginAudio(audio) else { return }
        await wait(2)
        // Option+Escape invokes Cocoa completion and may insert text even when
        // Lamitype correctly cancels. Option+Left only moves the empty caret.
        for down in [true, false] {
            let arrow = CGEvent(keyboardEventSource: CGEventSource(stateID: .hidSystemState), virtualKey: 123, keyDown: down)!
            arrow.flags = .maskAlternate; arrow.post(tap: .cghidEventTap)
        }
        await wait(0.2); key(false); stopPlayback(); guard await terminal() else { return }; await wait(0.5)
        record("cancelled_chord", ["noUnexpectedPaste": first.string.isEmpty && second.string.isEmpty,
                                   "noFinalCall": NativeLocalLiveCounters.finalCalls == cancelledFinalCalls,
                                   "noResult": NativeLocalLiveCounters.results == cancelledResults,
                                   "noPasteDispatch": NativeLocalLiveCounters.pasteDispatches == cancelledPasteDispatches])

        focusAndClear(); await wait(0.5)
        let capFinalCalls = NativeLocalLiveCounters.finalCalls
        let capPasteDispatches = NativeLocalLiveCounters.pasteDispatches
        guard await beginAudio(capAudio) else { return }
        await wait(30); record("cap_midpoint")
        await wait(25); record("cap_countdown")
        await wait(5.4); record("cap_stopped_while_key_held")
        await wait(5); guard await terminal() else { return }; record("cap_result_before_release")
        let beforeReleaseResults = NativeLocalLiveCounters.results
        let beforeReleasePastes = NativeLocalLiveCounters.pasteDispatches
        let beforeReleaseText = inspect()["result"] as? String ?? ""
        key(false); stopPlayback(); guard await terminal() else { return }; await wait(0.7)
        record("cap_release_consumed", ["alternateUntouched": second.string.isEmpty,
                                       "pasteObserved": !first.string.isEmpty && first.string == inspect()["result"] as? String,
                                       "onePasteDispatch": NativeLocalLiveCounters.pasteDispatches == capPasteDispatches + 1,
                                       "oneFinalCall": NativeLocalLiveCounters.finalCalls == capFinalCalls + 1,
                                       "noResultOnRelease": NativeLocalLiveCounters.results == beforeReleaseResults,
                                       "noPasteOnRelease": NativeLocalLiveCounters.pasteDispatches == beforeReleasePastes,
                                       "resultUnchangedOnRelease": inspect()["result"] as? String == beforeReleaseText])

        setPreview(false); AppConfig.shared.floatingOverlayEnabled = true
        focusAndClear(); await wait(0.5); guard await beginAudio(audio) else { return }
        await wait(1)
        record("legacy_local_recording", ["ordinaryIndicatorVisible": inspect()["ordinaryOverlayVisible"] as? Bool == true,
            "oneOverlay": inspect()["visibleOverlayCount"] as? Int == 1,
            "noLivePreview": inspect()["liveOverlayVisible"] as? Bool == false])
        await wait(7); key(false); stopPlayback(); await wait(6)
        record("legacy_local", ["pasteObserved": !first.string.isEmpty, "alternateUntouched": second.string.isEmpty])
        await externalDocumentCases()
        // Empty QA key files guarantee these lanes cannot upload audio. Exercise
        // their actual missing-key UI and verify the live toggle is ignored.
        for engine in [AppConfig.DictationEngine.openai, .gemini] {
            let keyFile = engine == .openai ? AppSupportPaths.openAIKeyFileURL : AppSupportPaths.geminiKeyFileURL
            guard !FileManager.default.fileExists(atPath: keyFile.path) else {
                record("cloud_skipped_existing_key_file_" + engine.rawValue); continue
            }
            setPreview(true); setEngine(engine); focusAndClear(); await wait(0.4)
            key(true); await wait(0.6)
            record("cloud_recording_" + engine.rawValue, ["noLivePreview": inspect()["liveOverlayVisible"] as? Bool == false, "noLease": inspect()["cacheLease"] as? Bool == false])
            // Native run-loop timer can dismiss the app's own missing-key alert
            // even if its nested modal loop temporarily blocks MainActor jobs.
            let closeAlert = Timer(timeInterval: 1.2, repeats: false) { _ in
                MainActor.assumeIsolated {
                    guard let modal = NSApp.modalWindow else { return }
                    var buttons: [NSButton] = []
                    func collect(_ view: NSView) {
                        if let button = view as? NSButton { buttons.append(button) }
                        for child in view.subviews { collect(child) }
                    }
                    if let content = modal.contentView { collect(content) }
                    if let button = buttons.first(where: { ["Cancel", "OK"].contains($0.title) }) ?? buttons.last { button.performClick(nil) }
                }
            }
            RunLoop.main.add(closeAlert, forMode: .common)
            RunLoop.main.add(closeAlert, forMode: .modalPanel)
            key(false); await wait(2)
            closeAlert.invalidate()
            record("cloud_missing_key_" + engine.rawValue, ["noInsertion": first.string.isEmpty && second.string.isEmpty])
        }
        setEngine(.local)
        clearPrivateState(); await wait(0.2)
        record("privacy_handler_clear", ["resultCleared": (inspect()["result"] as? String ?? "").isEmpty,
            "audioCleared": inspect()["failedAudioFrames"] as? Int == 0,
            "windowHidden": inspect()["resultVisible"] as? Bool == false,
            "overlayHidden": inspect()["visibleOverlayCount"] as? Int == 0,
            "lastResultUnavailable": !openLastResult()])
        let required: [String: [String]] = [
            "privacy_handler_clear": ["resultCleared", "audioCleared", "windowHidden", "overlayHidden", "lastResultUnavailable"],
            "live_preview": ["noEarlyInsertion"],
            "normal_release": ["pasteObserved", "oneFinalCall", "onePasteDispatch", "alternateUntouched", "noAutomaticResultWindow"],
            "field_changed": ["noUnexpectedPaste", "nonemptyCopyResult", "noPasteDispatch", "noAutomaticResultWindow", "neutralNoticeVisible"],
            "manual_result_open": ["menuActionInvoked", "windowVisible", "sameRetainedText"],
            "cancelled_chord": ["noUnexpectedPaste", "noFinalCall", "noResult", "noPasteDispatch"],
            "cap_result_before_release": ["closedPressLatch"],
            "cap_release_consumed": ["pasteObserved", "onePasteDispatch", "oneFinalCall", "noResultOnRelease", "noPasteOnRelease", "resultUnchangedOnRelease", "alternateUntouched"],
            "legacy_local_recording": ["ordinaryIndicatorVisible", "oneOverlay", "noLivePreview"],
            "legacy_local": ["pasteObserved", "alternateUntouched"],
            "external_normal_release": ["pasteObserved", "onePasteDispatch", "alternateUntouched", "noAutomaticResultWindow"],
            "external_field_changed": ["noUnexpectedPaste", "nonemptyCopyResult", "noPasteDispatch", "noAutomaticResultWindow", "neutralNoticeVisible", "originalAppStillFront"],
            "cloud_recording_openai": ["noLivePreview", "noLease"],
            "cloud_missing_key_openai": ["noInsertion"],
            "cloud_recording_gemini": ["noLivePreview", "noLease"],
            "cloud_missing_key_gemini": ["noInsertion"]
        ]
        var unmet: [String] = []
        var skipped: [String] = []
        for (event, keys) in required {
            if event.hasPrefix("cloud_"), let engine = event.split(separator: "_").last,
               rows.contains(where: { $0["event"] as? String == "cloud_skipped_existing_key_file_" + engine }) {
                skipped.append(event + ": existing key file; no upload attempted"); continue
            }
            guard let row = rows.first(where: { $0["event"] as? String == event }) else { unmet.append(event + ": not executed"); continue }
            for key in keys where row[key] as? Bool != true { unmet.append(event + "." + key) }
        }
        if !rows.contains(where: { ["live_preview", "live_preview_later"].contains($0["event"] as? String ?? "") && !($0["draft"] as? String ?? "").isEmpty }) {
            unmet.append("nonempty_live_draft")
        }
        if interruptHotkey != nil && staleHotkey != nil {
            for (event, keys) in [("interrupted_hook_drained", ["busyObserved", "noFinal", "noResult", "noPaste", "audioReleased", "leaseReleased", "listenerEnabled"]),
                                  ("stale_disable_fresh_hold", ["stillRecording", "held"]),
                                  ("stale_disable_fresh_result", ["oneFinal", "onePaste", "pasteObserved"])] {
                guard let row = rows.first(where: { $0["event"] as? String == event }) else { unmet.append(event); continue }
                for key in keys where row[key] as? Bool != true { unmet.append(event + "." + key) }
            }
        }
        if CommandLine.arguments.contains("--native-e2e-reload-first") {
            for (event, keys) in [("unloaded_before_hotkey", ["unloaded", "modelAbsent"]), ("hotkey_reloaded_model", ["ready"])] {
                guard let row = rows.first(where: { $0["event"] as? String == event }) else { unmet.append(event); continue }
                for key in keys where row[key] as? Bool != true { unmet.append(event + "." + key) }
            }
        }
        record("finished", ["automaticChecksPassed": unmet.isEmpty, "unmetChecks": unmet.sorted(), "skippedCoverage": skipped.sorted()])
    }

    /// Real hotkey/physical-capture workloads with per-process + MLX samples.
    /// No cache clearing between measured attempts; unload is its own pattern.
    private func memoryPatternChecks() async {
        guard let index = CommandLine.arguments.firstIndex(of: "--native-memory-pattern"),
              CommandLine.arguments.indices.contains(index + 1) else { return }
        let pattern = CommandLine.arguments[index + 1]
        let root = output.deletingLastPathComponent()
        var samples: [[String: Any]] = []
        var stage = "initial"
        var unmet: [String] = []
        let oldPolish = AppConfig.shared.textPolishEnabled
        let oldAutoPolish = AppConfig.shared.autoPolishDictationEnabled
        AppConfig.shared.autoPolishDictationEnabled = false
        func writeSamples() {
            if let data = try? JSONSerialization.data(withJSONObject: samples, options: [.sortedKeys]) {
                try? data.write(to: root.appendingPathComponent("memory-samples.json"), options: .atomic)
            }
        }
        func sample() {
            var row = readMemory()
            row["stage"] = stage; row["uptime"] = ProcessInfo.processInfo.systemUptime
            samples.append(row)
            if samples.count % 12 == 0 { writeSamples() }
        }
        let sampler = Timer(timeInterval: 0.25, repeats: true) { _ in MainActor.assumeIsolated { sample() } }
        RunLoop.main.add(sampler, forMode: .common)
        defer {
            sampler.invalidate(); sample(); writeSamples()
            NativeLocalLiveCounters.forceNextFinalIncomplete = false
            AppConfig.shared.textPolishEnabled = oldPolish
            AppConfig.shared.autoPolishDictationEnabled = oldAutoPolish
        }
        func result(_ event: String, _ checks: [String: Bool], extra: [String: Any] = [:]) {
            var values: [String: Any] = extra
            for (key, passed) in checks { values[key] = passed; if !passed { unmet.append(event + "." + key) } }
            record(event, values)
        }
        func idle() async -> Bool {
            for _ in 0..<600 {
                if inspect()["appState"] as? String == "idle" { return true }
                await wait(0.1)
            }
            return false
        }
        func clipDuration(_ clip: URL) -> Double {
            guard let file = try? AVAudioFile(forReading: clip) else { return 0 }
            return Double(file.length) / file.processingFormat.sampleRate
        }
        func attempt(_ id: String, live: Bool, cap: Bool = false, expectFailure: Bool = false) async -> Bool {
            stage = id
            setPreview(live); AppConfig.shared.floatingOverlayEnabled = true
            focusAndClear(); await wait(0.5)
            let priorLimit = readMemory()["mlxCacheLimitBytes"] as? Int ?? -1
            let beforeFinal = NativeLocalLiveCounters.finalCalls
            let beforePaste = NativeLocalLiveCounters.pasteDispatches
            let clip = cap ? capAudio : audio
            guard await beginAudio(clip) else { unmet.append(id + ".captureAdmission"); return false }
            let current = readMemory()
            result(id + "_recording", ["cachePolicy": (current["mlxCacheLimitBytes"] as? Int) == (live ? 128 * 1024 * 1024 : priorLimit),
                "leaseMatchesMode": current["cacheLease"] as? Bool == live], extra: ["pattern": pattern, "priorLimitBytes": priorLimit])
            await wait(cap ? 65 : clipDuration(clip) + 0.5)
            let beforeReleaseFinal = NativeLocalLiveCounters.finalCalls
            key(false); stopPlayback()
            guard await terminal() else { unmet.append(id + ".terminal"); return false }
            if expectFailure {
                result(id + "_recovery", ["recoveryVisible": inspect()["resultVisible"] as? Bool == true,
                    "retainedAudio": (inspect()["failedAudioFrames"] as? Int ?? 0) > 0,
                    "boundedAudio": (inspect()["failedAudioFrames"] as? Int ?? Int.max) <= 960_000,
                    "noPaste": NativeLocalLiveCounters.pasteDispatches == beforePaste,
                    "cacheRestored": readMemory()["mlxCacheLimitBytes"] as? Int == priorLimit,
                    "leaseReleased": readMemory()["cacheLease"] as? Bool == false])
                await wait(10); record(id + "_retained_idle", ["pattern": pattern])
                return inspect()["livePhase"] as? String == "recovery"
            }
            guard await idle() else { unmet.append(id + ".idle"); return false }
            await wait(0.7)
            result(id + "_complete", ["observedPaste": !first.string.isEmpty,
                "noAutomaticWindow": inspect()["resultVisible"] as? Bool == false,
                "oneFinal": !live || NativeLocalLiveCounters.finalCalls == beforeFinal + 1,
                "onePaste": !live || NativeLocalLiveCounters.pasteDispatches == beforePaste + 1,
                "autoFinalBeforeRelease": !cap || beforeReleaseFinal == beforeFinal + 1,
                "cacheRestored": readMemory()["mlxCacheLimitBytes"] as? Int == priorLimit,
                "audioReleased": readMemory()["failedAudioFrames"] as? Int == 0,
                "leaseReleased": readMemory()["cacheLease"] as? Bool == false], extra: ["pattern": pattern])
            stage = id + "_settling"; await wait(10); sample()
            record(id + "_settled", ["pattern": pattern])
            return unmet.isEmpty
        }
        func clickRecoverySynchronously(_ title: String) -> Bool {
            func value(_ node: AXUIElement, _ key: String) -> CFTypeRef? {
                var result: CFTypeRef?; AXUIElementCopyAttributeValue(node, key as CFString, &result); return result
            }
            var visited = 0
            func find(_ node: AXUIElement, _ depth: Int) -> AXUIElement? {
                guard depth < 20, visited < 1500 else { return nil }; visited += 1
                if value(node, kAXRoleAttribute) as? String == kAXButtonRole {
                    let identifiers = [L10n.string("live.action.retry", fallback: "Retry locally"): "local-live-retry",
                        L10n.string("live.action.discard", fallback: "Discard"): "local-live-discard",
                        L10n.string("live.action.save", fallback: "Save Audio…"): "local-live-save"]
                    let identifier = identifiers[title] ?? "unmatched-action"
                    if value(node, kAXIdentifierAttribute) as? String == identifier
                        || value(node, kAXTitleAttribute) as? String == title
                        || value(node, kAXDescriptionAttribute) as? String == title { return node }
                }
                for child in value(node, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
                    if let match = find(child, depth + 1) { return match }
                }
                return nil
            }
            let app = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
            for window in value(app, kAXWindowsAttribute) as? [AXUIElement] ?? [] {
                guard value(window, kAXTitleAttribute) as? String == L10n.string("live.result.title", fallback: "Local Live Dictation") else { continue }
                if let button = find(window, 0) { return AXUIElementPerformAction(button, kAXPressAction as CFString) == .success }
            }
            return false
        }
        func clickRecovery(_ title: String) async -> Bool {
            // Native actions may spin nested AppKit/XPC run loops. Enter from
            // GCD with the Swift test Task suspended, as a real UI event does.
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume(returning: clickRecoverySynchronously(title)) }
            }
        }
        record("memory_start", ["pattern": pattern, "settledIdleSeconds": 10, "samplePeriodSeconds": 0.25])
        if pattern == "homogeneous" {
            for attemptIndex in 0..<12 {
                if !(await attempt("short_\(attemptIndex)", live: true)) { break }
            }
        } else if pattern == "caps" {
            for attemptIndex in 0..<3 {
                if !(await attempt("cap_\(attemptIndex)", live: true, cap: true)) { break }
            }
        } else if pattern == "alternating" {
            for attemptIndex in 0..<6 {
                if !(await attempt("mode_\(attemptIndex)", live: attemptIndex % 2 == 0)) { break }
            }
        } else if pattern == "cancel" {
            for attemptIndex in 0..<3 {
                stage = "cancel_\(attemptIndex)"; setPreview(true); focusAndClear(); await wait(0.5)
                let limit = readMemory()["mlxCacheLimitBytes"] as? Int
                let final = NativeLocalLiveCounters.finalCalls
                guard await beginAudio(audio) else { unmet.append(stage + ".admission"); break }
                var busyObserved = false
                for _ in 0..<100 {
                    if readMemory()["recognitionBusy"] as? Bool == true { busyObserved = true; break }
                    await wait(0.05)
                }
                for down in [true, false] {
                    let event = CGEvent(keyboardEventSource: CGEventSource(stateID: .hidSystemState), virtualKey: 123, keyDown: down)!
                    event.flags = .maskAlternate; event.post(tap: .cghidEventTap)
                }
                await wait(0.02); key(false); stopPlayback(); _ = await terminal(); _ = await idle()
                await wait(10)
                result(stage + "_settled", ["busyObserved": busyObserved,
                    "noFinal": NativeLocalLiveCounters.finalCalls == final, "noInsertion": first.string.isEmpty,
                    "audioReleased": readMemory()["failedAudioFrames"] as? Int == 0,
                    "cacheRestored": readMemory()["mlxCacheLimitBytes"] as? Int == limit,
                    "leaseReleased": readMemory()["cacheLease"] as? Bool == false])
            }
        } else if pattern == "recovery" {
            NativeLocalLiveCounters.forceNextFinalIncomplete = true
            if await attempt("failure_cap", live: true, cap: true, expectFailure: true) {
                let retainedFrames = inspect()["failedAudioFrames"] as? Int ?? 0
                let export = root.appendingPathComponent("native-recovery-test.wav")
                let saveInvoked = await clickRecovery(L10n.string("live.action.save", fallback: "Save Audio…"))
                var panel: NSSavePanel?
                var savePanelDetails: [String: Any] = [:]
                for _ in 0..<50 {
                    panel = NSApp.windows.first { $0 is NSSavePanel && $0.isVisible } as? NSSavePanel
                    if panel != nil { break }; await wait(0.1)
                }
                if let panel {
                    savePanelDetails = await withCheckedContinuation { continuation in
                        DispatchQueue.main.async {
                            panel.directoryURL = root; panel.nameFieldStringValue = export.lastPathComponent
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                                panel.makeFirstResponder(nil)
                                let sameDirectory = panel.directoryURL?.standardizedFileURL.path == root.standardizedFileURL.path
                                let sameName = panel.nameFieldStringValue == export.lastPathComponent
                                let details: [String: Any] = ["directoryMatches": sameDirectory, "nameMatches": sameName,
                                    "actualDirectory": panel.directoryURL?.path ?? "", "actualName": panel.nameFieldStringValue,
                                    "prospectiveURL": panel.url?.path ?? ""]
                                // panel.url is authoritative only on completion;
                                // the DEBUG writer fences its actual destination.
                                var saveDetails = details
                                func attribute(_ node: AXUIElement, _ key: String) -> CFTypeRef? {
                                    var value: CFTypeRef?; AXUIElementCopyAttributeValue(node, key as CFString, &value); return value
                                }
                                var visited = 0
                                func saveButton(_ node: AXUIElement, _ depth: Int) -> AXUIElement? {
                                    guard depth < 24, visited < 2000 else { return nil }; visited += 1
                                    if attribute(node, kAXRoleAttribute) as? String == kAXButtonRole,
                                       attribute(node, kAXEnabledAttribute) as? Bool == true,
                                       attribute(node, kAXTitleAttribute) as? String == "Save" || attribute(node, kAXDescriptionAttribute) as? String == "Save" { return node }
                                    for child in attribute(node, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
                                        if let found = saveButton(child, depth + 1) { return found }
                                    }
                                    return nil
                                }
                                var pressed = false
                                if sameDirectory && sameName {
                                    let app = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
                                    for window in attribute(app, kAXWindowsAttribute) as? [AXUIElement] ?? [] {
                                        guard attribute(window, kAXTitleAttribute) as? String == panel.title else { continue }
                                        if let button = saveButton(window, 0) {
                                            pressed = AXUIElementPerformAction(button, kAXPressAction as CFString) == .success; break
                                        }
                                    }
                                }
                                saveDetails["realSaveButtonPressed"] = pressed; saveDetails["savePanelTitle"] = panel.title
                                if !pressed { panel.cancel(nil) }
                                continuation.resume(returning: saveDetails)
                            }
                        }
                    }
                }
                for _ in 0..<50 { if FileManager.default.fileExists(atPath: export.path) { break }; await wait(0.1) }
                let exported = try? Data(contentsOf: export)
                result("save_audio_verified", ["actionInvoked": saveInvoked, "realSavePanel": panel != nil,
                    "validWAV": exported?.prefix(4) == Data("RIFF".utf8),
                    "exactFramePayload": exported?.count == 44 + retainedFrames * 2,
                    "recordingStillRetained": inspect()["failedAudioFrames"] as? Int == retainedFrames], extra: savePanelDetails)
                // Release the completed remote panel, as the app's normal
                // asynchronous Save action does. Do not keep its input session
                // alive across the next test recording.
                panel = nil
                try? FileManager.default.removeItem(at: export) // test-owned export only
                let beforeRetry = NativeLocalLiveCounters.finalCalls
                let beforePaste = NativeLocalLiveCounters.pasteDispatches
                let clicked = await clickRecovery(L10n.string("live.action.retry", fallback: "Retry locally"))
                await wait(0.2); _ = await terminal(); _ = await idle(); await wait(10)
                result("retry_settled", ["actionInvoked": clicked,
                    "oneRetry": NativeLocalLiveCounters.finalCalls == beforeRetry + 1,
                    "noAutoPaste": NativeLocalLiveCounters.pasteDispatches == beforePaste,
                    "noAutomaticWindow": inspect()["resultVisible"] as? Bool == false,
                    "nonemptyRetainedText": !(inspect()["result"] as? String ?? "").isEmpty,
                    "audioReleased": readMemory()["failedAudioFrames"] as? Int == 0,
                    "leaseReleased": readMemory()["cacheLease"] as? Bool == false])
            }
            NativeLocalLiveCounters.forceNextFinalIncomplete = true
            if unmet.isEmpty, await attempt("failure_short", live: true, expectFailure: true) {
                let discarded = await clickRecovery(L10n.string("live.action.discard", fallback: "Discard"))
                await wait(10)
                result("discard_settled", ["actionInvoked": discarded,
                    "audioReleased": readMemory()["failedAudioFrames"] as? Int == 0,
                    "noRecovery": inspect()["livePhase"] as? String == "none",
                    "leaseReleased": readMemory()["cacheLease"] as? Bool == false])
            }
        } else if pattern == "unload" {
            _ = await attempt("before_unload", live: true)
            stage = "unload"
            let timer = Timer(timeInterval: 0.05, repeats: true) { _ in
                MainActor.assumeIsolated {
                    if self.inspect()["appState"] as? String == "unloaded", NSApp.modalWindow != nil { NSApp.stopModal(withCode: .alertFirstButtonReturn) }
                }
            }
            RunLoop.main.add(timer, forMode: .common); RunLoop.main.add(timer, forMode: .modalPanel)
            let invoked = performMenuAction("unloadOrReloadModel")
            for _ in 0..<200 {
                if inspect()["appState"] as? String == "unloaded" { break }; await wait(0.1)
            }
            timer.invalidate(); await wait(10)
            result("unloaded_settled", ["menuActionInvoked": invoked,
                "modelUnloaded": readMemory()["modelLoaded"] as? Bool == false,
                "activeModelMemoryReleased": (readMemory()["mlxActiveBytes"] as? Int ?? Int.max) < 64 * 1024 * 1024])
            stage = "reload"; key(true); await wait(0.4); key(false); _ = await idle(); await wait(10)
            result("reloaded_settled", ["modelLoaded": readMemory()["modelLoaded"] as? Bool == true])
            if unmet.isEmpty { _ = await attempt("after_reload", live: true) }
        } else if pattern == "polish" {
            let beforePolish = NativeLocalLiveCounters.polishCalls
            AppConfig.shared.textPolishEnabled = true; AppConfig.shared.autoPolishDictationEnabled = true
            record("polish_availability", ["available": TextPolisher.isAvailableCached])
            if TextPolisher.isAvailableCached {
                for attemptIndex in 0..<3 { if !(await attempt("polish_\(attemptIndex)", live: true)) { break } }
                result("polish_calls_verified", ["threePolishStages": NativeLocalLiveCounters.polishCalls == beforePolish + 3])
            }
        } else { unmet.append("unknown_pattern") }
        record("memory_finished", ["automaticChecksPassed": unmet.isEmpty, "unmetChecks": unmet, "pattern": pattern])
    }

    private func clipChecks() async {
        var clips = [audio]
        for index in CommandLine.arguments.indices where CommandLine.arguments[index] == "--qa-extra-audio" && CommandLine.arguments.indices.contains(index + 1) {
            clips.append(URL(fileURLWithPath: CommandLine.arguments[index + 1]))
        }
        var unmet: [String] = []
        for (index, clip) in clips.enumerated() {
            let prefix = "clip_\(index)"
            guard let file = try? AVAudioFile(forReading: clip) else { record(prefix + "_load_failed"); return }
            let duration = Double(file.length) / file.processingFormat.sampleRate
            guard duration > 0, duration < 58 else { record(prefix + "_invalid_duration"); return }
            focusAndClear(); await wait(0.5)
            let beforeFinal = NativeLocalLiveCounters.finalCalls
            let beforePaste = NativeLocalLiveCounters.pasteDispatches
            guard await beginAudio(clip) else { return }
            await wait(duration / 2)
            let early = first.string.isEmpty && second.string.isEmpty
            let draftVisible = !(inspect()["draft"] as? String ?? "").isEmpty
            record(prefix + "_preview", ["audio": clip.lastPathComponent, "noEarlyInsertion": early])
            await wait(duration / 2 + 0.5)
            let draftSeen = draftVisible || !(inspect()["draft"] as? String ?? "").isEmpty
            key(false); stopPlayback(); guard await terminal() else { return }; await wait(0.7)
            let checks = ["pasteObserved": !first.string.isEmpty && first.string == inspect()["result"] as? String,
                          "oneFinalCall": NativeLocalLiveCounters.finalCalls == beforeFinal + 1,
                          "onePasteDispatch": NativeLocalLiveCounters.pasteDispatches == beforePaste + 1,
                          "alternateUntouched": second.string.isEmpty,
                          "noEarlyInsertion": early,
                          "nonemptyLiveDraft": draftSeen]
            var detail: [String: Any] = checks
            detail["audio"] = clip.lastPathComponent
            record(prefix + "_release", detail)
            for (key, passed) in checks where !passed { unmet.append(prefix + "." + key) }
            if CommandLine.arguments.contains("--native-e2e-memory-repeat") {
                await wait(1.5)
                record(prefix + "_idle", ["audio": clip.lastPathComponent])
            }
        }
        record("clips_finished", ["automaticChecksPassed": unmet.isEmpty, "unmetChecks": unmet.sorted()])
    }

    /// Optional second process: the prebuilt disposable document is only a
    /// target and requests no Accessibility or microphone access of its own.
    private func externalDocumentCases() async {
        guard let index = CommandLine.arguments.firstIndex(of: "--external-document-app"),
              CommandLine.arguments.indices.contains(index + 1) else {
            record("external_document_not_configured"); return
        }
        let url = URL(fileURLWithPath: CommandLine.arguments[index + 1]).standardizedFileURL
        let identifier = "com.felix.lamitype.liveE2ERunner"
        guard Bundle(url: url)?.bundleIdentifier == identifier else { record("external_document_invalid_bundle"); return }
        let opener = Process()
        opener.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        opener.arguments = ["-n", url.path, "--args", "--document-only", "--report", output.deletingLastPathComponent().appendingPathComponent("external-document.json").path]
        do { try opener.run() } catch { record("external_document_launch_failed"); return }
        var application: NSRunningApplication?
        for _ in 0..<50 {
            application = NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == identifier && $0.bundleURL?.standardizedFileURL == url }
            if application != nil { break }
            await wait(0.1)
        }
        guard let application else { record("external_document_launch_timeout"); return }
        defer { _ = application.terminate() }
        await wait(0.5)
        let app = AXUIElementCreateApplication(application.processIdentifier)
        func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
            return value
        }
        var fields: [String: AXUIElement] = [:]
        func findFields(_ element: AXUIElement, _ depth: Int) {
            guard depth < 12 else { return }
            if attribute(element, kAXRoleAttribute) as? String == kAXTextAreaRole,
               let label = attribute(element, kAXDescriptionAttribute) as? String,
               ["E2E original field", "E2E alternate field"].contains(label) { fields[label] = element }
            if let children = attribute(element, kAXChildrenAttribute) as? [AXUIElement] {
                for child in children { findFields(child, depth + 1) }
            }
        }
        if let windows = attribute(app, kAXWindowsAttribute) as? [AXUIElement] {
            for window in windows { findFields(window, 0) }
        }
        guard let original = fields["E2E original field"], let alternate = fields["E2E alternate field"] else {
            record("external_document_fields_unavailable"); return
        }
        func text(_ element: AXUIElement) -> String { attribute(element, kAXValueAttribute) as? String ?? "" }
        func clearAndFocus() -> Bool {
            dismissResult()
            let a = AXUIElementSetAttributeValue(original, kAXValueAttribute as CFString, "" as CFString)
            let b = AXUIElementSetAttributeValue(alternate, kAXValueAttribute as CFString, "" as CFString)
            _ = application.activate(options: [.activateIgnoringOtherApps])
            let focus = AXUIElementSetAttributeValue(original, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            return a == .success && b == .success && focus == .success
        }
        setPreview(true)
        guard clearAndFocus() else { record("external_document_focus_failed"); return }
        await wait(0.5)
        let beforeNormal = NativeLocalLiveCounters.pasteDispatches
        guard await beginAudio(audio) else { return }
        await wait(8); key(false); stopPlayback(); guard await terminal() else { return }; await wait(0.7)
        record("external_normal_release", ["externalFirstField": text(original), "externalSecondField": text(alternate),
                                            "pasteObserved": !text(original).isEmpty && text(original) == inspect()["result"] as? String,
                                            "onePasteDispatch": NativeLocalLiveCounters.pasteDispatches == beforeNormal + 1,
                                            "noAutomaticResultWindow": inspect()["resultVisible"] as? Bool == false,
                                            "alternateUntouched": text(alternate).isEmpty])
        guard clearAndFocus() else { record("external_document_focus_failed"); return }
        await wait(0.5)
        let beforeChanged = NativeLocalLiveCounters.pasteDispatches
        guard await beginAudio(audio) else { return }
        await wait(1)
        guard AXUIElementSetAttributeValue(alternate, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success else {
            key(false); stopPlayback(); record("external_field_change_failed"); return
        }
        await wait(7); key(false); stopPlayback(); guard await terminal() else { return }; await wait(0.7)
        record("external_field_changed", ["externalFirstField": text(original), "externalSecondField": text(alternate),
                                          "noUnexpectedPaste": text(original).isEmpty && text(alternate).isEmpty,
                                          "nonemptyCopyResult": !(inspect()["result"] as? String ?? "").isEmpty,
                                 "noAutomaticResultWindow": inspect()["resultVisible"] as? Bool == false,
                                 "neutralNoticeVisible": inspect()["noticeVisible"] as? Bool == true && inspect()["failureNotice"] as? Bool == false,
                                          "noPasteDispatch": NativeLocalLiveCounters.pasteDispatches == beforeChanged,
                                          "originalAppStillFront": inspect()["frontmostBundleID"] as? String == "com.felix.lamitype.liveE2ERunner"])
    }
}
#endif
