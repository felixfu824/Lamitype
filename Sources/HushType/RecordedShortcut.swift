import AppKit
import Carbon

enum ShortcutAction: String, CaseIterable, Codable {
    case dictate, translate, polish, caption

    var title: String {
        switch self {
        case .dictate: return L10n.string("shortcut.action.dictate", fallback: "Dictate")
        case .translate: return L10n.string("shortcut.action.translate", fallback: "Translate selection")
        case .polish: return L10n.string("shortcut.action.polish", fallback: "Polish selection")
        case .caption: return L10n.string("shortcut.action.caption", fallback: "Live Caption")
        }
    }

    /// Dictate is hold-only. Live Caption is a start/stop toggle, so Hold would make both
    /// starting and stopping wait for the key release; it offers Tap and Double-tap only.
    var gestures: [ShortcutGesture] {
        switch self {
        case .dictate: return [.hold]
        case .caption: return [.tap, .doubleTap]
        case .translate, .polish: return [.tap, .doubleTap, .hold]
        }
    }
}

enum ShortcutGesture: String, CaseIterable, Codable {
    case hold, tap, doubleTap

    var title: String {
        switch self {
        case .hold: return L10n.string("shortcut.mode.hold", fallback: "Hold")
        case .tap: return L10n.string("shortcut.mode.tap", fallback: "Tap")
        case .doubleTap: return L10n.string("shortcut.mode.double", fallback: "Double-tap")
        }
    }
}

struct ActionBinding: Equatable, Codable {
    var chord: ShortcutChord?
    var gesture: ShortcutGesture

    var hint: String {
        guard let chord else { return ShortcutDisplay.off }
        return L10n.format("shortcut.binding.hint", "%1$@ %2$@", arguments: [gesture.title, chord.title])
    }
}

/// Hardware key codes survive input-source changes. Device bits distinguish left and right
/// modifiers. A migrated preset may deliberately accept either side of one modifier family.
struct ShortcutChord: Equatable, Codable, Hashable {
    let keyCode: CGKeyCode
    var modifiers: UInt64 = 0
    var sides: UInt64 = 0
    var excludedSides: UInt64 = 0

    struct Modifier {
        let code: CGKeyCode
        let bit: UInt64
        let family: CGEventFlags
        let glyph: String
        let right: Bool
    }
    static let modifierKeys = [
        Modifier(code: 59, bit: 1, family: .maskControl, glyph: "⌃", right: false),
        Modifier(code: 62, bit: 0x2000, family: .maskControl, glyph: "⌃", right: true),
        Modifier(code: 58, bit: 0x20, family: .maskAlternate, glyph: "⌥", right: false),
        Modifier(code: 61, bit: 0x40, family: .maskAlternate, glyph: "⌥", right: true),
        Modifier(code: 56, bit: 2, family: .maskShift, glyph: "⇧", right: false),
        Modifier(code: 60, bit: 4, family: .maskShift, glyph: "⇧", right: true),
        Modifier(code: 55, bit: 8, family: .maskCommand, glyph: "⌘", right: false),
        Modifier(code: 54, bit: 16, family: .maskCommand, glyph: "⌘", right: true)
    ]
    static let families: CGEventFlags = [.maskCommand, .maskAlternate, .maskShift, .maskControl]
    static func modifier(_ code: CGKeyCode) -> Modifier? { modifierKeys.first { $0.code == code } }
    // IOLLEvent.h: stateless Caps Lock bits report the physical key separately from its latched LED.
    static let physicalCapsMask: UInt64 = 0x0100_0080
    static let escape = ShortcutChord(keyCode: 53)
    static let delete = ShortcutChord(keyCode: 51)
    static let rightOption = ShortcutChord(keyCode: 61)
    static let rightCommand = ShortcutChord(keyCode: 54)
    static let rightControl = ShortcutChord(keyCode: 62)
    static let defaultCaption = ShortcutChord(keyCode: 44, modifiers: CGEventFlags.maskCommand.rawValue,
                                               sides: 16, excludedSides: 8)

    /// Modifiers plus a non-modifier key (for example Right ⌘ + `/`). The second press of a
    /// double-tap only registers at the final key's keyDown, so re-pressing the whole chord
    /// needs a longer window. A lone modifier, Caps Lock or a bare key is a single-key chord.
    var isMultiKey: Bool {
        modifiers != 0 && keyCode != 57 && Self.modifier(keyCode) == nil
    }

    var deviceBit: UInt64 { keyCode == 57 ? Self.physicalCapsMask : Self.modifier(keyCode)?.bit ?? 0 }
    var valid: Bool {
        keyCode < 128 && keyCode != 63 && modifiers & ~Self.families.rawValue == 0
            && sides & excludedSides == 0 && (sides | excludedSides) & ~UInt64(0x207f) == 0
    }

    static func recorded(code: CGKeyCode, flags: CGEventFlags) -> ShortcutChord {
        var primary = code
        var extras = flags.intersection(families).rawValue
        var required: UInt64 = 0, excluded: UInt64 = 0
        // A modifier-only chord has the same identity in either press order.
        if modifier(code) != nil {
            primary = modifierKeys.last { flags.rawValue & $0.bit != 0 }?.code ?? code
        }
        for key in modifierKeys where key.code != primary && flags.rawValue & key.bit != 0 {
            required |= key.bit
        }
        if let own = modifier(primary), !modifierKeys.contains(where: { $0.family == own.family && required & $0.bit != 0 }) {
            extras &= ~own.family.rawValue
        }
        for key in modifierKeys where extras & key.family.rawValue != 0 && flags.rawValue & key.bit == 0 {
            if modifierKeys.contains(where: { $0.family == key.family && required & $0.bit != 0 }) {
                excluded |= key.bit
            }
        }
        return ShortcutChord(keyCode: primary, modifiers: extras, sides: required, excludedSides: excluded)
    }

    private var requiredFamilies: UInt64 { modifiers | (Self.modifier(keyCode)?.family.rawValue ?? 0) }

    func overlaps(_ other: ShortcutChord) -> Bool {
        keyCode == other.keyCode && requiredFamilies == other.requiredFamilies
            && sides & other.excludedSides == 0 && other.sides & excludedSides == 0
    }

    func matchesDown(type: CGEventType, code: CGKeyCode, flags: CGEventFlags) -> Bool {
        let bits = flags.rawValue
        if keyCode == 57 {
            guard code == 57, type == .keyDown || (type == .flagsChanged && bits & Self.physicalCapsMask != 0) else { return false }
        } else if deviceBit != 0 {
            guard type == .flagsChanged, let edge = Self.modifier(code),
                  edge.bit & (sides | deviceBit) != 0, bits & deviceBit != 0 else { return false }
        } else {
            guard type == .keyDown, code == keyCode else { return false }
        }
        var families = flags.intersection(Self.families).rawValue
        for key in Self.modifierKeys where bits & key.bit != 0 { families |= key.family.rawValue }
        return families == requiredFamilies && bits & sides == sides && bits & excludedSides == 0
    }

    func released(type: CGEventType, code: CGKeyCode, flags: CGEventFlags) -> Bool {
        if type == .keyUp { return keyCode == code }
        guard type == .flagsChanged else { return false }
        if code == 57 && keyCode == 57 { return flags.rawValue & Self.physicalCapsMask == 0 }
        guard let key = Self.modifier(code) else { return false }
        if (sides | deviceBit) & key.bit != 0 { return flags.rawValue & key.bit == 0 }
        return modifiers & key.family.rawValue != 0 && !flags.contains(key.family)
    }

    var systemShortcut: Bool {
        let cmd = CGEventFlags.maskCommand.rawValue
        let control = CGEventFlags.maskControl.rawValue
        switch modifiers {
        case cmd:
            // Standard editing, app switching, window cycling, Spotlight and app commands.
            return [0, 1, 3, 4, 6, 7, 8, 9, 12, 13, 31, 35, 43, 45, 46, 48, 49, 50].contains(keyCode)
        case cmd | CGEventFlags.maskShift.rawValue:
            return [6, 12, 20, 21, 23, 48, 50].contains(keyCode)
        case cmd | CGEventFlags.maskAlternate.rawValue:
            return keyCode == 53
        case cmd | control:
            return keyCode == 12
        case control:
            return [49, 123, 124, 125, 126].contains(keyCode)
        default:
            return false
        }
    }

    private var displayedModifiers: [(key: Modifier, side: KeycapSide?)] {
        Self.modifierKeys.compactMap { key in
            if sides & key.bit != 0 { return (key, key.side) }
            if !key.right, modifiers & key.family.rawValue != 0,
               !Self.modifierKeys.contains(where: { $0.family == key.family && sides & $0.bit != 0 }) {
                return (key, nil)
            }
            return nil
        }
    }

    var title: String {
        func name(_ key: Modifier, side: KeycapSide?) -> String {
            switch side {
            case .right: return L10n.format("shortcut.key.right", "Right %1$@", arguments: [key.glyph])
            case .left: return L10n.format("shortcut.key.left", "Left %1$@", arguments: [key.glyph])
            case nil: return key.glyph
            }
        }
        var parts = displayedModifiers.map { name($0.key, side: $0.side) }
        parts.append(Self.modifier(keyCode).map { name($0, side: $0.side) }
            ?? keyNames?.glyph ?? L10n.format("shortcut.key.code", "Key %1$lld", arguments: [Int(keyCode)]))
        return parts.joined(separator: " + ")
    }

    private var keyNames: (glyph: String, accessibility: String)? {
        let special: [CGKeyCode: (String, String)] = [
            36: ("↩", "Return"), 48: ("⇥", "Tab"), 49: ("␣", "Space"),
            51: ("⌫", "Delete"), 53: ("Esc", "Escape"), 57: ("⇪", "Caps Lock"),
            71: ("⌧", "Clear"), 76: ("⌤", "Enter"), 114: ("Help", "Help"),
            115: ("↖", "Home"), 116: ("⇞", "Page Up"), 117: ("⌦", "Forward Delete"),
            119: ("↘", "End"), 121: ("⇟", "Page Down"), 123: ("←", "Left Arrow"),
            124: ("→", "Right Arrow"), 125: ("↓", "Down Arrow"), 126: ("↑", "Up Arrow")
        ]
        if let names = special[keyCode] { return names }
        let functionKeys: [CGKeyCode] = [122,120,99,118,96,97,98,100,101,109,103,111,105,107,113,106,64,79,80,90]
        if let index = functionKeys.firstIndex(of: keyCode) {
            let name = "F\(index + 1)"
            return (name, name)
        }
        let source = TISCopyCurrentKeyboardLayoutInputSource().takeRetainedValue()
        if let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) {
            let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue()
            let layout = UnsafeRawPointer(CFDataGetBytePtr(data)!).assumingMemoryBound(to: UCKeyboardLayout.self)
            var dead: UInt32 = 0, length = 0
            var chars = [UniChar](repeating: 0, count: 8)
            if UCKeyTranslate(layout, keyCode, UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                              OptionBits(kUCKeyTranslateNoDeadKeysMask), &dead, chars.count, &length, &chars) == noErr,
               length > 0 {
                let name = String(utf16CodeUnits: chars, count: length).uppercased()
                return (name, name)
            }
        }
        return nil
    }
}

enum KeycapSide: Equatable {
    case left, right
}

struct KeycapPart: Equatable {
    let side: KeycapSide?
    let glyph: String
    let accessibilityName: String
}

extension ShortcutChord {
    var keycapParts: [KeycapPart] {
        var parts = displayedModifiers.map { $0.key.keycap(side: $0.side) }
        if let key = Self.modifier(keyCode) {
            parts.append(key.keycap(side: key.side))
        } else {
            let fallback = "Key \(keyCode)"
            let names = keyNames ?? (fallback, fallback)
            parts.append(KeycapPart(side: nil, glyph: names.glyph, accessibilityName: names.accessibility))
        }
        return parts
    }
}

private extension ShortcutChord.Modifier {
    var side: KeycapSide { right ? .right : .left }

    func keycap(side: KeycapSide?) -> KeycapPart {
        let name: String
        switch family {
        case .maskControl: name = "Control"
        case .maskAlternate: name = "Option"
        case .maskShift: name = "Shift"
        case .maskCommand: name = "Command"
        default: name = glyph
        }
        return KeycapPart(side: side, glyph: glyph, accessibilityName: name)
    }
}
