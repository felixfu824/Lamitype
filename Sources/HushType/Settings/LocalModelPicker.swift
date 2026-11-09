import SwiftUI

/// Settings › Dictation "Local model" row: Fast / Optimized with download,
/// switching and error states. All actions go through LocalModelSwitcher.
struct LocalModelPicker: View {
    @ObservedObject var switcher: LocalModelSwitcher
    let enabled: Bool
    @State private var busyNotice = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("", selection: Binding(
                get: { switcher.shownSelection },
                set: { busyNotice = !switcher.select($0) }
            )) {
                choice(.fast).tag(AppConfig.LocalModel.fast)
                choice(.optimized).tag(AppConfig.LocalModel.optimized)
            }
            .labelsHidden()
            .pickerStyle(.radioGroup)
            .disabled(!enabled || switcher.isSwitching)
            .accessibilityIdentifier("local-model-picker")

            switch switcher.phase {
            case .switching(let target, _, let progress):
                progressRow(target: target, progress: progress)
            case .failed(let target):
                failureRow(target: target, loadFailure: false)
            case .loadFailed(let target):
                failureRow(target: target, loadFailure: true)
            case .notLoaded(let target):
                failureRow(target: target, loadFailure: true, nothingLoaded: true)
            case .idle:
                EmptyView()
            }

            if busyNotice {
                Text(L10n.string(
                    "settings.local_model.busy",
                    fallback: "Finish the current dictation before switching models."
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .onChange(of: switcher.phase) { _, _ in busyNotice = false }
    }

    private func choice(_ model: AppConfig.LocalModel) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(model.displayName)
            Text(detail(model))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func detail(_ model: AppConfig.LocalModel) -> String {
        var parts: [String]
        switch model {
        case .fast:
            parts = [L10n.string("settings.local_model.fast.detail", fallback: "Fastest")]
        case .optimized:
            parts = [L10n.string(
                "settings.local_model.optimized.detail",
                fallback: "Recommended · same weight size as Fast"
            )]
        }
        parts.append(L10n.format("settings.local_model.size", "%1$ld MB", arguments: [model.downloadMB]))
        if case .switching(let target, _, _) = switcher.phase, model == switcher.active, target != model {
            parts.append(L10n.string("settings.local_model.in_use_until_ready", fallback: "in use until the new model is ready"))
        } else if model != switcher.active, !switcher.isSwitching, !switcher.isOnDisk(model) {
            parts.append(L10n.string("settings.local_model.not_downloaded", fallback: "Not downloaded"))
        }
        return parts.joined(separator: " · ")
    }

    private func progressRow(target: AppConfig.LocalModel, progress: Double) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let percent = switcher.downloadPercent {
                ProgressView(value: Double(percent), total: 100)
                    .frame(width: 260)
            }
            HStack(spacing: 10) {
                if let percent = switcher.downloadPercent {
                    Text(L10n.format(
                        "settings.local_model.downloading",
                        "Downloading… %1$ld%% of %2$ld MB",
                        arguments: [percent, target.downloadMB]
                    ))
                    .font(.caption)
                    .fixedSize()
                } else {
                    ProgressView().controlSize(.small)
                    Text(switcher.waitingForIdle
                         ? L10n.string("settings.local_model.waiting", fallback: "Waiting for dictation to finish…")
                         : L10n.string("settings.local_model.loading", fallback: "Loading model…"))
                        .font(.caption)
                        .fixedSize()
                }
                Button(L10n.string("common.button.cancel", fallback: "Cancel")) { switcher.cancel() }
                    .controlSize(.small)
                    .fixedSize()
                    .disabled(switcher.gateClosed)
            }
            Text(L10n.format(
                "settings.local_model.keeps_current",
                "Dictation keeps using %1$@ until the new model is ready.",
                arguments: [switcher.active.shortName]
            ))
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.leading, 20)
    }

    private func failureRow(target: AppConfig.LocalModel, loadFailure: Bool, nothingLoaded: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Group {
                if nothingLoaded {
                    Text(L10n.format(
                        "settings.local_model.nothing_loaded",
                        "Couldn’t load the %1$@ model. Check your connection, then try again.",
                        arguments: [target.shortName]
                    ))
                } else {
                    Text(L10n.format(
                        loadFailure ? "settings.local_model.load_failed" : "settings.local_model.failed",
                        loadFailure
                            ? "Couldn’t load the %1$@ model. Try again. Lamitype is still using %2$@."
                            : "Couldn’t download the %1$@ model. Check your connection, then try again. Lamitype is still using %2$@.",
                        arguments: [target.shortName, switcher.active.shortName]
                    ))
                }
            }
            .font(.caption)
            .fixedSize(horizontal: false, vertical: true)
            Button(L10n.string("settings.local_model.try_again", fallback: "Try Again")) {
                busyNotice = !switcher.select(target)
            }
            .controlSize(.small)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.orange.opacity(0.12)))
        .padding(.leading, 20)
    }
}

extension AppConfig.LocalModel {
    /// Name without the bit width, for sentences.
    var shortName: String {
        switch self {
        case .fast: return L10n.string("local_model.fast.short", fallback: "Fast")
        case .optimized: return L10n.string("local_model.optimized.short", fallback: "Optimized")
        }
    }
}
