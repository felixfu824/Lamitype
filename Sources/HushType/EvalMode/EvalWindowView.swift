import AppKit
import SwiftUI

struct EvalWindowView: View {
    @ObservedObject var model: EvalWindowModel
    @State private var rerunExpanded = true

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HSplitView {
                entriesPane.frame(minWidth: 285, idealWidth: 384)
                detailPane.frame(minWidth: 430, maxWidth: .infinity)
            }
            Divider()
            footer
        }
        .frame(minWidth: 760, minHeight: 520)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .bottom) { undoBar }
        .sheet(isPresented: $model.promptEditorPresented) {
            PromptEditorView(model: model)
        }
        .background {
            Group {
                Button("") { model.setLabel(nil) }
                    .keyboardShortcut("0", modifiers: .command)
                Button("") { model.setLabel(.correct) }
                    .keyboardShortcut("1", modifiers: .command)
                Button("") { model.setLabel(.overEdited) }
                    .keyboardShortcut("2", modifiers: .command)
                Button("") { model.setLabel(.wrongOrMissed) }
                    .keyboardShortcut("3", modifiers: .command)
                Button("") { model.deleteSelected() }
                    .keyboardShortcut(.delete, modifiers: .command)
            }
            .frame(width: 1, height: 1)
            .opacity(0.001)
            .accessibilityHidden(true)
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(headerStateText)
                    .font(.headline)
                HStack(spacing: 10) {
                    labelTally
                    if model.suppressedCount > 0 {
                        Text(L10n.format(
                            "eval.header.suppressed",
                            "%1$ld not captured",
                            arguments: [model.suppressedCount]
                        ))
                        .help(L10n.string(
                            "eval.header.suppressed_tooltip",
                            fallback: "Secure input, excluded app, or unknown app"
                        ))
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if model.entries.count >= EvalStore.maximumEntries {
                    Text(L10n.string(
                        "eval.header.capture_limit",
                        fallback: "500-entry limit reached. Delete entries to capture more."
                    ))
                    .font(.caption)
                    .foregroundStyle(.orange)
                }
            }
            Spacer()
            Button(L10n.string("eval.prompt.edit", fallback: "Edit Polish Prompt")) {
                model.showPromptEditor()
            }
            Button(model.evalEnabled
                   ? L10n.string("eval.header.turn_off", fallback: "Turn Off")
                   : L10n.string("eval.header.turn_on", fallback: "Turn On")) {
                model.toggleEvalMode()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var headerStateText: String {
        let count = L10n.plural("eval.entries_count", model.entries.count, fallback: "%ld entries")
        return model.evalEnabled
            ? L10n.format("eval.header.on", "Eval Mode is on. %1$@.", arguments: [count])
            : L10n.format("eval.header.off", "Eval Mode is off. %1$@.", arguments: [count])
    }

    private var labelTally: some View {
        let counts = model.labelledCounts
        return HStack(spacing: 7) {
            Label("\(counts.correct)", systemImage: "checkmark.circle")
                .help(labelText(.correct))
            Text("·")
            Label("\(counts.overEdited)", systemImage: "scissors")
                .help(labelText(.overEdited))
            Text("·")
            Label("\(counts.wrongOrMissed)", systemImage: "xmark.circle")
                .help(labelText(.wrongOrMissed))
            Text(L10n.format(
                "eval.header.unlabelled",
                "%1$ld unlabelled",
                arguments: [counts.unlabelled]
            ))
        }
    }

    private var entriesPane: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Picker(L10n.string("eval.filter.outcome_title", fallback: "Outcome"), selection: $model.outcomeFilter) {
                    ForEach(EvalWindowModel.OutcomeFilter.allCases, id: \.self) {
                        Text(outcomeFilterText($0)).tag($0)
                    }
                }
                .labelsHidden()
                Picker(L10n.string("eval.detail.label", fallback: "Label"), selection: $model.labelFilter) {
                    ForEach(EvalWindowModel.LabelFilter.allCases, id: \.self) {
                        Text(labelFilterText($0)).tag($0)
                    }
                }
                .labelsHidden()
            }
            .padding(10)

            Divider()

            if model.filteredEntries.isEmpty {
                if model.entries.isEmpty {
                    emptyState
                } else {
                    filteredEmptyState
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(model.filteredEntries.enumerated()), id: \.element.id) { index, entry in
                            entryRow(entry, alternate: !index.isMultiple(of: 2))
                        }
                    }
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var filteredEmptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "line.3.horizontal.decrease.circle")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text(L10n.string("eval.filter.empty", fallback: "No entries match these filters."))
                .font(.headline)
                .multilineTextAlignment(.center)
            Button(L10n.string("eval.filter.reset", fallback: "Clear Filters")) {
                model.outcomeFilter = .all
                model.labelFilter = .all
            }
            Spacer()
        }
        .padding(24)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "wand.and.stars")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text(L10n.string("eval.empty.title", fallback: "No entries yet."))
                .font(.headline)
            Text(L10n.string(
                "eval.empty.body",
                fallback: "Turn Eval Mode on, then dictate or polish a selection. Each result shows up here with a diff. Excluded apps and secure input are never captured."
            ))
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            if !model.evalEnabled {
                Button(L10n.string("eval.header.turn_on", fallback: "Turn On")) {
                    model.toggleEvalMode()
                }
            }
            Spacer()
        }
        .padding(24)
    }

    private func entryRow(_ entry: EvalEntry, alternate: Bool) -> some View {
        Button { model.selectedID = entry.id } label: {
            HStack(spacing: 9) {
                appIcon(entry.appBundleID)
                    .resizable()
                    .frame(width: 26, height: 26)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 7) {
                        Text(Self.timeFormatter.string(from: entry.capturedAt))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Text(String(entry.original.prefix(70))
                            .replacingOccurrences(of: "\n", with: " "))
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        outcomePill(entry.outcome)
                    }
                    if entry.outcome == .keptOriginal
                        || entry.outcome == .notPolished
                        || entry.elapsedMS != nil
                        || entry.label != nil {
                        HStack(spacing: 7) {
                            if entry.outcome == .keptOriginal || entry.outcome == .notPolished {
                                Text(EvalReasonText.string(for: entry.reason)).lineLimit(1)
                            }
                            Spacer()
                            if let elapsedMS = entry.elapsedMS {
                                Text("\(elapsedMS) ms").monospacedDigit()
                            }
                            if let label = entry.label {
                                Image(systemName: labelSymbol(label)).help(labelText(label))
                            }
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(rowBackground(entry, alternate: alternate))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var detailPane: some View {
        if let entry = model.selectedEntry {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(metadata(entry))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    textSection(
                        title: L10n.string("eval.detail.original", fallback: "Original"),
                        text: AttributedString(entry.original)
                    )
                    resultSection(entry)
                    labelControls(entry)
                    rerunSection(entry)
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            Color.clear
        }
    }

    private func resultSection(_ entry: EvalEntry) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(L10n.string("eval.detail.result", fallback: "Result"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if entry.outcome == .polished { PolishDiffLegend() }
            }
            Text(entry.outcome == .polished
                 ? PolishDiff.attributed(original: entry.original, polished: entry.output)
                    ?? AttributedString(entry.output)
                 : AttributedString(entry.output))
                .font(.system(size: 15))
                .lineSpacing(4)
                .textSelection(.enabled)
            if entry.outcome == .unchanged {
                Text(L10n.string("eval.detail.no_changes", fallback: "No changes."))
                    .font(.caption).foregroundStyle(.secondary)
            } else if entry.outcome == .keptOriginal || entry.outcome == .notPolished {
                Text(EvalReasonText.string(for: entry.reason))
                    .font(.caption).foregroundStyle(.secondary)
                if entry.outcome == .notPolished && entry.reason == "disabled" {
                    Text(L10n.string(
                        "eval.detail.rerun_hint_disabled",
                        fallback: "Rerun to see what polishing would have done."
                    ))
                    .font(.caption).foregroundStyle(.secondary)
                }
            }

            if let latest = entry.reruns.last {
                rerunResult(latest, original: entry.original, baseline: entry.output)
            }
        }
    }

    private func labelControls(_ entry: EvalEntry) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(L10n.string("eval.detail.label", fallback: "Label"))
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            HStack {
                labelButton(.correct, active: entry.label == .correct)
                labelButton(.overEdited, active: entry.label == .overEdited)
                labelButton(.wrongOrMissed, active: entry.label == .wrongOrMissed)
                Spacer()
                Button(role: .destructive) { model.deleteSelected() } label: {
                    Image(systemName: "trash")
                }
            }
        }
    }

    private func rerunSection(_ entry: EvalEntry) -> some View {
        DisclosureGroup(isExpanded: $rerunExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.string(
                    "eval.rerun.instructions_note",
                    fallback: "Reruns use the current prompt draft. Saving makes it active for future requests."
                ))
                .font(.caption).foregroundStyle(.secondary)
                if model.hasUnsavedPromptDraft {
                    Text(L10n.string("eval.prompt.unsaved", fallback: "Unsaved draft"))
                        .font(.caption).foregroundStyle(.orange)
                }

                if let reason = model.rerunUnavailableReason {
                    Text(reason).font(.caption).foregroundStyle(.secondary)
                }
                if model.batchStoppedForDictation {
                    Text(L10n.string(
                        "eval.rerun.stopped_dictation",
                        fallback: "Stopped: dictation started."
                    ))
                    .font(.caption).foregroundStyle(.orange)
                }
                if let progress = model.batchProgress {
                    Text(L10n.format(
                        "eval.rerun.progress",
                        "%1$ld of %2$ld",
                        arguments: [progress.completed, progress.total]
                    ))
                    .font(.caption).monospacedDigit()
                }

                HStack {
                    Button(L10n.string("eval.rerun.run", fallback: "Rerun")) {
                        model.rerunSelected()
                    }
                    .disabled(model.rerunBusy || model.rerunUnavailableReason != nil)

                    Button(batchTitle) { model.rerunShown() }
                        .disabled(model.rerunBusy || model.rerunUnavailableReason != nil)

                    if model.batchProgress != nil {
                        Button(L10n.string("eval.rerun.cancel", fallback: "Cancel")) {
                            model.cancelBatch()
                        }
                    }

                    Spacer()
                    Button(L10n.string("eval.prompt.edit", fallback: "Edit Polish Prompt")) {
                        model.showPromptEditor()
                    }
                }

                if model.batchProgress != nil {
                    Text(L10n.string(
                        "eval.rerun.cancel_note",
                        fallback: "Cancel stops after the current entry finishes."
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                if entry.reruns.count > 1 {
                    DisclosureGroup(L10n.format(
                        "eval.rerun.previous",
                        "Previous reruns (%1$ld)",
                        arguments: [entry.reruns.count - 1]
                    )) {
                        ForEach(Array(entry.reruns.dropLast().reversed().enumerated()), id: \.offset) { _, rerun in
                            rerunResult(rerun, original: entry.original, baseline: entry.output)
                                .padding(.vertical, 5)
                        }
                    }
                }
            }
            .padding(.top, 8)
        } label: {
            Text(L10n.string("eval.detail.rerun", fallback: "Rerun"))
                .font(.headline)
        }
    }

    private var batchTitle: String {
        let count = model.filteredEntries.count
        if count > 50 {
            return L10n.string(
                "eval.rerun.run_shown_capped",
                fallback: "Rerun Shown (first 50)"
            )
        }
        return L10n.format(
            "eval.rerun.run_shown",
            "Rerun Shown (%1$ld)",
            arguments: [count]
        )
    }

    private func rerunResult(
        _ rerun: EvalRerun,
        original: String,
        baseline: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(L10n.format(
                "eval.rerun.result_line",
                "Rerun · %1$@ · %2$@",
                arguments: ["\(rerun.elapsedMS) ms", outcomeText(rerun.outcome)]
            ))
            .font(.caption.weight(.semibold))
            Text(PolishDiff.attributed(original: original, polished: rerun.output)
                 ?? AttributedString(rerun.output))
                .textSelection(.enabled)
            Text(rerun.output == baseline
                 ? L10n.string("eval.rerun.same_as_original", fallback: "Same as the original result")
                 : L10n.string("eval.rerun.differs_from_original", fallback: "Different from the original result"))
                .font(.caption).foregroundStyle(.secondary)
            if let reason = rerun.reason {
                Text(EvalReasonText.string(for: reason))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var footer: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Button(L10n.string("eval.footer.export", fallback: "Export…")) {
                    model.exportShown()
                }
                .disabled(model.filteredEntries.isEmpty)
                Text(L10n.string(
                    "eval.footer.export_note",
                    fallback: "Entries clear on quit. Export to keep a copy."
                ))
                .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Button(L10n.string("eval.footer.reveal", fallback: "Reveal in Finder")) {
                model.revealInFinder()
            }
            if model.entries.count >= 100 {
                Button(L10n.string("eval.footer.delete_oldest", fallback: "Delete Oldest 100")) {
                    model.deleteOldest100()
                }
            }
            Button(L10n.string("eval.footer.delete_all", fallback: "Delete All…"), role: .destructive) {
                model.deleteAll()
            }
            .disabled(model.entries.isEmpty)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var undoBar: some View {
        if model.pendingDeletion != nil {
            Button(L10n.string("eval.deleted_undo", fallback: "Deleted. Undo")) {
                model.undoDelete()
            }
            .buttonStyle(.borderedProminent)
            .padding(.bottom, 55)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private func textSection(title: String, text: AttributedString) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(text).font(.system(size: 15)).lineSpacing(4).textSelection(.enabled)
        }
    }

    @ViewBuilder
    private func labelButton(_ label: EvalLabel, active: Bool) -> some View {
        if active {
            Button(labelText(label)) { model.setLabel(label) }
                .buttonStyle(.borderedProminent)
        } else {
            Button(labelText(label)) { model.setLabel(label) }
                .buttonStyle(.bordered)
        }
    }

    private func outcomePill(_ outcome: EvalOutcome) -> some View {
        Text(outcomeText(outcome))
            .font(.caption2.weight(outcome == .notPolished ? .regular : .semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(pillColor(outcome))
            .background(pillColor(outcome).opacity(0.13), in: Capsule())
    }

    private func rowBackground(_ entry: EvalEntry, alternate: Bool) -> Color {
        if model.selectedID == entry.id { return Color.accentColor.opacity(0.15) }
        return alternate
            ? Color(nsColor: .alternatingContentBackgroundColors.last ?? .clear)
            : .clear
    }

    private func metadata(_ entry: EvalEntry) -> String {
        var parts = [
            sourceText(entry.source),
            AutoPolishAppNameResolver.displayName(for: entry.appBundleID)
        ]
        if let elapsedMS = entry.elapsedMS { parts.append("\(elapsedMS) ms") }
        parts.append(Self.timestampFormatter.string(from: entry.capturedAt))
        if entry.abandoned {
            parts.append(L10n.string("eval.detail.not_inserted", fallback: "Not inserted"))
        }
        return parts.joined(separator: " · ")
    }

    private func sourceText(_ source: EvalSource) -> String {
        switch source {
        case .dictation: return L10n.string("eval.source.dictation", fallback: "Dictation")
        case .dictationLocalOnce:
            return L10n.string("eval.source.dictation_local_once", fallback: "Dictation (local once)")
        case .polishHotkey:
            return L10n.string("eval.source.polish_hotkey", fallback: "Text Polish (hotkey)")
        case .polishService:
            return L10n.string("eval.source.polish_service", fallback: "Text Polish (Services)")
        }
    }

    private func outcomeText(_ outcome: EvalOutcome) -> String {
        switch outcome {
        case .polished: return L10n.string("eval.pill.polished", fallback: "Polished")
        case .unchanged: return L10n.string("eval.pill.no_change", fallback: "No change")
        case .keptOriginal: return L10n.string("eval.pill.kept_original", fallback: "Kept original")
        case .notPolished: return L10n.string("eval.pill.not_polished", fallback: "Not polished")
        }
    }

    private func labelText(_ label: EvalLabel) -> String {
        switch label {
        case .correct: return L10n.string("eval.label.correct", fallback: "Correct")
        case .overEdited: return L10n.string("eval.label.over_edited", fallback: "Over-edited")
        case .wrongOrMissed:
            return L10n.string("eval.label.wrong_or_missed", fallback: "Wrong or missed")
        }
    }

    private func labelSymbol(_ label: EvalLabel) -> String {
        switch label {
        case .correct: return "checkmark.circle"
        case .overEdited: return "scissors"
        case .wrongOrMissed: return "xmark.circle"
        }
    }

    private func pillColor(_ outcome: EvalOutcome) -> Color {
        switch outcome {
        case .polished: return .green
        case .unchanged, .notPolished: return .secondary
        case .keptOriginal: return .orange
        }
    }

    private func outcomeFilterText(_ filter: EvalWindowModel.OutcomeFilter) -> String {
        switch filter {
        case .all: return L10n.string("eval.filter.outcome.all", fallback: "All")
        case .polished: return L10n.string("eval.filter.outcome.polished", fallback: "Polished")
        case .unchanged: return L10n.string("eval.filter.outcome.no_change", fallback: "No change")
        case .keptOriginal:
            return L10n.string("eval.filter.outcome.kept_original", fallback: "Kept original")
        case .notPolished:
            return L10n.string("eval.filter.outcome.not_polished", fallback: "Not polished")
        }
    }

    private func labelFilterText(_ filter: EvalWindowModel.LabelFilter) -> String {
        switch filter {
        case .all: return L10n.string("eval.filter.label.all", fallback: "All")
        case .correct:
            return L10n.string("eval.filter.label.correct", fallback: "Correct")
        case .overEdited:
            return L10n.string("eval.filter.label.over_edited", fallback: "Over-edited")
        case .wrongOrMissed:
            return L10n.string("eval.filter.label.wrong_or_missed", fallback: "Wrong or missed")
        case .unlabelled: return L10n.string("eval.filter.label.unlabelled", fallback: "Unlabelled")
        }
    }

    private func appIcon(_ bundleID: String) -> Image {
        Image(nsImage: EvalAppIconCache.icon(for: bundleID))
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = L10n.effectiveLocale
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = L10n.effectiveLocale
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter
    }()
}

private struct PromptEditorView: View {
    @ObservedObject var model: EvalWindowModel
    @FocusState private var editorFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.string("eval.prompt.title", fallback: "Polish Prompt"))
                .font(.title2.weight(.semibold))
            Text(L10n.string(
                "eval.prompt.note",
                fallback: "This complete prompt is used by manual polish, Auto Polish Dictation, and Eval reruns. Reruns can test this unsaved draft."
            ))
            .font(.caption)
            .foregroundStyle(.secondary)
            TextEditor(text: $model.instructionsText)
                .font(.system(.body, design: .monospaced))
                .focused($editorFocused)
                .frame(minWidth: 680, minHeight: 340)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color(nsColor: .separatorColor)))
            if let error = model.promptSaveError {
                Text(error).font(.caption).foregroundStyle(.red)
            } else if model.hasUnsavedPromptDraft {
                Text(L10n.string("eval.prompt.unsaved", fallback: "Unsaved draft"))
                    .font(.caption).foregroundStyle(.orange)
            }
            HStack {
                Button(L10n.string("eval.prompt.done", fallback: "Done")) {
                    model.requestClosePromptEditor()
                }
                Spacer()
                Button(L10n.string("eval.prompt.restore", fallback: "Restore Default")) {
                    model.restoreDefaultDraft()
                }
                Button(L10n.string("eval.prompt.save", fallback: "Save Prompt")) {
                    _ = model.savePrompt()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(18)
        .onAppear { editorFocused = true }
    }
}

@MainActor
private enum EvalAppIconCache {
    private static var icons: [String: NSImage] = [:]

    static func icon(for bundleID: String) -> NSImage {
        let key = AutoPolishPolicy.normalize(bundleID)
        if let cached = icons[key] { return cached }

        let icon: NSImage
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            icon = NSWorkspace.shared.icon(forFile: url.path)
        } else {
            icon = NSImage(systemSymbolName: "app.fill", accessibilityDescription: nil)
                ?? NSImage(size: NSSize(width: 26, height: 26))
        }
        icons[key] = icon
        return icon
    }
}
