import AppKit
import XCTest
@testable import HushType

@MainActor
final class RecordedShortcutTests: XCTestCase {
    func testKeycapsForBareModifiersAndCapsLock() {
        XCTAssertEqual(ShortcutChord(keyCode: 56).keycapParts,
                       [KeycapPart(side: .left, glyph: "⇧", accessibilityName: "Shift")])
        XCTAssertEqual(ShortcutChord.rightOption.keycapParts,
                       [KeycapPart(side: .right, glyph: "⌥", accessibilityName: "Option")])
        XCTAssertEqual(ShortcutChord(keyCode: 57).keycapParts,
                       [KeycapPart(side: nil, glyph: "⇪", accessibilityName: "Caps Lock")])
    }

    func testKeycapsForRightCommandAndLayoutSpecificSlashKey() {
        let parts = ShortcutChord.defaultCaption.keycapParts
        XCTAssertEqual(parts.count, 2)
        XCTAssertEqual(parts.first, KeycapPart(side: .right, glyph: "⌘", accessibilityName: "Command"))
        // Key code 44 is slash on US layouts and can have a different glyph on others.
        let slashKey = ShortcutChord(keyCode: 44)
        XCTAssertEqual(parts.last, slashKey.keycapParts.first)
        XCTAssertNil(parts.last?.side)
    }

    func testKeycapsForEitherSideLegacyChordAndUnboundAction() throws {
        let bindings = ShortcutBindings(dictation: .rightControl, liveCaption: .controlOptionSlash)
        let parts = try XCTUnwrap(bindings[.caption].chord).keycapParts
        XCTAssertEqual(parts.count, 3)
        XCTAssertEqual(Array(parts.dropLast()), [
            KeycapPart(side: .left, glyph: "⌃", accessibilityName: "Control"),
            KeycapPart(side: nil, glyph: "⌥", accessibilityName: "Option")
        ])
        XCTAssertNil(ShortcutBindings(liveCaption: .off)[.caption].chord?.keycapParts)
    }

    func testKeycapsForBothPhysicalKeysOfTheSameModifier() {
        let flags = CGEventFlags(rawValue: CGEventFlags.maskAlternate.rawValue | 0x20 | 0x40)
        let chord = ShortcutChord.recorded(code: 61, flags: flags)
        XCTAssertEqual(chord.keycapParts, [
            KeycapPart(side: .left, glyph: "⌥", accessibilityName: "Option"),
            KeycapPart(side: .right, glyph: "⌥", accessibilityName: "Option")
        ])
    }

    func testLegacyPairAndSeparateIDsMigrateEveryActionAndPersistEdits() throws {
        let suite = try TestDefaultsSuite(prefix: "Lamitype-recorded-shortcuts")
        defer { suite.destroy() }
        for paired in [false, true] {
            let pair = ["dictationKey": "rightControl", "liveCaption": "controlOptionSlash"]
            let domain: [String: Any] = paired ? ["hushtype.shortcut.bindings": pair]
                : ["hushtype.shortcut.dictationKey": "rightControl", "hushtype.shortcut.liveCaption": "controlOptionSlash"]
            suite.defaults.setPersistentDomain(domain, forName: suite.name)
            let config = AppConfig.forUpgradeTesting(defaults: suite.defaults)
            let model = ShortcutSettingsModel(config: config)
            for action in [ShortcutAction.dictate, .translate, .polish] {
                XCTAssertEqual(model.bindings[action].chord, .rightControl)
                XCTAssertEqual(model.bindings[action].gesture, ShortcutBindings.default[action].gesture)
            }
            XCTAssertEqual(model.bindings[.caption].chord?.sides, 1)
            XCTAssertNil(model.assign(.init(chord: .init(keyCode: 40), gesture: .hold), to: .translate))
            model.clear(.dictate)
            XCTAssertTrue(model.dictationShortcutMissing)
            XCTAssertEqual(AppConfig.forUpgradeTesting(defaults: suite.defaults).shortcutBindings, model.bindings)
            model.clear(.caption)
            XCTAssertNil(model.bindings[.caption].chord)
            XCTAssertNil(model.reset(.dictate))
            XCTAssertEqual(model.bindings[.dictate], ShortcutBindings.default[.dictate])
            XCTAssertFalse(model.dictationShortcutMissing)
            XCTAssertEqual(model.bindings[.polish].chord, .rightControl)
            XCTAssertNil(model.bindings[.caption].chord)
        }
    }

    func testRejectsConflictsAndFnWithoutOverwritingAndClearedRowsNeverConflict() throws {
        let suite = try TestDefaultsSuite(prefix: "Lamitype-shortcut-conflicts")
        defer { suite.destroy() }
        let model = ShortcutSettingsModel(config: .forUpgradeTesting(defaults: suite.defaults))
        XCTAssertNotNil(model.assign(.init(chord: .rightOption, gesture: .hold), to: .translate))
        XCTAssertNotNil(model.assign(.init(chord: .init(keyCode: 12, modifiers: CGEventFlags.maskCommand.rawValue), gesture: .tap), to: .translate))
        XCTAssertNotNil(model.assign(.init(chord: .init(keyCode: 63), gesture: .tap), to: .translate))
        XCTAssertEqual(model.bindings, .default)
        for action in ShortcutAction.allCases { model.clear(action) }
        XCTAssertTrue(model.bindings.valid)
        XCTAssertNil(model.assign(.init(chord: .rightOption, gesture: .tap), to: .caption))
        XCTAssertNotNil(model.reset(.translate))
        XCTAssertNil(model.bindings[.translate].chord)
    }

    func testGestureResolutionForEveryActionSharingAKey() {
        let code = ShortcutChord(keyCode: 40)
        for action in [ShortcutAction.translate, .polish] {
            var bindings = ShortcutBindings.default
            let arbiter = TapArbiter()
            var actions: [ShortcutAction] = []
            func release(_ held: Bool) {
                arbiter.finish(chord: code, held: held, bindings: bindings, enabled: { _ in true }) {
                    if let action = $0 { actions.append(action) }
                }
            }
            bindings[action] = .init(chord: code, gesture: .hold)
            release(false)
            XCTAssertTrue(actions.isEmpty)
            release(true)
            bindings[action].gesture = .tap
            release(true)
            release(false)
            bindings[action].gesture = .doubleTap
            release(false)
            XCTAssertTrue(arbiter.cancelPendingForSecondPress())
            release(false)
            XCTAssertEqual(actions, [action, action, action])
        }
    }

    func testCaptionOffersOnlyTapAndDoubleTapAndRejectsHold() throws {
        XCTAssertEqual(ShortcutAction.caption.gestures, [.tap, .doubleTap])
        XCTAssertEqual(ShortcutAction.dictate.gestures, [.hold])
        XCTAssertEqual(ShortcutAction.translate.gestures, [.tap, .doubleTap, .hold])
        XCTAssertEqual(ShortcutAction.polish.gestures, [.tap, .doubleTap, .hold])
        let suite = try TestDefaultsSuite(prefix: "Lamitype-caption-gestures")
        defer { suite.destroy() }
        let model = ShortcutSettingsModel(config: .forUpgradeTesting(defaults: suite.defaults))
        XCTAssertNotNil(model.assign(.init(chord: .defaultCaption, gesture: .hold), to: .caption))
        XCTAssertEqual(model.bindings[.caption], ShortcutBindings.default[.caption])
        XCTAssertNil(model.assign(.init(chord: .defaultCaption, gesture: .doubleTap), to: .caption))
        XCTAssertEqual(model.bindings[.caption].gesture, .doubleTap)
        var invalid = ShortcutBindings.default
        invalid.edits[.caption] = .init(chord: .defaultCaption, gesture: .hold)
        XCTAssertFalse(invalid.valid)
    }

    func testDoubleTapWindowByChordType() {
        XCTAssertEqual(TapArbiter.doubleTapWindow, 0.35)
        XCTAssertEqual(TapArbiter.multiKeyDoubleTapWindow, 0.5)
        // Multi-key: modifiers + a non-modifier key.
        XCTAssertTrue(ShortcutChord.defaultCaption.isMultiKey)
        XCTAssertTrue(ShortcutChord(keyCode: 44, modifiers: CGEventFlags([.maskAlternate, .maskControl]).rawValue).isMultiKey)
        XCTAssertEqual(TapArbiter.doubleTapWindow(for: .defaultCaption), 0.5)
        // Single-key: lone modifier, Caps Lock, bare key.
        for chord in [ShortcutChord.rightOption, .rightCommand, .rightControl,
                      ShortcutChord(keyCode: 57), ShortcutChord(keyCode: 40)] {
            XCTAssertFalse(chord.isMultiKey, chord.title)
            XCTAssertEqual(TapArbiter.doubleTapWindow(for: chord), 0.35)
        }
        // A modifier primary with extra required modifiers is still a modifier-only chord.
        let recorded = ShortcutChord.recorded(code: 54, flags: CGEventFlags(rawValue: 0x40 | 0x10 | CGEventFlags.maskAlternate.rawValue | CGEventFlags.maskCommand.rawValue))
        XCTAssertFalse(recorded.isMultiKey)
    }

    func testFinishDefersSingleTapByChordWindow() async throws {
        for (chord, window) in [(ShortcutChord.rightOption, 0.35), (ShortcutChord.defaultCaption, 0.5)] {
            var bindings = ShortcutBindings.default
            bindings[.translate] = .init(chord: chord, gesture: .tap)
            bindings[.polish] = .init(chord: chord, gesture: .doubleTap)
            let arbiter = TapArbiter()
            var fired: [ShortcutAction] = []
            arbiter.finish(chord: chord, held: false, bindings: bindings, enabled: { _ in true }) {
                if let action = $0 { fired.append(action) }
            }
            XCTAssertTrue(arbiter.hasPendingAction)
            try await Task.sleep(for: .seconds(0.35 + 0.05))
            // 0.35 s single-key window has fired; the 0.5 s multi-key window is still pending.
            XCTAssertEqual(fired, window == 0.35 ? [.translate] : [], "\(chord.title) at 0.40 s")
            try await Task.sleep(for: .seconds(0.2))
            XCTAssertEqual(fired, [.translate], "\(chord.title) at 0.60 s")
        }
    }

    func testSavedCaptionHoldMigratesToTap() throws {
        let suite = try TestDefaultsSuite(prefix: "Lamitype-caption-hold-migration")
        defer { suite.destroy() }
        let other = ShortcutChord(keyCode: 40)
        var saved = ShortcutBindings.default
        saved.edits[.caption] = .init(chord: .defaultCaption, gesture: .hold)
        saved[.translate] = .init(chord: other, gesture: .hold)
        // Encode the legacy shape directly (the setter would now refuse it).
        suite.defaults.set(try JSONEncoder().encode(saved), forKey: "hushtype.shortcut.bindings")
        let loaded = AppConfig.forUpgradeTesting(defaults: suite.defaults).shortcutBindings
        XCTAssertTrue(loaded.valid)
        XCTAssertEqual(loaded[.caption], .init(chord: .defaultCaption, gesture: .tap))
        XCTAssertEqual(loaded[.translate], .init(chord: other, gesture: .hold), "other edits are kept")

        // Hold on a chord whose Tap is taken by another action: caption turns off, the rest is kept.
        var clash = ShortcutBindings.default
        clash.edits[.translate] = .init(chord: other, gesture: .tap)
        clash.edits[.caption] = .init(chord: other, gesture: .hold)
        suite.defaults.set(try JSONEncoder().encode(clash), forKey: "hushtype.shortcut.bindings")
        let migrated = AppConfig.forUpgradeTesting(defaults: suite.defaults).shortcutBindings
        XCTAssertTrue(migrated.valid)
        XCTAssertNil(migrated[.caption].chord)
        XCTAssertEqual(migrated[.caption].gesture, .tap)
        XCTAssertEqual(migrated[.translate], .init(chord: other, gesture: .tap))
    }

    private func event(_ code: CGKeyCode, flags: CGEventFlags = []) -> CGEvent {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true)!
        event.flags = flags
        return event
    }

    func testCustomDictationReleaseAndLostReleaseAcrossKeyboardTapOutage() {
        var bindings = ShortcutBindings.default
        let flags = CGEventFlags(rawValue: CGEventFlags.maskControl.rawValue | 1)
        bindings[.dictate].chord = ShortcutChord.recorded(code: 40, flags: flags)
        var healthy = true
        let manager = HotkeyManager(bindings: bindings, keyIsDown: { _ in false }, keyboardTapEnabled: { _ in healthy },
                                    secureInput: { false })
        var starts = 0, ends = 0, cancelled = 0
        manager.onPress = { starts += 1 }
        manager.onRelease = { ends += 1 }
        manager.onCancelledRelease = { _ in cancelled += 1 }
        XCTAssertTrue(manager.handleEvent(type: .keyDown, event: event(40, flags: flags)) == nil)
        for _ in 0..<8 { manager.checkForLostRelease() }
        XCTAssertEqual(starts, 1)
        XCTAssertEqual(cancelled, 0)
        // Releasing the pre-held modifier first must end capture and pass that modifier up to its owner.
        XCTAssertTrue(manager.handleEvent(type: .flagsChanged, event: event(59)) != nil)
        XCTAssertTrue(manager.handleEvent(type: .keyUp, event: event(40)) == nil)
        XCTAssertEqual(ends, 1)
        XCTAssertTrue(manager.handleEvent(type: .keyDown, event: event(40, flags: flags)) == nil)
        healthy = false
        manager.checkForLostRelease()
        XCTAssertEqual(cancelled, 0)
        manager.checkForLostRelease()
        XCTAssertEqual(cancelled, 1)
        _ = manager.handleEvent(type: .keyUp, event: event(40))
        XCTAssertEqual(ends, 1)
    }

    func testCapsLockLEDDoesNotHoldTheMicrophoneAfterPhysicalRelease() {
        var bindings = ShortcutBindings.default
        bindings[.dictate].chord = .init(keyCode: 57)
        let manager = HotkeyManager(bindings: bindings, secureInput: { false })
        var presses = 0, releases = 0
        manager.onPress = { presses += 1 }
        manager.onRelease = { releases += 1 }
        let down = CGEventFlags(rawValue: ShortcutChord.physicalCapsMask | CGEventFlags.maskAlphaShift.rawValue)
        XCTAssertTrue(manager.handleEvent(type: .flagsChanged, event: event(57, flags: down)) == nil)
        XCTAssertTrue(manager.handleEvent(type: .flagsChanged, event: event(57, flags: .maskAlphaShift)) == nil)
        XCTAssertEqual(presses, 1)
        XCTAssertEqual(releases, 1)
        XCTAssertNil(manager.currentPress)
    }

    func testModifierOnlyChordsReleaseThePhysicalKeyWhoseDownWasConsumed() {
        let control = CGEventFlags(rawValue: CGEventFlags.maskControl.rawValue | 1)
        let shift = CGEventFlags(rawValue: CGEventFlags.maskShift.rawValue | 2)
        let both = control.union(shift)
        let chord = ShortcutChord.recorded(code: 59, flags: both)
        XCTAssertEqual(chord, ShortcutChord.recorded(code: 56, flags: both))
        for action in [ShortcutAction.dictate, .translate] {
            var bindings = ShortcutBindings.default
            bindings[action].chord = chord
            let manager = HotkeyManager(bindings: bindings, secureInput: { false })
            var releases = 0
            manager.onRelease = { releases += 1 }
            manager.onActionRelease = { _, _ in releases += 1 }
            // Shift is the canonical primary, but Control completes this physical press.
            XCTAssertTrue(manager.handleEvent(type: .flagsChanged, event: event(56, flags: shift)) != nil)
            XCTAssertTrue(manager.handleEvent(type: .flagsChanged, event: event(59, flags: both)) == nil)
            XCTAssertTrue(manager.handleEvent(type: .flagsChanged, event: event(56, flags: control)) != nil)
            XCTAssertTrue(manager.handleEvent(type: .flagsChanged, event: event(59)) == nil)
            XCTAssertEqual(releases, 1)
        }
    }

    func testIndependentCustomKeyDoesNotEnterDictationOrDispatchTwiceOnRepeat() {
        var bindings = ShortcutBindings.default
        bindings[.translate].chord = .init(keyCode: 40)
        bindings[.dictate].chord = nil
        let manager = HotkeyManager(bindings: bindings, secureInput: { false })
        var released: [ShortcutChord] = []
        manager.onPress = { XCTFail("Cleared Dictate started") }
        manager.onActionRelease = { chord, _ in released.append(chord) }
        XCTAssertTrue(manager.handleEvent(type: .keyDown, event: event(40)) == nil)
        let repeatEvent = event(40)
        repeatEvent.setIntegerValueField(.keyboardEventAutorepeat, value: 1)
        XCTAssertTrue(manager.handleEvent(type: .keyDown, event: repeatEvent) == nil)
        XCTAssertTrue(manager.handleEvent(type: .keyUp, event: event(40)) == nil)
        XCTAssertEqual(released, [.init(keyCode: 40)])
        XCTAssertTrue(manager.handleEvent(type: .keyUp, event: event(40)) != nil)
    }
}
