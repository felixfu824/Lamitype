import AppKit
import SwiftUI

enum AutoPolishExclusionCatalog {
    struct Candidate: Equatable, Sendable {
        let bundleID: String
        let name: String
    }

    struct Groups: Equatable, Sendable {
        let running: [Candidate]
        let excludedNotRunning: [Candidate]
    }

    static func groups(
        running: [Candidate],
        excludedBundleIDs: [String],
        ownBundleID: String?,
        resolveName: (String) -> String?
    ) -> Groups {
        let own = ownBundleID.map(AutoPolishPolicy.normalize)
        var seen = Set<String>()
        var normalizedRunning: [Candidate] = []

        for candidate in running {
            let bundleID = AutoPolishPolicy.normalize(candidate.bundleID)
            guard !bundleID.isEmpty, bundleID != own, seen.insert(bundleID).inserted else {
                continue
            }
            let name = normalizedName(candidate.name)
            normalizedRunning.append(Candidate(
                bundleID: bundleID,
                name: name.isEmpty ? bundleID : name
            ))
        }
        normalizedRunning.sort(by: alphabeticalOrder)

        let runningIDs = Set(normalizedRunning.map(\.bundleID))
        let excludedNotRunning = AutoPolishPolicy.normalizedUnique(excludedBundleIDs)
            .filter { !runningIDs.contains($0) && $0 != own }
            .map { bundleID in
                let resolved = resolveName(bundleID).map(normalizedName) ?? ""
                return Candidate(
                    bundleID: bundleID,
                    name: resolved.isEmpty ? bundleID : resolved
                )
            }
            .sorted(by: alphabeticalOrder)

        return Groups(running: normalizedRunning, excludedNotRunning: excludedNotRunning)
    }

    private static func normalizedName(_ name: String) -> String {
        name.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func alphabeticalOrder(_ lhs: Candidate, _ rhs: Candidate) -> Bool {
        let lhsKey = sortKey(lhs.name)
        let rhsKey = sortKey(rhs.name)
        if lhsKey != rhsKey { return lhsKey < rhsKey }
        if lhs.name != rhs.name { return lhs.name < rhs.name }
        return lhs.bundleID < rhs.bundleID
    }

    private static func sortKey(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
    }
}

enum AutoPolishAppNameResolver {
    static func displayName(for bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return bundleID
        }
        var name = FileManager.default.displayName(atPath: url.path)
        if name.lowercased().hasSuffix(".app") {
            name.removeLast(4)
        }
        return name.isEmpty ? bundleID : name
    }
}

@MainActor
private final class AutoPolishPickerWindowDelegate: NSObject, NSWindowDelegate {
    let onBecomeKey: () -> Void
    let onClose: () -> Void

    init(onBecomeKey: @escaping () -> Void, onClose: @escaping () -> Void) {
        self.onBecomeKey = onBecomeKey
        self.onClose = onClose
    }

    func windowDidBecomeKey(_ notification: Notification) { onBecomeKey() }
    func windowWillClose(_ notification: Notification) { onClose() }
}

@MainActor
private final class AutoPolishExclusionPickerModel: ObservableObject {
    struct RunningEntry: Identifiable {
        let id: String
        let name: String
        let icon: NSImage?
    }

    @Published private(set) var running: [RunningEntry] = []
    @Published private(set) var excludedNotRunning: [AutoPolishExclusionCatalog.Candidate] = []

    private let settingsModel: TextSettingsModel

    init(settingsModel: TextSettingsModel) {
        self.settingsModel = settingsModel
    }

    func reload() {
        var candidates: [AutoPolishExclusionCatalog.Candidate] = []
        var icons: [String: NSImage] = [:]
        for application in NSWorkspace.shared.runningApplications
            where application.activationPolicy == .regular {
            guard let bundleID = application.bundleIdentifier else { continue }
            let normalizedID = AutoPolishPolicy.normalize(bundleID)
            let name = application.localizedName
                ?? AutoPolishAppNameResolver.displayName(for: bundleID)
            candidates.append(.init(bundleID: bundleID, name: name))
            if icons[normalizedID] == nil, let icon = application.icon {
                icons[normalizedID] = icon
            }
        }

        let groups = AutoPolishExclusionCatalog.groups(
            running: candidates,
            excludedBundleIDs: settingsModel.excludedBundleIDs,
            ownBundleID: Bundle.main.bundleIdentifier,
            resolveName: { bundleID in
                AutoPolishAppNameResolver.displayName(for: bundleID)
            }
        )
        running = groups.running.map {
            RunningEntry(id: $0.bundleID, name: $0.name, icon: icons[$0.bundleID])
        }
        excludedNotRunning = groups.excludedNotRunning
    }

    func toggle(_ bundleID: String) {
        let excluded = settingsModel.excludedBundleIDs.contains(AutoPolishPolicy.normalize(bundleID))
        settingsModel.setExcluded(bundleID, excluded: !excluded)
        reload()
    }

    func remove(_ bundleID: String) {
        settingsModel.removeExcluded(bundleID)
        reload()
    }
}

@MainActor
enum AutoPolishExclusionPicker {
    private static var window: NSPanel?
    private static var windowDelegate: AutoPolishPickerWindowDelegate?

    static func present(model: TextSettingsModel? = nil) {
        let model = model ?? .shared
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }

        let pickerModel = AutoPolishExclusionPickerModel(settingsModel: model)
        let view = AutoPolishExclusionPickerView(
            settingsModel: model,
            pickerModel: pickerModel,
            onDone: dismiss
        )
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 520),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.title = L10n.string(
            "window.auto_polish_picker.title",
            fallback: "Excluded Apps"
        )
        panel.contentViewController = NSHostingController(rootView: view)
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.center()

        let delegate = AutoPolishPickerWindowDelegate(
            onBecomeKey: { pickerModel.reload() },
            onClose: {
                // Deferred: this runs inside the delegate's own windowWillClose,
                // and NSWindow.delegate is weak, so releasing it synchronously
                // could deallocate the delegate under its live method frame.
                DispatchQueue.main.async {
                    window = nil
                    windowDelegate = nil
                }
            }
        )
        panel.delegate = delegate
        windowDelegate = delegate
        window = panel
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private static func dismiss() {
        window?.close()
    }
}

private struct AutoPolishExclusionPickerView: View {
    @ObservedObject var settingsModel: TextSettingsModel
    @ObservedObject var pickerModel: AutoPolishExclusionPickerModel
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.string("picker.auto_polish.heading", fallback: "Choose apps to exclude"))
                .font(.title3.weight(.semibold))
            Text(L10n.string(
                "picker.auto_polish.description",
                fallback: "Auto Polish keeps dictation unchanged in these apps, and Eval Mode never saves their text. Manual selection proofreading still works."
            ))
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    sectionHeader(L10n.string(
                        "picker.auto_polish.section.running",
                        fallback: "Running apps"
                    ))
                    if pickerModel.running.isEmpty {
                        Text(L10n.string(
                            "picker.auto_polish.empty",
                            fallback: "No running apps found."
                        ))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 80)
                    } else {
                        ForEach(Array(pickerModel.running.enumerated()), id: \.element.id) { index, app in
                            runningRow(app, alternateBackground: !index.isMultiple(of: 2))
                        }
                    }

                    if !pickerModel.excludedNotRunning.isEmpty {
                        sectionHeader(L10n.string(
                            "picker.auto_polish.section.not_running",
                            fallback: "Excluded but not running"
                        ))
                        ForEach(pickerModel.excludedNotRunning, id: \.bundleID) { app in
                            excludedRow(app)
                        }
                    }
                }
            }
            .background(Color(NSColor.textBackgroundColor))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(NSColor.separatorColor)))
            .cornerRadius(6)

            HStack {
                Spacer()
                Button(L10n.string("common.button.done", fallback: "Done"), action: onDone)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(minWidth: 380, minHeight: 480)
        .onAppear { pickerModel.reload() }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
            .background(Color(NSColor.controlBackgroundColor))
    }

    private func runningRow(
        _ app: AutoPolishExclusionPickerModel.RunningEntry,
        alternateBackground: Bool
    ) -> some View {
        let isExcluded = settingsModel.excludedBundleIDs.contains(app.id)
        return Button { pickerModel.toggle(app.id) } label: {
            HStack(spacing: 10) {
                if let icon = app.icon {
                    Image(nsImage: icon).resizable().frame(width: 24, height: 24)
                } else {
                    Image(systemName: "app.fill").frame(width: 24, height: 24)
                }
                Text(app.name).lineLimit(1)
                Spacer()
                if isExcluded { Image(systemName: "checkmark") }
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
            .background(alternateBackground
                ? Color(NSColor.alternatingContentBackgroundColors.last ?? .clear)
                : Color.clear)
        }
        .buttonStyle(.plain)
    }

    private func excludedRow(_ app: AutoPolishExclusionCatalog.Candidate) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "app.fill").frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(app.name).lineLimit(1)
                Text(app.bundleID).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Button(L10n.string("picker.auto_polish.remove", fallback: "Remove")) {
                pickerModel.remove(app.bundleID)
            }
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
    }
}
