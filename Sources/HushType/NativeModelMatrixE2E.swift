#if DEBUG
import AppKit
import AVFoundation

/// `--native-model-matrix`: Fast / Optimized end-to-end through the real
/// Right Option hotkey, capture path, Standard and Live modes, the Settings
/// picker and the menu bar. Clips: `--matrix-clip id|forced|kind|path`.
/// Phase: `--matrix-phase main|persist|missing|fallback`.
extension NativeLocalLiveE2E {
    struct MatrixClip {
        let id: String
        let forced: String
        let kind: String
        let url: URL
        let duration: Double
    }

    /// Letters outside Latin, Han and Bopomofo: Thai, Arabic, Hangul,
    /// Cyrillic, kana and so on. Lamitype users dictate Chinese and English.
    static func hasWrongScript(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            guard scalar.properties.isAlphabetic else { return false }
            let v = scalar.value
            let allowed = v < 0x250 || (0x1E00...0x1EFF).contains(v) || (0x2E80...0x2FDF).contains(v)
                || (0x3005...0x3007).contains(v) || (0x3021...0x3029).contains(v) || (0x3100...0x312F).contains(v)
                || (0x31A0...0x31BF).contains(v) || (0x3400...0x4DBF).contains(v) || (0x4E00...0x9FFF).contains(v)
                || (0xF900...0xFAFF).contains(v) || (0xFF21...0xFF3A).contains(v) || (0xFF41...0xFF5A).contains(v)
                || (0x20000...0x3FFFF).contains(v)
            return !allowed
        }
    }

    private var matrixClips: [MatrixClip] {
        let args = CommandLine.arguments
        return args.indices.compactMap { index -> MatrixClip? in
            guard args[index] == "--matrix-clip", args.indices.contains(index + 1) else { return nil }
            let parts = args[index + 1].split(separator: "|", maxSplits: 3).map(String.init)
            guard parts.count == 4, let file = try? AVAudioFile(forReading: URL(fileURLWithPath: parts[3])) else { return nil }
            return MatrixClip(id: parts[0], forced: parts[1], kind: parts[2], url: URL(fileURLWithPath: parts[3]),
                              duration: Double(file.length) / file.processingFormat.sampleRate)
        }
    }

    private func argument(_ name: String) -> String? {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: name), args.indices.contains(index + 1) else { return nil }
        return args[index + 1]
    }

    private var now: Double { ProcessInfo.processInfo.systemUptime }

    // MARK: - Dictation

    /// One hold-and-release dictation into the first test field.
    func matrixDictate(_ clip: MatrixClip, live: Bool, language: String?, tag: String,
                       duringRecording: (() async -> [String: Any])? = nil,
                       afterRelease: (() async -> [String: Any])? = nil) async -> [String: Any] {
        setPreview(live)
        AppConfig.shared.floatingOverlayEnabled = true
        AppConfig.shared.language = language
        focusAndClear(); await wait(0.5)
        let model = inspect()["loadedModelID"] as? String ?? ""
        let beforeFinal = NativeLocalLiveCounters.finalCalls
        let beforePaste = NativeLocalLiveCounters.pasteDispatches
        let pressed = now
        guard await beginAudio(clip.url) else {
            var failed: [String: Any] = ["ok": false, "reason": "recording not admitted"]
            failed["clip"] = clip.id; failed["mode"] = live ? "live" : "standard"
            record(tag, failed); return failed
        }
        var drafts: [[String: Any]] = []
        var lastDraft = ""
        var extra: [String: Any] = [:]
        var probed = false
        let releaseAt = pressed + clip.duration + 0.8
        while now < releaseAt {
            let draft = inspect()["draft"] as? String ?? ""
            if draft != lastDraft {
                drafts.append(["t": (now - pressed).rounded(toPlaces: 3), "text": draft]); lastDraft = draft
            }
            if !probed, let duringRecording, now > pressed + min(1.0, clip.duration / 2) {
                probed = true
                extra["duringRecording"] = await duringRecording()
            }
            await wait(0.05)
        }
        let earlyInsertion = !first.string.isEmpty || !second.string.isEmpty
        key(false); stopPlayback()
        let released = now
        if let afterRelease { extra["afterRelease"] = await afterRelease() }
        var finalSeconds: Double?
        for _ in 0..<1500 {
            if !first.string.isEmpty { finalSeconds = now - released; break }
            await wait(0.02)
        }
        for _ in 0..<300 {
            let row = inspect()
            if row["appState"] as? String == "idle", ["none", "recovery"].contains(row["livePhase"] as? String ?? "") { break }
            await wait(0.05)
        }
        await wait(0.3)
        let text = first.string
        let nonempty = drafts.compactMap { $0["text"] as? String }.filter { !$0.isEmpty }
        var row: [String: Any] = [
            "ok": finalSeconds != nil && !earlyInsertion,
            "clip": clip.id, "kind": clip.kind, "clipSeconds": clip.duration.rounded(toPlaces: 2),
            "mode": live ? "live" : "standard", "language": language ?? "auto",
            "model": model, "finalText": text,
            "finalSeconds": finalSeconds.map { $0.rounded(toPlaces: 3) } ?? NSNull(),
            "firstDraftSeconds": (drafts.first { !($0["text"] as? String ?? "").isEmpty }?["t"]) ?? NSNull(),
            "draftUpdates": nonempty.count, "drafts": drafts,
            "earlyInsertion": earlyInsertion,
            "wrongScriptFinal": Self.hasWrongScript(text),
            "wrongScriptDraft": nonempty.contains { Self.hasWrongScript($0) },
            "traditionalStable": ChineseConverter.convert(text, enabled: true) == text,
            "hasPunctuation": text.unicodeScalars.contains { "，。？！、,.?!".unicodeScalars.contains($0) },
            "finalCalls": NativeLocalLiveCounters.finalCalls - beforeFinal,
            "pasteDispatches": NativeLocalLiveCounters.pasteDispatches - beforePaste,
            "footprintMiB": inspect()["appFootprintMiB"] ?? NSNull()]
        if let letter = text.first(where: { $0.isLetter && $0.isASCII }) { row["startsUppercase"] = letter.isUppercase }
        if live {
            row["oneFinalCall"] = NativeLocalLiveCounters.finalCalls == beforeFinal + 1
            row["fieldMatchesLiveResult"] = !text.isEmpty && text == inspect()["result"] as? String
            row["lastDraft"] = nonempty.last ?? ""
        }
        for (key, value) in extra { row[key] = value }
        record(tag, row)
        return row
    }

    // MARK: - Settings and menu

    private func axValue(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private func axDescendants(_ element: AXUIElement, depth: Int = 0, into found: inout [AXUIElement]) {
        guard depth < 30, found.count < 4000 else { return }
        found.append(element)
        for child in axValue(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
            axDescendants(child, depth: depth + 1, into: &found)
        }
    }

    private func settingsElements() -> [AXUIElement] {
        let app = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
        let title = L10n.string("settings.window.title", fallback: "Settings")
        var all: [AXUIElement] = []
        for window in axValue(app, kAXWindowsAttribute) as? [AXUIElement] ?? [] {
            guard (axValue(window, kAXTitleAttribute) as? String)?.hasPrefix(title) == true
                    || (axValue(window, kAXTitleAttribute) as? String)?.contains(L10n.string("settings.pane.dictation", fallback: "Dictation")) == true
            else { continue }
            axDescendants(window, into: &all)
        }
        return all
    }

    /// Runs `body` from a main-queue callback with the test Task suspended, as
    /// a real UI event does, so AppKit and SwiftUI can service AX calls.
    private func onMainQueue<T>(_ body: @escaping @MainActor () -> T) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume(returning: MainActor.assumeIsolated { body() }) }
        }
    }

    func openSettingsDictation() async {
        LamitypeSettingsWindowController.shared.presentAndFocus(pane: .dictation)
        await wait(1.2)
    }

    func closeSettings() {
        let title = L10n.string("settings.window.title", fallback: "Settings")
        for window in NSApp.windows where window.isVisible && window.title.hasPrefix(title) { window.close() }
    }

    /// Saves the Settings window's own content view as a PNG (no screen capture).
    func snapshotSettings(_ name: String) {
        let title = L10n.string("settings.window.title", fallback: "Settings")
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.title.hasPrefix(title) }),
              let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        let folder = output.deletingLastPathComponent().appendingPathComponent("settings-screenshots")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: folder.appendingPathComponent(name + ".png"))
        }
    }

    /// Presses the Fast or Optimized radio button in the open Settings window.
    func pressSettingsModel(_ model: AppConfig.LocalModel) async -> [String: Any] {
        await onMainQueue { [self] in
            let elements = settingsElements()
            let radios = elements.filter { axValue($0, kAXRoleAttribute) as? String == kAXRadioButtonRole }
            let labelled = radios.filter { radio in
                [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueDescriptionAttribute].contains { name in
                    (axValue(radio, name) as? String)?.contains(model.displayName) == true
                }
            }
            var target = labelled.first
            if target == nil,
               let group = elements.first(where: { axValue($0, kAXIdentifierAttribute) as? String == "local-model-picker" }) {
                var inner: [AXUIElement] = []
                axDescendants(group, into: &inner)
                let groupRadios = inner.filter { axValue($0, kAXRoleAttribute) as? String == kAXRadioButtonRole }
                let index = model == .fast ? 0 : 1
                if groupRadios.indices.contains(index) { target = groupRadios[index] }
            }
            guard let target else {
                return ["pressed": false, "radioCount": radios.count, "elementCount": elements.count]
            }
            let enabled = axValue(target, kAXEnabledAttribute) as? Bool ?? false
            let result = AXUIElementPerformAction(target, kAXPressAction as CFString)
            return ["pressed": result == .success, "enabled": enabled, "radioCount": radios.count, "matchedByLabel": !labelled.isEmpty]
        }
    }

    /// Static texts in the Settings window, for the failure box and notices.
    func settingsTexts() async -> [String] {
        await onMainQueue { [self] in
            settingsElements().compactMap { element -> String? in
                guard axValue(element, kAXRoleAttribute) as? String == kAXStaticTextRole else { return nil }
                return axValue(element, kAXValueAttribute) as? String ?? axValue(element, kAXTitleAttribute) as? String
            }
        }
    }

    func pressSettingsButton(_ title: String) async -> Bool {
        await onMainQueue { [self] in
            guard let button = settingsElements().first(where: {
                axValue($0, kAXRoleAttribute) as? String == kAXButtonRole
                    && (axValue($0, kAXTitleAttribute) as? String == title || axValue($0, kAXDescriptionAttribute) as? String == title)
            }) else { return false }
            return AXUIElementPerformAction(button, kAXPressAction as CFString) == .success
        }
    }

    func menuSelect(_ model: AppConfig.LocalModel) -> Bool {
        performProviderMenuAction?("selectLocalModel:", model.rawValue) ?? false
    }

    /// Waits for a running switch to end. Returns the phases seen.
    func waitForSwitch(timeout: Double = 180) async -> [String] {
        var seen: [String] = []
        let end = now + timeout
        while now < end {
            let phase = String(describing: LocalModelSwitcher.shared.phase)
            if seen.last != phase { seen.append(phase) }
            if !LocalModelSwitcher.shared.isSwitching { break }
            await wait(0.05)
        }
        return seen
    }

    private func modelState() -> [String: Any] {
        var state: [String: Any] = ["loadedModelID": inspect()["loadedModelID"] ?? "",
            "saved": AppConfig.shared.localModel.rawValue,
            "active": LocalModelSwitcher.shared.active.rawValue,
            "phase": String(describing: LocalModelSwitcher.shared.phase),
            "footprintMiB": inspect()["appFootprintMiB"] ?? NSNull()]
        if let menu = modelMenuSnapshot?() { state["menu"] = menu }
        return state
    }

    private func source(_ model: AppConfig.LocalModel) -> String { AppConfig.shared.modelSource(for: model) }

    // MARK: - Phases

    func modelMatrixChecks() async {
        let clips = matrixClips
        let phase = argument("--matrix-phase") ?? "main"
        var unmet: [String] = []
        let savedLanguage = AppConfig.shared.language
        let savedPolish = AppConfig.shared.textPolishEnabled
        let savedAutoPolish = AppConfig.shared.autoPolishDictationEnabled
        defer {
            AppConfig.shared.language = savedLanguage
            AppConfig.shared.textPolishEnabled = savedPolish
            AppConfig.shared.autoPolishDictationEnabled = savedAutoPolish
            DictionaryReplacer.setDictionaryFileURLForTesting(nil)
            closeSettings()
        }
        AppConfig.shared.autoPolishDictationEnabled = false
        func check(_ name: String, _ passed: Bool) { if !passed { unmet.append(name) } }
        record("matrix_start", ["phase": phase, "clips": clips.map { "\($0.id) \($0.kind) \(String(format: "%.2f", $0.duration))s" },
            "numberConversion": AppConfig.shared.numberConversionEnabled,
            "chineseConversion": AppConfig.shared.chineseConversionEnabled,
            "punctuationMode": String(describing: AppConfig.shared.punctuationMode),
            "polishAvailable": TextPolisher.isAvailableCached, "state": modelState()])
        guard !clips.isEmpty else { record("matrix_finished", ["automaticChecksPassed": false, "unmetChecks": ["no clips"]]); return }
        let main = clips.filter { $0.kind != "short" }
        let short = clips.filter { $0.kind == "short" }
        let anyClip = main.first { $0.kind == "cs" } ?? clips[0]

        func dictationBlock(_ name: String) async {
            for language in ["auto", "forced"] {
                let firstOfKind = ["zh", "en", "cs"].compactMap { kind in main.first { $0.kind == kind } }
                let set = language == "auto" ? clips : firstOfKind + Array(short.prefix(2))
                for clip in set {
                    for live in [false, true] {
                        let row = await matrixDictate(clip, live: live, language: language == "auto" ? nil : clip.forced,
                                                      tag: "\(name)_\(language)_\(clip.id)_\(live ? "live" : "std")")
                        let id = "\(name).\(language).\(clip.id).\(live ? "live" : "std")"
                        check(id + ".ok", row["ok"] as? Bool == true)
                        check(id + ".wrongScriptFinal", row["wrongScriptFinal"] as? Bool == false)
                        check(id + ".wrongScriptDraft", row["wrongScriptDraft"] as? Bool == false)
                        if live {
                            check(id + ".oneFinalCall", row["oneFinalCall"] as? Bool == true)
                            check(id + ".fieldMatchesLiveResult", row["fieldMatchesLiveResult"] as? Bool == true)
                        }
                    }
                }
            }
        }

        func postProcessingBlock(_ name: String) async {
            let dictionary = output.deletingLastPathComponent().appendingPathComponent("matrix-dictionary.txt")
            try? "chemistry -> 化學\nbasketball -> 籃球\nengineering -> 工程\n".write(to: dictionary, atomically: true, encoding: .utf8)
            DictionaryReplacer.setDictionaryFileURLForTesting(dictionary)
            for clip in main where clip.kind == "cs" {
                for live in [false, true] {
                    let row = await matrixDictate(clip, live: live, language: nil, tag: "\(name)_dictionary_\(clip.id)_\(live ? "live" : "std")")
                    let text = (row["finalText"] as? String ?? "").lowercased()
                    let replaced = !text.contains("chemistry") && !text.contains("basketball") && !text.contains("engineering")
                    record("\(name)_dictionary_check_\(clip.id)_\(live ? "live" : "std")", ["noSourceWordsLeft": replaced])
                    check("\(name).dictionary.\(clip.id).\(live ? "live" : "std")", replaced)
                }
            }
            DictionaryReplacer.setDictionaryFileURLForTesting(nil)
            try? FileManager.default.removeItem(at: dictionary)
            guard TextPolisher.isAvailableCached else { record("\(name)_polish_unavailable"); return }
            AppConfig.shared.textPolishEnabled = true; AppConfig.shared.autoPolishDictationEnabled = true
            for live in [false, true] {
                let before = NativeLocalLiveCounters.polishCalls
                let row = await matrixDictate(anyClip, live: live, language: nil, tag: "\(name)_polish_\(live ? "live" : "std")")
                record("\(name)_polish_check_\(live ? "live" : "std")", ["polishCalls": NativeLocalLiveCounters.polishCalls - before,
                    "ok": row["ok"] as? Bool == true])
                check("\(name).polish.\(live ? "live" : "std")", row["ok"] as? Bool == true)
            }
            AppConfig.shared.autoPolishDictationEnabled = false; AppConfig.shared.textPolishEnabled = savedPolish
        }

        func stabilityBlock(_ name: String, count: Int) async {
            var footprints: [Double] = []
            for index in 0..<count {
                let clip = clips[index % clips.count]
                let row = await matrixDictate(clip, live: index % 2 == 0, language: nil, tag: "\(name)_stability_\(index)")
                check("\(name).stability.\(index).ok", row["ok"] as? Bool == true)
                check("\(name).stability.\(index).wrongScript", row["wrongScriptFinal"] as? Bool == false && row["wrongScriptDraft"] as? Bool == false)
                if let value = row["footprintMiB"] as? Double { footprints.append(value) }
                else if let value = row["footprintMiB"] as? Int { footprints.append(Double(value)) }
            }
            let settled = footprints.count >= 6 ? Array(footprints.dropFirst(3)) : footprints
            let growth = (settled.last ?? 0) - (settled.first ?? 0)
            record("\(name)_stability_summary", ["count": count, "footprintsMiB": footprints,
                "growthAfterWarmupMiB": growth, "maxMiB": footprints.max() ?? 0])
            check("\(name).stability.memoryGrowth", growth < 300)
        }

        switch phase {
        case "main":
            check("launch.fastLoaded", inspect()["loadedModelID"] as? String == source(.fast))
            record("main_launch", ["state": modelState()])
            await dictationBlock("fast")
            await postProcessingBlock("fast")
            await stabilityBlock("fast", count: Int(argument("--matrix-stability") ?? "20") ?? 20)

            // Switch in Settings while idle, right after a dictation.
            _ = await matrixDictate(anyClip, live: true, language: nil, tag: "before_settings_switch")
            await openSettingsDictation()
            snapshotSettings("main_before_switch")
            let start = now
            let press = await pressSettingsModel(.optimized)
            let phases = await waitForSwitch()
            let switched = inspect()["loadedModelID"] as? String == source(.optimized)
            record("settings_switch_to_optimized", ["press": press, "phases": phases, "seconds": now - start,
                "switched": switched, "state": modelState(), "settingsTexts": await settingsTexts()])
            check("settings.switchToOptimized", switched && AppConfig.shared.localModel == .optimized)
            snapshotSettings("main_after_switch_to_optimized")
            closeSettings()

            await dictationBlock("optimized")
            await postProcessingBlock("optimized")
            await stabilityBlock("optimized", count: Int(argument("--matrix-stability") ?? "20") ?? 20)

            // Switch attempts during an active recording and during the final pass.
            await openSettingsDictation()
            for live in [false, true] {
                let row = await matrixDictate(anyClip, live: live, language: nil, tag: "busy_attempt_\(live ? "live" : "std")",
                    duringRecording: { [self] in
                        let menu = menuSelect(.fast)
                        let settings = await pressSettingsModel(.fast)
                        await wait(0.3)
                        return ["menuAccepted": menu, "settingsPress": settings, "state": modelState(),
                                "busyNoticeShown": await settingsTexts().contains(L10n.string("settings.local_model.busy",
                                    fallback: "Finish the current dictation before switching models."))]
                    },
                    afterRelease: { [self] in
                        let appState = inspect()["appState"] ?? ""
                        let menu = menuSelect(.fast)
                        let direct = LocalModelSwitcher.shared.select(.fast)
                        return ["menuAccepted": menu, "switcherAccepted": direct, "appStateAtAttempt": appState, "state": modelState()]
                    })
                snapshotSettings("busy_after_\(live ? "live" : "std")")
                let during = row["duringRecording"] as? [String: Any] ?? [:]
                let state = during["state"] as? [String: Any] ?? [:]
                let id = "busy.\(live ? "live" : "std")"
                check(id + ".menuRefused", during["menuAccepted"] as? Bool == false)
                check(id + ".noSwitchDuringRecording", state["loadedModelID"] as? String == source(.optimized)
                      && state["phase"] as? String == "idle")
                check(id + ".sessionCompleted", row["ok"] as? Bool == true)
                // A switch accepted right after release must not land mid-final; let it finish, then restore.
                _ = await waitForSwitch()
                if AppConfig.shared.localModel != .optimized || inspect()["loadedModelID"] as? String != source(.optimized) {
                    record(id + "_post_release_switch_landed", ["state": modelState()])
                    _ = LocalModelSwitcher.shared.select(.optimized); _ = await waitForSwitch()
                }
            }
            closeSettings()

            // Menu: to Fast right after a dictation, then back to Optimized.
            for target in [AppConfig.LocalModel.fast, .optimized] {
                _ = await matrixDictate(anyClip, live: false, language: nil, tag: "before_menu_switch_\(target.rawValue)")
                let start = now
                let accepted = menuSelect(target)
                let phases = await waitForSwitch()
                let switched = inspect()["loadedModelID"] as? String == source(target)
                record("menu_switch_to_\(target.rawValue)", ["accepted": accepted, "phases": phases,
                    "seconds": now - start, "switched": switched, "state": modelState()])
                check("menu.switchTo.\(target.rawValue)", accepted && switched && AppConfig.shared.localModel == target)
                let after = await matrixDictate(anyClip, live: true, language: nil, tag: "after_menu_switch_\(target.rawValue)")
                check("menu.dictateAfter.\(target.rawValue)", after["ok"] as? Bool == true && after["model"] as? String == source(target))
            }

        case "persist":
            let loaded = inspect()["loadedModelID"] as? String
            record("persist_launch", ["state": modelState()])
            check("persist.optimizedLoadedAtLaunch", loaded == source(.optimized) && AppConfig.shared.localModel == .optimized)
            let first = await matrixDictate(anyClip, live: true, language: nil, tag: "persist_dictate_optimized")
            check("persist.dictateOptimized", first["ok"] as? Bool == true)
            await openSettingsDictation()
            let press = await pressSettingsModel(.fast)
            let phases = await waitForSwitch()
            snapshotSettings("persist_after_switch_to_fast")
            record("persist_settings_switch_to_fast", ["press": press, "phases": phases, "state": modelState()])
            check("persist.settingsSwitchToFast", inspect()["loadedModelID"] as? String == source(.fast) && AppConfig.shared.localModel == .fast)
            closeSettings()
            let second = await matrixDictate(anyClip, live: false, language: nil, tag: "persist_dictate_fast")
            check("persist.dictateFast", second["ok"] as? Bool == true && second["model"] as? String == source(.fast))

        case "missing":
            record("missing_launch", ["state": modelState(), "optimizedOnDisk": LocalModelSwitcher.shared.isOnDisk(.optimized)])
            check("missing.fastLoadedAtLaunch", inspect()["loadedModelID"] as? String == source(.fast))
            check("missing.optimizedNotOnDisk", !LocalModelSwitcher.shared.isOnDisk(.optimized))
            let accepted = menuSelect(.optimized)
            let phases = await waitForSwitch(timeout: 120)
            await openSettingsDictation()
            let texts = await settingsTexts()
            let failure = L10n.format("settings.local_model.failed",
                "Couldn’t download the %1$@ model. Check your connection, then try again. Lamitype is still using %2$@.",
                arguments: [AppConfig.LocalModel.optimized.shortName, AppConfig.LocalModel.fast.shortName])
            snapshotSettings("missing_failed")
            record("missing_select_optimized", ["accepted": accepted, "phases": phases, "state": modelState(), "settingsTexts": texts])
            check("missing.downloadAttempted", phases.contains { $0.contains("downloading: true") })
            check("missing.failedState", LocalModelSwitcher.shared.phase == .failed(.optimized))
            check("missing.failureBoxShown", texts.contains(failure))
            check("missing.fastStillLoaded", inspect()["loadedModelID"] as? String == source(.fast) && AppConfig.shared.localModel == .fast)
            closeSettings()
            for live in [false, true] {
                let row = await matrixDictate(anyClip, live: live, language: nil, tag: "missing_dictate_fast_\(live ? "live" : "std")")
                check("missing.fastWorks.\(live ? "live" : "std")", row["ok"] as? Bool == true && row["model"] as? String == source(.fast))
            }
            await openSettingsDictation()
            let retried = await pressSettingsButton(L10n.string("settings.local_model.try_again", fallback: "Try Again"))
            let retryPhases = await waitForSwitch(timeout: 120)
            record("missing_try_again", ["pressed": retried, "phases": retryPhases, "state": modelState()])
            check("missing.tryAgainRuns", retried && retryPhases.contains { $0.contains("switching") })
            check("missing.tryAgainFailsCleanly", LocalModelSwitcher.shared.phase == .failed(.optimized)
                  && inspect()["loadedModelID"] as? String == source(.fast))
            closeSettings()
            // Cancel a download from the menu.
            let again = menuSelect(.optimized)
            let cancelled = performMenuAction("cancelModelDownload")
            await wait(0.5)
            record("missing_cancel", ["selectAccepted": again, "cancelInvoked": cancelled, "state": modelState()])
            check("missing.cancelLeavesFast", LocalModelSwitcher.shared.active == .fast && inspect()["loadedModelID"] as? String == source(.fast))
            let selectFast = menuSelect(.fast)
            record("missing_choose_fast", ["accepted": selectFast, "state": modelState()])
            check("missing.chooseFastClears", LocalModelSwitcher.shared.phase == .idle)

        case "fallback":
            record("fallback_launch", ["state": modelState()])
            check("fallback.fastLoaded", inspect()["loadedModelID"] as? String == source(.fast))
            check("fallback.failedShown", LocalModelSwitcher.shared.phase == .failed(.optimized) && LocalModelSwitcher.shared.active == .fast)
            check("fallback.savedChoiceKept", AppConfig.shared.localModel == .optimized)
            await openSettingsDictation()
            snapshotSettings("fallback_launch")
            record("fallback_settings", ["settingsTexts": await settingsTexts()])
            closeSettings()
            for live in [false, true] {
                let row = await matrixDictate(anyClip, live: live, language: nil, tag: "fallback_dictate_\(live ? "live" : "std")")
                check("fallback.fastWorks.\(live ? "live" : "std")", row["ok"] as? Bool == true && row["model"] as? String == source(.fast))
            }
            let chose = menuSelect(.fast)
            record("fallback_choose_fast", ["accepted": chose, "state": modelState()])
            check("fallback.chooseFastSaves", AppConfig.shared.localModel == .fast && LocalModelSwitcher.shared.phase == .idle)

        default:
            unmet.append("unknown phase \(phase)")
        }
        record("matrix_finished", ["automaticChecksPassed": unmet.isEmpty, "unmetChecks": unmet, "phase": phase, "state": modelState()])
    }
}

private extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let scale = Foundation.pow(10.0, Double(places))
        return (self * scale).rounded() / scale
    }
}
#endif
