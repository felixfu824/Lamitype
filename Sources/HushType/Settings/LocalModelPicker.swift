import SwiftUI

/// Settings › Dictation "Local model" row: Fast / Optimized with download,
/// switching and error states. All actions go through LocalModelSwitcher.
struct LocalModelPicker: View {
    @ObservedObject var switcher: LocalModelSwitcher
    @State private var busyNotice = false

    var body: some View {
        Group {
            SettingRow(L10n.string("settings.dictation.model", fallback: "Model")) {
                // The model matrix drives the choices through their native AX radio buttons.
                Picker(L10n.string("settings.dictation.model", fallback: "Model"), selection: Binding(
                    get: { switcher.shownSelection },
                    set: { busyNotice = !switcher.select($0) }
                )) {
                    modelLabel(.fast).tag(AppConfig.LocalModel.fast)
                    modelLabel(.optimized).tag(AppConfig.LocalModel.optimized)
                }
                .labelsHidden()
                .pickerStyle(.radioGroup)
                .horizontalRadioGroupLayout()
                .modifier(SettingsActiveTint())
                .disabled(switcher.isSwitching)
                .accessibilityIdentifier("local-model-picker")
            }

            switch switcher.phase {
            case .switching(let target, _, _):
                progressRow(target: target)
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
                SettingsStatusLabel(
                    kind: .warning,
                    text: L10n.string("settings.local_model.busy", fallback: "Finish the current dictation before switching models.")
                )
            }
        }
        .onChange(of: switcher.phase) { _, _ in busyNotice = false }
    }

    private func modelLabel(_ model: AppConfig.LocalModel) -> some View {
        let size = L10n.format("settings.local_model.size", "%1$ld MB", arguments: [model.downloadMB])
        let detail = !switcher.isSwitching && !switcher.isOnDisk(model)
            ? L10n.format("settings.local_model.size_missing", "%1$@ · Not downloaded", arguments: [size])
            : size
        return SettingLabel(title: model.displayName, description: detail)
    }

    private func progressRow(target: AppConfig.LocalModel) -> some View {
        SettingRow(
            progressTitle(target: target),
            description: L10n.format(
                "settings.local_model.keeps_current",
                "Dictation keeps using %1$@ until the new model is ready.",
                arguments: [switcher.active.shortName]
            )
        ) {
            HStack(spacing: 8) {
                if let percent = switcher.downloadPercent {
                    ProgressView(value: Double(percent), total: 100)
                        .frame(width: 76)
                } else {
                    ProgressView()
                }
                Button(L10n.string("common.button.cancel", fallback: "Cancel")) { switcher.cancel() }
                    .disabled(switcher.gateClosed)
            }
        }
    }

    private func progressTitle(target: AppConfig.LocalModel) -> String {
        if let percent = switcher.downloadPercent {
            return L10n.format("settings.local_model.downloading", "Downloading… %1$ld%% of %2$ld MB",
                               arguments: [percent, target.downloadMB])
        }
        return switcher.waitingForIdle
            ? L10n.string("settings.local_model.waiting", fallback: "Waiting for dictation to finish…")
            : L10n.string("settings.local_model.loading", fallback: "Loading model…")
    }

    private func failureRow(target: AppConfig.LocalModel, loadFailure: Bool, nothingLoaded: Bool = false) -> some View {
        LabeledContent {
            Button(L10n.string("settings.local_model.try_again", fallback: "Try Again")) {
                busyNotice = !switcher.select(target)
            }
        } label: {
            SettingsStatusLabel(kind: .warning, text: failureMessage(target, loadFailure: loadFailure, nothingLoaded: nothingLoaded))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func failureMessage(_ target: AppConfig.LocalModel, loadFailure: Bool, nothingLoaded: Bool) -> String {
        if nothingLoaded {
            return L10n.format("settings.local_model.nothing_loaded",
                              "Couldn’t load the %1$@ model. Check your connection, then try again.",
                              arguments: [target.shortName])
        }
        return L10n.format(
            loadFailure ? "settings.local_model.load_failed" : "settings.local_model.failed",
            loadFailure
                ? "Couldn’t load the %1$@ model. Try again. Lamitype is still using %2$@."
                : "Couldn’t download the %1$@ model. Check your connection, then try again. Lamitype is still using %2$@.",
            arguments: [target.shortName, switcher.active.shortName]
        )
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
