import AppKit
import SwiftUI

struct SettingsPage<Content: View>: View {
    static var width: CGFloat { 620 }

    let height: CGFloat
    var pane: SettingsPane? = nil
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            if let pane {
                PaneHeader(pane: pane)
            }
            Form { content }
                .formStyle(.grouped)
                .buttonStyle(.bordered)
                .controlSize(.regular)
        }
        .frame(width: Self.width, height: height)
    }
}

struct SettingLabel: View {
    let title: String
    var description: String?
    var badge: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Text(title)
                if let badge {
                    Text(badge)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                }
            }
            if let description {
                SettingsNote(description)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct SettingsNote: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            // macOS grouped-form footers align wrapped lines to the trailing edge.
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct SettingRow<Control: View>: View {
    let title: String
    let description: String?
    let control: Control

    init(_ title: String, description: String? = nil, @ViewBuilder control: () -> Control) {
        self.title = title
        self.description = description
        self.control = control()
    }

    var body: some View {
        LabeledContent {
            control
        } label: {
            SettingLabel(title: title, description: description)
        }
    }
}

struct SettingsInfoButton: View {
    let title: String
    let detail: String
    @State private var presented = false

    var body: some View {
        Button {
            presented.toggle()
        } label: {
            Image(systemName: "info.circle")
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(title)
        .popover(isPresented: $presented) {
            Text(detail)
                .frame(width: 280, alignment: .leading)
                .padding(20)
        }
    }
}

struct FileSettingRow<Detail: View>: View {
    let title: String
    let url: URL
    @ViewBuilder let detail: Detail
    let open: () -> Void

    var body: some View {
        LabeledContent {
            Button(L10n.string("settings.button.open", fallback: "Open…"), action: open)
                .help(url.path)
                .contextMenu {
                    Button(L10n.string("settings.file.reveal", fallback: "Reveal in Finder")) {
                        let selection = FileManager.default.fileExists(atPath: url.path)
                            ? url : url.deletingLastPathComponent()
                        NSWorkspace.shared.activateFileViewerSelecting([selection])
                    }
                    Button(L10n.string("settings.file.copy_path", fallback: "Copy Path")) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(url.path, forType: .string)
                    }
                }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                detail
            }
            .accessibilityElement(children: .combine)
        }
    }
}

struct SettingsStatusLabel: View {
    enum Kind {
        case available, warning, inactive

        var symbol: String {
            switch self {
            case .available: "checkmark.circle.fill"
            case .warning: "exclamationmark.triangle"
            case .inactive: "minus.circle"
            }
        }
    }

    let kind: Kind
    let text: String

    var body: some View {
        Label(text, systemImage: kind.symbol)
            .foregroundStyle(.secondary)
    }
}

extension View {
    func settingsPopup() -> some View {
        pickerStyle(.menu)
            .labelsHidden()
            .fixedSize(horizontal: true, vertical: false)
            .frame(maxWidth: 260, alignment: .trailing)
    }
}

struct SettingsActiveTint: ViewModifier {
    @Environment(\.colorSchemeContrast) private var contrast

    private static let coral = Color(red: 236 / 255, green: 106 / 255, blue: 78 / 255)

    func body(content: Content) -> some View {
        content.tint(contrast == .increased ? SettingsPalette.focus : Self.coral)
    }
}

enum SettingsPalette {
    static let sage = adaptive(light: 0xF2F4E8, dark: 0x363B32)
    static let sageInk = adaptive(light: 0x1C2529, dark: 0xE4E8D6)
    static let sample = adaptive(light: 0xEFF2E7, dark: 0x30352D)
    static let recorder = adaptive(light: 0xF2F2F2, dark: 0x292929)
    static let keycap = adaptive(light: 0xE8E8E8, dark: 0x383838)
    static let focus = adaptive(light: 0xD4553B, dark: 0xF58268)
    static let attentionInk = adaptive(light: 0x9D3927, dark: 0xF58268)

    private static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let rgb = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((rgb >> 16) & 255) / 255,
                           green: CGFloat((rgb >> 8) & 255) / 255,
                           blue: CGFloat(rgb & 255) / 255, alpha: 1)
        })
    }
}

@MainActor
struct PaneHeader: View {
    let pane: SettingsPane
    @ObservedObject private var model = SettingsStatusModel.shared

    var body: some View {
        if let (symbol, purpose) = identity {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 16))
                    .frame(width: 30, height: 30)
                    .background(SettingsPalette.sage, in: RoundedRectangle(cornerRadius: 7))
                    .accessibilityHidden(true)
                Text(purpose)
                    .font(.system(size: 13))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if let status = model.status[pane] {
                    StatusChip(status: status)
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, pane == .dictation ? 13 : 17)
            .onAppear { model.refresh(pane) }
        }
    }

    private var identity: (String, String)? {
        switch pane {
        case .general:
            ("gearshape", L10n.string("settings.purpose.general", fallback: "Set your interface language and shortcuts."))
        case .dictation:
            ("mic", L10n.string("settings.purpose.dictation", fallback: "Choose an engine and tune what gets inserted."))
        case .caption:
            ("captions.bubble", L10n.string("settings.purpose.caption", fallback: "Adjust the Live Caption panel and translation."))
        case .text:
            ("textformat", L10n.string("settings.purpose.text", fallback: "Polish and translate selected text on device."))
        case .cloud:
            ("dollarsign.circle", L10n.string("settings.purpose.cloud", fallback: "Manage API keys and cloud usage limits."))
        case .ios:
            ("slider.horizontal.3", L10n.string("settings.purpose.advanced", fallback: "Manage the experimental iOS dictation server."))
        case .about:
            nil
        }
    }
}

struct StatusChip: View {
    private enum Style {
        case ok, attention, neutral

        var symbol: String {
            switch self {
            case .ok: "checkmark.circle"
            case .attention: "exclamationmark.circle"
            case .neutral: "minus.circle"
            }
        }

        var foreground: Color {
            switch self {
            case .ok: SettingsPalette.sageInk
            case .attention: SettingsPalette.attentionInk
            case .neutral: .secondary
            }
        }

        @ViewBuilder var background: some View {
            let capsule = Capsule(style: .circular)
            switch self {
            case .ok: capsule.fill(SettingsPalette.sage)
            case .attention: capsule.strokeBorder(SettingsPalette.focus, lineWidth: 1)
            case .neutral: capsule.fill(Color(nsColor: .quaternarySystemFill))
            }
        }
    }

    let status: PaneStatus

    var body: some View {
        let style = style
        let label = detailText
        Label(label, systemImage: style.symbol)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(style.foreground)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background { style.background }
            .lineLimit(2)
            .frame(maxWidth: 310, alignment: .trailing)
            .fixedSize(horizontal: true, vertical: false)
            .accessibilityLabel(label)
            .accessibilityIdentifier("settings-pane-status")
    }

    private var style: Style {
        switch status {
        case .ok(.captionOff), .ok(.iosServerStopped): .neutral
        case .ok: .ok
        case .attention: .attention
        }
    }

    private var detailText: String {
        let detail: PaneStatusDetail
        switch status {
        case .ok(let value), .attention(let value): detail = value
        }
        switch detail {
        case .permissionsGranted:
            return L10n.string("settings.status.permissions_granted", fallback: "Permissions granted")
        case .needsAccessibility:
            return L10n.string("settings.status.needs_accessibility", fallback: "Needs Accessibility")
        case .needsMicrophone:
            return L10n.string("settings.status.needs_microphone", fallback: "Needs microphone")
        case .needsBoth:
            return L10n.string("settings.status.needs_both", fallback: "Needs Accessibility and microphone")
        case .microphoneRestricted:
            return L10n.string("settings.status.microphone_restricted", fallback: "Microphone restricted")
        case .localModel(let kind):
            let name: String
            switch kind {
            case .fast: name = AppConfig.LocalModel.fast.shortName
            case .optimized: name = AppConfig.LocalModel.optimized.shortName
            case .custom(let customName): name = customName
            }
            return L10n.format("settings.status.local_model", "Local · %1$@", arguments: [name])
        case .cloudEngine(let provider, let hasKey):
            let name = provider == .openAI ? "OpenAI" : "Gemini"
            return hasKey ? name : providerKeyText(name, .missing)
        case .captionOff:
            return L10n.string("settings.status.caption_off", fallback: "Off")
        case .captionMicrophone:
            return L10n.string("permission.microphone.title", fallback: "Microphone")
        case .captionSystem(let appName):
            return appName ?? L10n.string("settings.status.caption_system", fallback: "System audio")
        case .keys(let openAI, let gemini):
            return L10n.format("settings.status.two_keys", "%1$@ · %2$@",
                               arguments: [providerKeyText("OpenAI", openAI), providerKeyText("Gemini", gemini)])
        case .polishAvailable:
            return L10n.string("settings.status.polish_available", fallback: "Text Polish available")
        case .polishChecking:
            return L10n.string("settings.status.polish_checking", fallback: "Checking Text Polish")
        case .polishUnavailable:
            return L10n.string("settings.status.polish_unavailable", fallback: "Text Polish unavailable")
        case .iosServerRunning:
            return L10n.string("settings.ios.status.running", fallback: "Running on port 8000")
        case .iosServerStopped:
            return L10n.string("settings.ios.status.stopped", fallback: "Stopped")
        }
    }

    private func providerKeyText(_ provider: String, _ key: KeyState) -> String {
        let detail: String
        switch key {
        case .loaded:
            detail = L10n.string("settings.key.status.loaded", fallback: "Key loaded")
        case .missing:
            detail = L10n.string("settings.key.status.empty", fallback: "No key")
        case .unusualFormat:
            detail = L10n.string("settings.status.key_format", fallback: "Unusual format")
        }
        return L10n.format("settings.status.provider_key", "%1$@: %2$@", arguments: [provider, detail])
    }
}

struct KeycapView: View {
    let chord: ShortcutChord
    var compact = false

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(chord.keycapParts.enumerated()), id: \.offset) { entry in
                if entry.offset > 0 {
                    Text(verbatim: "+")
                        .font(.system(size: compact ? 9 : 11))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                HStack(spacing: 4) {
                    if let side = entry.element.side {
                        Text(side == .right
                             ? L10n.string("shortcut.keycap.right", fallback: "Right")
                             : L10n.string("shortcut.keycap.left", fallback: "Left"))
                            .font(.system(size: compact ? 9 : 10, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    Text(entry.element.glyph)
                        .font(.system(size: compact ? 11 : 13, weight: .medium))
                }
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .padding(.horizontal, compact ? 3 : 4)
                .frame(minWidth: compact ? 17 : 22, minHeight: compact ? 17 : 22)
                .background(SettingsPalette.keycap, in: RoundedRectangle(cornerRadius: 4))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(chord.title)
    }
}

struct ShortcutKeycapHint: View {
    let binding: ActionBinding

    var body: some View {
        if let chord = binding.chord {
            HStack(spacing: 5) {
                Text(binding.gesture.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                KeycapView(chord: chord, compact: true)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(binding.hint)
        } else {
            SettingsNote(binding.hint)
        }
    }
}

struct SampleRow: View {
    let before: String
    let after: String
    var stacked = false

    private var beforeLabel: String { L10n.string("settings.sample.before", fallback: "Before") }
    private var afterLabel: String { L10n.string("settings.sample.after", fallback: "After") }

    var body: some View {
        HStack(spacing: stacked ? 8 : 6) {
            sample(beforeLabel, before, weight: .regular)
            Image(systemName: "arrow.right")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            sample(afterLabel, after, weight: .semibold)
        }
        .padding(.horizontal, stacked ? 9 : 8)
        .padding(.vertical, stacked ? 7 : 4)
        .background(SettingsPalette.sample, in: RoundedRectangle(cornerRadius: 6))
        .accessibilityElement(children: .combine)
    }

    private func sample(_ title: String, _ value: String, weight: Font.Weight) -> some View {
        let layout = stacked
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 3))
            : AnyLayout(HStackLayout(spacing: 7))
        return layout {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: stacked ? 13 : 12, weight: weight))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
