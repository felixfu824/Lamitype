import AppKit
import CoreText
import Settings
import SwiftUI

struct AboutPane: View {
    let onCheckForUpdates: () -> Void
    var bundleInfo = Bundle.main.infoDictionary ?? [:]
    @ObservedObject private var updates = UpdateCheckCoordinator.shared

    static let coauthors = [
        "Claude (Anthropic)",
        "Codex (OpenAI)",
        "Pi (Qwen 3.8 27B)",
    ]

    private static let repositoryURL = URL(string: "https://github.com/felixfu824/lamitype")!

    var body: some View {
        VStack(spacing: 0) {
            identity
            SettingsPage(height: 424) {
                Section {
                    SettingRow(L10n.string("settings.about.author", fallback: "Author")) {
                        Text("Felix Fu")
                    }
                    SettingRow(L10n.string("settings.about.coauthors", fallback: "Co-authors")) {
                        VStack(alignment: .trailing, spacing: 2) {
                            ForEach(Self.coauthors, id: \.self) { coauthor in
                                Text(coauthor)
                            }
                        }
                    }
                    SettingRow(L10n.string("settings.about.license", fallback: "License")) {
                        Text("MIT")
                    }
                    SettingRow(L10n.string("settings.about.repository", fallback: "Repository")) {
                        Link(destination: Self.repositoryURL) {
                            Text(verbatim: "github.com/felixfu824/lamitype")
                                .underline()
                                .foregroundStyle(.primary)
                        }
                        .buttonStyle(.plain)
                    }
                }

                Section {
                    SettingRow(
                        L10n.string("settings.about.software_update", fallback: "Software update"),
                        description: Self.lastCheckedText(lastSuccess: updates.lastSuccessfulCheck)
                    ) {
                        Button(L10n.string("settings.about.check_updates", fallback: "Check for Updates…"),
                               action: onCheckForUpdates)
                    }
                    Toggle(
                        L10n.string("update.daily.enabled", fallback: "Check automatically every day"),
                        isOn: Binding(get: { updates.autoCheckEnabled }, set: { updates.setAutoCheckEnabled($0) })
                    )
                    .toggleStyle(.switch)
                    .modifier(SettingsActiveTint())
                    if let attempt = updates.lastFailedAutomaticAttempt {
                        SettingsStatusLabel(kind: .warning, text: Self.failedAttemptText(attempt))
                    }
                    if let version = updates.availableVersion {
                        SettingRow(L10n.format("update.daily.available", "v%1$@ is available", arguments: [version])) {
                            Link(L10n.string("alert.update.view_github", fallback: "View on GitHub"),
                                 destination: UpdateCheckCoordinator.releasesURL)
                                .buttonStyle(.link)
                        }
                    }
                } header: {
                    Text(L10n.string("settings.about.updates", fallback: "Updates"))
                } footer: {
                    SettingsNote(L10n.string("update.daily.disclosure", fallback: "Lamitype checks GitHub now and daily. GitHub sees your IP address. Turning this on also permits manual checks."))
                }
            }
        }
        .frame(width: SettingsPage<EmptyView>.width)
    }

    private var identity: some View {
        VStack(spacing: 4) {
            Image(nsImage: NSImage(named: "AppIcon") ?? NSApp.applicationIconImage)
                .resizable()
                .scaledToFit()
                .frame(width: 64, height: 64)
                .accessibilityHidden(true)
            Text("Lamitype")
                .font(Self.wordmarkFont)
                .tracking(-0.75)
            Text(versionAndBuild)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(productDescription)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 485)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity)
    }

    private static var wordmarkFont: Font {
        let postScriptName = "Fraunces-9ptBlack"
        let base = CTFontCreateWithName(postScriptName as CFString, 36, nil)
        guard CTFontCopyPostScriptName(base) as String == postScriptName else {
            return .system(size: 36, weight: .semibold, design: .serif)
        }
        // OpenType axis identifiers for weight and optical size.
        let variation = CTFontDescriptorCreateWithAttributes([
            kCTFontVariationAttribute: [0x77676874: 650, 0x6F70737A: 36],
        ] as CFDictionary)
        return Font(CTFontCreateCopyWithAttributes(base, 36, nil, variation))
    }

    static func makeSettingsPane(
        onCheckForUpdates: @escaping () -> Void
    ) -> AppSettings.Pane<AboutPane> {
        let title = L10n.string("settings.tab.about", fallback: "About")
        return AppSettings.Pane(
            identifier: .about,
            title: title,
            toolbarIcon: NSImage(
                systemSymbolName: "info.circle",
                accessibilityDescription: title
            )!
        ) {
            AboutPane(onCheckForUpdates: onCheckForUpdates)
        }
    }

    static func lastCheckedText(lastSuccess: Date?) -> String {
        guard let date = lastSuccess else {
            return L10n.string("update.daily.never", fallback: "Not yet checked")
        }
        let formatter = DateFormatter()
        formatter.locale = L10n.effectiveLocale
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return L10n.format("update.daily.last_checked", "Last checked: %1$@", arguments: [formatter.string(from: date)])
    }

    static func failedAttemptText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = L10n.effectiveLocale
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return L10n.format("update.daily.last_attempt_failed", "Last attempt failed: %1$@",
                           arguments: [formatter.string(from: date)])
    }

    private var versionAndBuild: String {
        let version = bundleInfo["CFBundleShortVersionString"] as? String ?? "?"
        let build = bundleInfo["CFBundleVersion"] as? String ?? "?"
        return L10n.format(
            "settings.about.version_build",
            "Version %1$@ (Build %2$@)",
            arguments: [version, build]
        )
    }

    private var productDescription: String {
        L10n.string(
            "about.body",
            fallback: "Local voice-to-text for macOS. English, Chinese and Japanese, with Traditional Chinese output."
        )
    }
}
