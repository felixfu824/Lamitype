import AppKit
import AVFoundation
import Carbon.HIToolbox
import XCTest
@testable import HushType

@MainActor
final class SystemSeamContractTests: XCTestCase {
    func testS1ModifierReaders() async throws {
        let folder = try contract("S1")
        try requireAccessibility()
        var evidence: [[String: Any]] = []
        defer { record(evidence, in: folder) }
        for key in DictationKey.allCases {
            let manager = HotkeyManager(bindings: ShortcutBindings(
                dictation: key, liveCaption: .off))
            let down = try modifier(key, down: true)
            let up = try modifier(key, down: false)
            down.post(tap: .cghidEventTap)
            do {
                defer { up.post(tap: .cghidEventTap) }
                let start = ContinuousClock.now
                for sample in 1...5 {
                    try await Task.sleep(until: start + .milliseconds(sample * 500))
                    let snapshot = readers(key, manager: manager, phase: "held")
                    evidence.append(snapshot)
                    XCTAssertEqual(snapshot["effectiveDown"] as? Bool, true, "\(key) at sample \(sample)")
                }
            }
            try await Task.sleep(for: .milliseconds(300))
            let snapshot = readers(key, manager: manager, phase: "released")
            evidence.append(snapshot)
            XCTAssertEqual(snapshot["effectiveDown"] as? Bool, false, "\(key) after release")
        }
    }

    func testS2SecureInputAndTapVisibility() async throws {
        let folder = try contract("S2")
        try requireAccessibility()
        let target = try startTarget(in: folder)
        defer { stopTarget(target, in: folder) }
        _ = try await targetState(in: folder) { $0["focus"] == "first" }
        guard !SecureInputProbe.isActive() else { throw XCTSkip("Another process owns Secure Input") }
        let seen = SeamTapEvents()
        let tap = try XCTUnwrap(attachTap(seen, options: .listenOnly))
        defer { CFMachPortInvalidate(tap) }
        try await postCommandC()
        let normal = seen.types
        XCTAssertTrue(normal.contains(CGEventType.keyDown.rawValue))
        seen.types = []

        let enabled = EnableSecureEventInput()
        XCTAssertEqual(enabled, noErr)
        guard enabled == noErr else { return }
        let before = SecureInputProbe.isActive()
        do {
            defer { XCTAssertEqual(DisableSecureEventInput(), noErr) }
            try await postCommandC()
        }
        let after = SecureInputProbe.isActive()
        record(["secureInputOn": before, "secureInputAfterRelease": after,
                "normalTapEventTypes": normal, "secureTapEventTypes": seen.types], in: folder)
        XCTAssertTrue(before)
        XCTAssertFalse(after)
    }

    func testS3PasteboardAndPasteDelivery() async throws {
        let folder = try contract("S3")
        try requireAccessibility()
        let target = try startTarget(in: folder)
        defer { stopTarget(target, in: folder) }
        _ = try await targetState(in: folder) { $0["focus"] == "first" }
        let board = NSPasteboard.general
        let original = board.pasteboardItems?.map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        } ?? []
        defer {
            board.clearContents()
            board.writeObjects(original.map { data in
                let item = NSPasteboardItem()
                for (type, value) in data { item.setData(value, forType: type) }
                return item
            })
        }
        var evidence: [[String: Any]] = []
        defer { record(evidence, in: folder) }
        for method in ["HID", "PID"] {
            try "clear".write(to: folder.appendingPathComponent("command.txt"), atomically: true, encoding: .utf8)
            _ = try await targetState(in: folder) { $0["field1"] == "" }
            let fixture = "Lamitype seam " + method
            let before = board.changeCount
            let began = Date().timeIntervalSince1970
            if method == "HID" {
                TextInserter.insert(fixture)
            } else {
                XCTAssertTrue(TextInserter.insertLive(fixture, targetPID: target.processIdentifier, verify: { true }))
            }
            let pasted = try await targetState(in: folder) { $0["field1"]?.isEmpty == false }
            try await Task.sleep(for: .milliseconds(300))
            let settled = try await targetState(in: folder) { _ in true }
            let arrival = try XCTUnwrap(pasted["field1ChangedAt"].flatMap(Double.init)) - began
            evidence.append(["method": method, "pasteboardBefore": before, "pasteboardAfter": board.changeCount,
                             "arrivalSeconds": arrival, "field1": settled["field1"] ?? "",
                             "field2": settled["field2"] ?? ""])
            XCTAssertGreaterThan(board.changeCount, before)
            XCTAssertGreaterThanOrEqual(arrival, 0)
            XCTAssertLessThanOrEqual(arrival, 0.5)
            XCTAssertEqual(settled["field1"], fixture)
            XCTAssertEqual(settled["field2"], "")
        }
    }

    func testS4AccessibilityFocus() async throws {
        let folder = try contract("S4")
        try requireAccessibility()
        let target = try startTarget(in: folder)
        defer { stopTarget(target, in: folder) }
        _ = try await targetState(in: folder) { $0["focus"] == "first" }
        let pid = target.processIdentifier
        let firstPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let first = LivePasteAXSnapshot(pid: pid, capturing: true)
        try "focus-second".write(to: folder.appendingPathComponent("command.txt"), atomically: true, encoding: .utf8)
        _ = try await targetState(in: folder) { $0["focus"] == "second" }
        let started = ContinuousClock.now
        let nextPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let second = LivePasteAXSnapshot(pid: pid, capturing: false, readsWindowID: false)
        let windowMatches = LivePasteAXSnapshot.equal(first.window, second.window)
        let elementMatches = LivePasteAXSnapshot.equal(first.element, second.element)
        let observation = try await observeS4Focus(
            before: first.windowID,
            axWindowChanged: first.window != nil && second.window != nil && !windowMatches,
            axElementChanged: first.element != nil && second.element != nil && !elementMatches,
            elapsed: { started.duration(to: .now) },
            wait: { try await Task.sleep(for: $0, tolerance: .zero) },
            readWindowID: { LivePasteAXSnapshot(pid: pid, capturing: false).windowID }
        )
        record(["frontmostBefore": firstPID ?? 0, "frontmostAfter": nextPID ?? 0,
                "windowIDBefore": first.windowID ?? 0, "windowIDAfter": observation.samples.last?.id ?? 0,
                "windowIDSamples": observation.samples.map { sample in
                    ["elapsedMilliseconds": milliseconds(sample.elapsed),
                     "windowID": sample.id.map { $0 as Any } ?? NSNull()]
                },
                "windowIDLagMilliseconds": observation.lag.map { milliseconds($0) as Any } ?? NSNull(),
                "windowMatches": windowMatches, "elementMatches": elementMatches,
                "firstHasWindow": first.window != nil, "secondHasWindow": second.window != nil,
                "firstHasElement": first.element != nil, "secondHasElement": second.element != nil], in: folder)
        XCTAssertEqual(firstPID, pid)
        XCTAssertEqual(nextPID, pid)
        XCTAssertNotNil(first.windowID)
        XCTAssertTrue(observation.passed, observation.axChanged
            ? "CG window ID must change within 100 ms"
            : "Both AX window and element must exist and change identity")
    }

    func testFocusPollingS4() async throws {
        let delayed = try await simulatedS4Focus(changeAt: .milliseconds(25))
        XCTAssertTrue(delayed.passed)
        XCTAssertEqual(delayed.lag, .milliseconds(25))
        XCTAssertEqual(delayed.samples.map(\.id), [10, 10, 10, 10, 10, 11])

        let unchanged = try await simulatedS4Focus(changeAt: .milliseconds(101))
        XCTAssertFalse(unchanged.passed)
        XCTAssertNil(unchanged.lag)
        XCTAssertEqual(unchanged.samples.last?.elapsed, .milliseconds(100))

        let sameWindow = try await simulatedS4Focus(changeAt: .milliseconds(25), axWindowChanged: false)
        XCTAssertFalse(sameWindow.passed)
        let sameElement = try await simulatedS4Focus(changeAt: .milliseconds(25), axElementChanged: false)
        XCTAssertFalse(sameElement.passed)
    }

    private struct S4FocusObservation {
        var samples: [(elapsed: Duration, id: CGWindowID?)] = []
        var lag: Duration?
        let axChanged: Bool

        var passed: Bool { lag != nil && axChanged }
    }

    private func observeS4Focus(
        before: CGWindowID?,
        axWindowChanged: Bool,
        axElementChanged: Bool,
        elapsed: () -> Duration,
        wait: (Duration) async throws -> Void,
        readWindowID: () -> CGWindowID?
    ) async throws -> S4FocusObservation {
        let limit = Duration.milliseconds(100)
        var observation = S4FocusObservation(axChanged: axWindowChanged && axElementChanged)
        while elapsed() <= limit {
            let id = readWindowID()
            let sampledAt = elapsed()
            observation.samples.append((sampledAt, id))
            if let before, let id, id != before, sampledAt <= limit {
                observation.lag = sampledAt
                break
            }
            let remaining = limit - elapsed()
            guard remaining > .zero else { break }
            try await wait(min(.milliseconds(5), remaining))
        }
        return observation
    }

    private func simulatedS4Focus(
        changeAt: Duration, axWindowChanged: Bool = true, axElementChanged: Bool = true
    ) async throws -> S4FocusObservation {
        var time = Duration.zero
        return try await observeS4Focus(
            before: 10, axWindowChanged: axWindowChanged, axElementChanged: axElementChanged,
            elapsed: { time }, wait: { time += $0 }, readWindowID: { time >= changeAt ? 11 : 10 }
        )
    }

    private func milliseconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) * 1_000 + Double(parts.attoseconds) / 1e15
    }

    func testS5AudioDeviceChanges() async throws {
        let folder = try contract("S5")
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            throw XCTSkip("The seam terminal needs Microphone permission")
        }
        let original = try switchAudio("-c")
        var evidence: [String: Any] = ["originalInput": original]
        defer { record(evidence, in: folder) }
        let capture = AudioCaptureService()
        defer { capture.cancelRecording(reason: .userDiscarded) }
        let first = try await firstBuffer(capture)
        evidence["firstBufferOriginalSeconds"] = first ?? -1
        XCTAssertNotNil(first)
        capture.cancelRecording(reason: .userDiscarded)

        let lid = try systemCommand("/usr/sbin/ioreg", ["-r", "-k", "AppleClamshellState", "-d", "1"])
        let closed = lid.contains("\"AppleClamshellState\" = Yes")
        let inputs = try switchAudio("-a").split(separator: "\n").map(String.init)
        let blackHole = "BlackHole 2ch"
        guard let other = inputs.first(where: { $0 == blackHole && $0 != original }) ?? inputs.first(where: {
            $0 != original && ($0.contains("Jabra SPEAK 510")
                || (!closed && $0.contains("MacBook") && $0.contains("Microphone")))
        }) else { throw XCTSkip("No second known-good input device for the idle and in-session switches") }
        evidence["secondInput"] = other
        defer {
            capture.cancelRecording(reason: .userDiscarded)
            XCTAssertNoThrow(try switchAudio("-s", original))
        }
        _ = try switchAudio("-s", other)
        XCTAssertEqual(try switchAudio("-c"), other)
        let next = try await firstBuffer(capture)
        evidence["firstBufferSecondSeconds"] = next ?? -1
        XCTAssertNotNil(next)
        guard next != nil else { return }

        // The unrecoverable half of S5 is covered by these injected tests.
        // testReplacementWithNoUsableSamplesFailsButKeepsPriorAudio
        // testRepeatedNotificationBeforeRecoveryDoesNotLoop
        // testReleaseBeforeQueuedRecoveryReturnsTheRecordedSamples
        // A change to any of them changes S5.
        var changes = 0
        var otherErrors = 0
        capture.onError = { error in
            if case AudioCaptureError.configurationChanged = error { changes += 1 } else { otherErrors += 1 }
        }
        // AudioCaptureService snapshots its callback at session start.
        capture.cancelRecording(reason: .userDiscarded)
        let usesBlackHole = original == blackHole || other == blackHole
        XCTAssertTrue(usesBlackHole, "S5 route identity requires BlackHole 2ch on one side of the switch")
        guard usesBlackHole else { return }
        let toneHz = 941.0
        let sampleRate = 16_000
        let radiansPerSample = 2 * Double.pi * toneHz / Double(sampleRate)
        let tone = (0..<sampleRate).map { Float(0.1 * sin(radiansPerSample * Double($0))) }
        let player = try AVAudioPlayer(data: WAVEncoder.encode(samples: tone, sampleRate: sampleRate))
        player.currentDevice = "BlackHole2ch_UID"
        player.numberOfLoops = -1
        defer { player.stop() }
        let playing = player.play()
        XCTAssertTrue(playing, "The 941 Hz BlackHole tone must play during the switch")
        guard playing else { return }
        evidence["toneHz"] = toneHz
        // play() accepts the start request. Let playback advance before
        // starting the separate one-second first-buffer clock.
        let toneStarted = ProcessInfo.processInfo.systemUptime
        let toneDeadline = toneStarted + 1
        while (!player.isPlaying || player.currentTime < 0.05)
                && ProcessInfo.processInfo.systemUptime < toneDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let tonePosition = player.currentTime
        let toneReady = player.isPlaying && tonePosition >= 0.05
        evidence["tonePositionBeforeCaptureSeconds"] = tonePosition
        evidence["toneStartupWaitSeconds"] = ProcessInfo.processInfo.systemUptime - toneStarted
        XCTAssertTrue(toneReady, "The 941 Hz BlackHole tone must advance before capture starts")
        guard toneReady else { return }

        let midSession = try await firstBuffer(capture)
        evidence["firstBufferMidSessionSeconds"] = midSession ?? -1
        XCTAssertNotNil(midSession)
        guard midSession != nil else { return }
        let before = capture.recordingSnapshot()
        evidence["samplesBeforeSwitch"] = before.count
        _ = try switchAudio("-s", original)
        let switchedAt = ProcessInfo.processInfo.systemUptime
        let deadline = switchedAt + 2
        // Exclude samples that arrived while the switch command was running.
        let samplesAtSwitch = capture.recordingSnapshot().count
        XCTAssertEqual(try switchAudio("-c"), original)
        var samplesInWindow = before.count
        var firstNewSampleSeconds: Double?
        while ProcessInfo.processInfo.systemUptime <= deadline {
            let count = capture.recordingSnapshot().count
            let observedAt = ProcessInfo.processInfo.systemUptime
            guard observedAt <= deadline else { break }
            samplesInWindow = count
            if count > samplesAtSwitch && firstNewSampleSeconds == nil {
                firstNewSampleSeconds = observedAt - switchedAt
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertGreaterThan(samplesInWindow, before.count, "PCM must resume within two seconds of the switch")
        evidence["switchToFirstNewSampleSeconds"] = firstNewSampleSeconds ?? -1

        let final = try capture.finishRecording()
        player.stop()
        evidence["samplesInRecoveryWindow"] = samplesInWindow
        evidence["finalSamples"] = final.samples.count
        evidence["interrupted"] = final.interrupted
        evidence["configurationErrors"] = changes
        evidence["otherErrors"] = otherErrors
        XCTAssertEqual(changes, 0)
        XCTAssertEqual(otherErrors, 0)
        XCTAssertFalse(final.interrupted)
        XCTAssertTrue(final.samples.prefix(before.count).elementsEqual(before), "The switch must preserve the recorded prefix")
        XCTAssertGreaterThan(final.samples.count, before.count)

        func toneAmplitude(_ samples: ArraySlice<Float>) -> Double {
            var inPhase = 0.0
            var quadrature = 0.0
            for (offset, sample) in samples.enumerated() {
                let phase = radiansPerSample * Double(offset)
                inPhase += Double(sample) * cos(phase)
                quadrature += Double(sample) * sin(phase)
            }
            return 2 * hypot(inPhase, quadrature) / Double(max(samples.count, 1))
        }
        // Use the newest appended PCM within the window so a tap already
        // in flight at the switch cannot identify the replacement route.
        let appended = final.samples.prefix(samplesInWindow).dropFirst(before.count)
        let beforeAmplitude = toneAmplitude(before[...])
        let afterAmplitude = toneAmplitude(appended.suffix(before.count))
        let blackHoleAmplitude = other == blackHole ? beforeAmplitude : afterAmplitude
        let otherAmplitude = other == blackHole ? afterAmplitude : beforeAmplitude
        evidence["blackHoleToneAmplitude"] = blackHoleAmplitude
        evidence["otherInputToneAmplitude"] = otherAmplitude
        XCTAssertGreaterThanOrEqual(blackHoleAmplitude, 0.01)
        XCTAssertLessThanOrEqual(otherAmplitude, blackHoleAmplitude * 0.05)

        let followUp = try await firstBuffer(capture)
        evidence["firstBufferFollowUpSeconds"] = followUp ?? -1
        XCTAssertNotNil(followUp, "The next capture on the new input must deliver PCM within one second")
    }

    func testS6EventTapResume() async throws {
        let folder = try contract("S6")
        try requireAccessibility()
        let manager = HotkeyManager()
        manager.start()
        defer { manager.stop() }
        XCTAssertTrue(manager.tapEnabledForTesting)
        manager.nativeInterruptAndResume()
        let recovered = manager.tapEnabledForTesting
        try await Task.sleep(for: .milliseconds(300))
        let earlyPresses = manager.pressDispatches
        let earlyReleases = manager.releaseDispatches
        try await postModifierPair(.rightOption)
        record(["enabledAfterResume": recovered, "enableCount": manager.proactiveEnableCount,
                "replayedPresses": earlyPresses, "replayedReleases": earlyReleases,
                "realPressDispatches": manager.pressDispatches, "realReleaseDispatches": manager.releaseDispatches], in: folder)
        XCTAssertTrue(recovered)
        XCTAssertEqual(manager.proactiveEnableCount, 1)
        XCTAssertEqual(earlyPresses, 0)
        XCTAssertEqual(earlyReleases, 0)
        XCTAssertEqual(manager.pressDispatches, 1)
        XCTAssertEqual(manager.releaseDispatches, 1)
    }

    func testS7PermissionReadersAndBehavior() async throws {
        let folder = try contract("S7")
        let accessibility = AXIsProcessTrusted()
        let microphone = AVCaptureDevice.authorizationStatus(for: .audio)
        let seen = SeamTapEvents()
        let tap = attachTap(seen, options: .defaultTap)
        if let tap {
            defer { CFMachPortInvalidate(tap) }
            try await postModifierPair(.rightOption)
        }
        let receivesKeys = seen.types.contains(CGEventType.flagsChanged.rawValue)
        let capture = AudioCaptureService()
        defer { capture.cancelRecording(reason: .userDiscarded) }
        let latency = microphone == .authorized ? try? await firstBuffer(capture) : nil
        record(["accessibilityGranted": accessibility, "tapDeliveredEvents": receivesKeys,
                "microphoneStatus": microphone.rawValue, "firstBufferSeconds": latency ?? -1], in: folder)
        XCTAssertEqual(accessibility, receivesKeys)
        XCTAssertEqual(microphone == .authorized, latency != nil)
        guard accessibility, microphone == .authorized else {
            throw XCTSkip("Grant the seam terminal Accessibility and Microphone access")
        }
    }

    private func contract(_ id: String) throws -> URL {
        let env = ProcessInfo.processInfo.environment
        guard env["LAMITYPE_RUN_SEAM_CONTRACTS"] == "1" else {
            throw XCTSkip("Set LAMITYPE_RUN_SEAM_CONTRACTS=1 for real system seams")
        }
        let output = try XCTUnwrap(env["LAMITYPE_SEAM_OUTPUT"])
        let directory = URL(fileURLWithPath: output).appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func record(_ evidence: Any, in directory: URL) {
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("observations.json"), options: .atomic))
    }

    private func requireAccessibility() throws {
        guard AXIsProcessTrusted() else { throw XCTSkip("The seam terminal needs Accessibility permission") }
    }

    private func modifier(_ key: DictationKey, down: Bool) throws -> CGEvent {
        let event = try XCTUnwrap(CGEvent(keyboardEventSource: CGEventSource(stateID: .hidSystemState),
                                         virtualKey: key.keyCode, keyDown: down))
        let family: [DictationKey: CGEventFlags] = [.rightOption: .maskAlternate, .rightCommand: .maskCommand,
                                                   .rightControl: .maskControl]
        event.type = .flagsChanged
        event.flags = CGEventFlags(rawValue: 0x100 | (down ? key.deviceBit | family[key]!.rawValue : 0))
        return event
    }

    private func readers(_ key: DictationKey, manager: HotkeyManager, phase: String) -> [String: Any] {
        ["key": key.rawValue, "phase": phase,
         "hidKeyDown": CGEventSource.keyState(.hidSystemState, key: key.keyCode),
         "sessionKeyDown": CGEventSource.keyState(.combinedSessionState, key: key.keyCode),
         "hidFlags": String(CGEventSource.flagsState(.hidSystemState).rawValue, radix: 16),
         "sessionFlags": String(CGEventSource.flagsState(.combinedSessionState).rawValue, radix: 16),
         "effectiveDown": manager.dictationKeyIsDown()]
    }

    private func attachTap(_ seen: SeamTapEvents, options: CGEventTapOptions) -> CFMachPort? {
        let types: [CGEventType] = [.flagsChanged, .keyDown, .keyUp]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                                options: options, eventsOfInterest: mask,
                                                callback: { _, type, event, user in
            if let user { Unmanaged<SeamTapEvents>.fromOpaque(user).takeUnretainedValue().types.append(type.rawValue) }
            return Unmanaged.passUnretained(event)
        }, userInfo: Unmanaged.passUnretained(seen).toOpaque()) else { return nil }
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return tap
    }

    private func postModifierPair(_ key: DictationKey) async throws {
        let down = try modifier(key, down: true)
        let up = try modifier(key, down: false)
        down.post(tap: .cghidEventTap)
        try await Task.sleep(for: .milliseconds(120))
        up.post(tap: .cghidEventTap)
        try await Task.sleep(for: .milliseconds(200))
    }

    private func postCommandC() async throws {
        let down = try modifier(.rightCommand, down: true)
        let up = try modifier(.rightCommand, down: false)
        let cDown = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 8, keyDown: true))
        let cUp = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 8, keyDown: false))
        cDown.flags = down.flags
        cUp.flags = down.flags
        for event in [down, cDown, cUp, up] { event.post(tap: .cghidEventTap) }
        try await Task.sleep(for: .milliseconds(300))
    }

    private func startTarget(in directory: URL) throws -> Process {
        let rig = try XCTUnwrap(ProcessInfo.processInfo.environment["LAMITYPE_SEAM_RIG"])
        let process = Process()
        process.executableURL = URL(fileURLWithPath: rig)
        process.arguments = ["seam-target", "--out", directory.path]
        try process.run()
        return process
    }

    private func stopTarget(_ process: Process, in directory: URL) {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("command.txt"))
        if process.isRunning { process.terminate() }
    }

    private func targetState(in directory: URL, matching matches: ([String: String]) -> Bool) async throws -> [String: String] {
        let path = directory.appendingPathComponent("target.json")
        let deadline = ContinuousClock.now + .seconds(4)
        while ContinuousClock.now < deadline {
            if let data = try? Data(contentsOf: path),
               let state = try? JSONDecoder().decode([String: String].self, from: data), matches(state) {
                return state
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw NSError(domain: "LamitypeSeamTarget", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for the rig field or focus"])
    }

    private func firstBuffer(_ capture: AudioCaptureService) async throws -> Double? {
        let started = Date()
        try capture.startRecording()
        while Date().timeIntervalSince(started) <= 1 {
            if !capture.recordingSnapshot().isEmpty { return Date().timeIntervalSince(started) }
            try await Task.sleep(for: .milliseconds(10))
        }
        return nil
    }

    private func switchAudio(_ flags: String...) throws -> String {
        try systemCommand("/opt/homebrew/bin/SwitchAudioSource", ["-t", "input"] + flags)
    }

    private func systemCommand(_ path: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: path, code: Int(process.terminationStatus))
        }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private final class SeamTapEvents {
    var types: [UInt32] = []
}
