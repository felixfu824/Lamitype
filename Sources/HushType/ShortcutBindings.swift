import AppKit

/// Stable preference IDs. Side-specific bits are NX_DEVICE*KEYMASK from IOLLEvent.h.
enum DictationKey: String, CaseIterable, Codable {
    case rightOption, rightCommand, rightControl

    var keyCode: CGKeyCode {
        switch self {
        case .rightOption: return 61
        case .rightCommand: return 54
        case .rightControl: return 62
        }
    }

    var chord: ShortcutChord { ShortcutChord(keyCode: keyCode) }

    var deviceBit: UInt64 {
        switch self {
        case .rightOption: return 0x40
        case .rightCommand: return 0x10
        case .rightControl: return 0x2000
        }
    }
}

enum CaptionShortcut: String, CaseIterable, Codable {
    case rightCmdSlash, controlOptionSlash, off

    var keyCode: Int64 { 44 }
}

enum HotkeyEvent: Equatable {
    case dictationDown, dictationUp, captionToggle, captionRepeat, passThrough
}

struct ShortcutBindings: Equatable, Codable {
    var dictation: DictationKey = .rightOption
    var liveCaption: CaptionShortcut = .rightCmdSlash

    var edits: [ShortcutAction: ActionBinding] = [:]

    init(dictation: DictationKey = .rightOption, liveCaption: CaptionShortcut = .rightCmdSlash,
         edits: [ShortcutAction: ActionBinding] = [:]) {
        self.dictation = dictation
        self.liveCaption = liveCaption
        self.edits = edits
    }

    /// Live Caption no longer offers Hold. A saved caption + Hold binding loads as Tap on the
    /// same chord. If that Tap would collide with another action on the same chord, the caption
    /// shortcut is turned off instead; every other binding is kept. (Without this, the stricter
    /// `valid` check would reject the whole saved set and reset every shortcut to its default.)
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        dictation = try container.decode(DictationKey.self, forKey: .dictation)
        liveCaption = try container.decode(CaptionShortcut.self, forKey: .liveCaption)
        edits = try container.decode([ShortcutAction: ActionBinding].self, forKey: .edits)
        guard var caption = edits[.caption], caption.gesture == .hold else { return }
        caption.gesture = .tap
        if conflict(for: .caption, binding: caption) != nil { caption.chord = nil }
        edits[.caption] = caption
    }

    subscript(action: ShortcutAction) -> ActionBinding {
        get { edits[action] ?? preset(action) }
        set { edits[action] = newValue == preset(action) ? nil : newValue }
    }

    private func preset(_ action: ShortcutAction) -> ActionBinding {
        switch action {
        case .dictate: return ActionBinding(chord: dictation.chord, gesture: .hold)
        case .translate: return ActionBinding(chord: dictation.chord, gesture: .tap)
        case .polish: return ActionBinding(chord: dictation.chord, gesture: .doubleTap)
        case .caption:
            let chord: ShortcutChord?
            switch liveCaption {
            case .off: chord = nil
            case .rightCmdSlash: chord = .defaultCaption
            case .controlOptionSlash:
                chord = ShortcutChord(keyCode: 44, modifiers: CGEventFlags([.maskAlternate, .maskControl]).rawValue,
                                      sides: dictation == .rightOption ? 0x20 : dictation == .rightControl ? 1 : 0)
            }
            return ActionBinding(chord: chord, gesture: .tap)
        }
    }

    func conflict(for action: ShortcutAction, binding: ActionBinding) -> ShortcutAction? {
        guard let chord = binding.chord else { return nil }
        return ShortcutAction.allCases.first { other in
            guard other != action, let existing = self[other].chord, existing.overlaps(chord) else { return false }
            return existing != chord || self[other].gesture == binding.gesture
        }
    }

    var valid: Bool {
        !hasConflict && ShortcutAction.allCases.allSatisfy { action in
            let binding = self[action]
            return action.gestures.contains(binding.gesture) && binding.chord?.valid != false
        }
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        ShortcutAction.allCases.allSatisfy { lhs[$0] == rhs[$0] }
    }

    static let `default` = ShortcutBindings()
    /// Per-event marker, intentionally independent of the posting process ID.
    static let syntheticEventTag: Int64 = 0x4C414D4954595045
    private static let modifiers: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]

    var hasConflict: Bool {
        guard edits.isEmpty else {
            return ShortcutAction.allCases.contains { conflict(for: $0, binding: self[$0]) != nil }
        }
        switch liveCaption {
        case .rightCmdSlash: return dictation == .rightCommand
        case .controlOptionSlash: return false
        case .off: return false
        }
    }

    func otherModifierPressed(keyCode: Int64, flags: CGEventFlags) -> Bool {
        guard keyCode != Int64(dictation.keyCode) else { return false }
        let deviceBits: [Int64: UInt64] = [55: 0x08, 54: 0x10, 59: 0x01, 62: 0x2000,
            58: 0x20, 61: 0x40, 56: 0x02, 60: 0x04, 63: CGEventFlags.maskSecondaryFn.rawValue]
        guard let bit = deviceBits[keyCode] else { return false }
        return flags.rawValue & bit != 0
    }

    func hasOtherModifierFamily(_ flags: CGEventFlags) -> Bool {
        let own: CGEventFlags
        switch dictation {
        case .rightOption: own = .maskAlternate
        case .rightCommand: own = .maskCommand
        case .rightControl: own = .maskControl
        }
        return !flags.intersection(Self.modifiers).subtracting(own).isEmpty
    }

    func classify(type: CGEventType, keyCode: Int64, flags: CGEventFlags,
                  autorepeat: Bool = false, userData: Int64 = 0) -> HotkeyEvent {
        guard userData != Self.syntheticEventTag else { return .passThrough }
        if type == .flagsChanged, keyCode == Int64(dictation.keyCode) {
            return flags.rawValue & dictation.deviceBit != 0 ? .dictationDown : .dictationUp
        }
        guard type == .keyDown, keyCode == liveCaption.keyCode else { return .passThrough }
        let exact = flags.intersection(Self.modifiers)
        let matches: Bool
        switch liveCaption {
        case .rightCmdSlash:
            matches = exact == .maskCommand && flags.rawValue & 0x10 != 0 && flags.rawValue & 0x08 == 0
        case .controlOptionSlash:
            let oppositeSidePresent: Bool
            switch dictation {
            case .rightOption: oppositeSidePresent = flags.rawValue & 0x20 != 0
            case .rightControl: oppositeSidePresent = flags.rawValue & 0x01 != 0
            case .rightCommand: oppositeSidePresent = true
            }
            matches = exact == [.maskControl, .maskAlternate] && oppositeSidePresent
        case .off: matches = false
        }
        guard matches else { return .passThrough }
        return autorepeat ? .captionRepeat : .captionToggle
    }
}

/// Key names share the existing zh-TW terms: compact 右 glyphs and spoken 右側 names.
enum ShortcutDisplay {
    static func dictation(_ key: DictationKey, spoken: Bool = false) -> String {
        switch (key, spoken) {
        case (.rightOption, false): return L10n.string("shortcut.key.right_option", fallback: "Right ⌥")
        case (.rightCommand, false): return L10n.string("shortcut.key.right_command", fallback: "Right ⌘")
        case (.rightControl, false): return L10n.string("shortcut.key.right_control", fallback: "Right ⌃")
        case (.rightOption, true): return L10n.string("shortcut.key.right_option.spoken", fallback: "Right Option")
        case (.rightCommand, true): return L10n.string("shortcut.key.right_command.spoken", fallback: "Right Command")
        case (.rightControl, true): return L10n.string("shortcut.key.right_control.spoken", fallback: "Right Control")
        }
    }

    static func dictationPopup(_ key: DictationKey) -> String {
        key == .rightControl
            ? L10n.string("shortcut.key.right_control.popup", fallback: "Right ⌃ (external keyboards)")
            : dictation(key)
    }

    static func modifierGlyph(_ key: DictationKey) -> String {
        switch key {
        case .rightOption: return "⌥"
        case .rightCommand: return "⌘"
        case .rightControl: return "⌃"
        }
    }

    static func caption(_ key: CaptionShortcut, dictation: DictationKey? = nil) -> String {
        switch key {
        case .rightCmdSlash: return L10n.string("shortcut.caption.right_command", fallback: "Right ⌘ + /")
        case .controlOptionSlash:
            if dictation == .rightOption { return L10n.string("shortcut.caption.left_option", fallback: "⌃ + Left ⌥ + /") }
            if dictation == .rightControl { return L10n.string("shortcut.caption.left_control", fallback: "Left ⌃ + ⌥ + /") }
            return "⌃⌥ + /"
        case .off: return L10n.string("shortcut.caption.off", fallback: "Off")
        }
    }

    static var missingDictation: String {
        L10n.string("shortcut.dictation.missing", fallback: "No dictation shortcut is set. Choose one in General > Shortcuts.")
    }

    static var off: String {
        L10n.string("shortcut.binding.off", fallback: "Off: no shortcut. Set one in General > Shortcuts.")
    }

    static func format(_ key: String, _ fallback: String, spoken: Bool = false) -> String {
        let bindings = AppConfig.shared.shortcutBindings
        guard let chord = bindings[.dictate].chord else { return off }
        let name = DictationKey.allCases.first { $0.chord == chord }.map { dictation($0, spoken: spoken) } ?? chord.title
        return L10n.format(key, fallback, arguments: [name])
    }
}
