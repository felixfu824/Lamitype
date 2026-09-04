import SwiftUI

struct PolishCardView: View {
    let originalText: String
    let polishedText: String
    let changed: Bool

    /// Track-changes rendering; nil when the selection exceeds the diff
    /// token cap, in which case the card shows the polished text plain.
    private let diffText: AttributedString?

    init(originalText: String, polishedText: String, changed: Bool) {
        self.originalText = originalText
        self.polishedText = polishedText
        self.changed = changed
        self.diffText = changed
            ? PolishDiff.attributed(original: originalText, polished: polishedText)
            : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(changed
                     ? L10n.string("polish.card.changed_title", fallback: "Text Polished")
                     : L10n.string("polish.card.no_changes_title", fallback: "No changes needed"))
                    .font(.headline)

                Spacer()

                if changed {
                    Label(
                        L10n.string("translation.card.copied", fallback: "Copied to clipboard"),
                        systemImage: "checkmark.circle.fill"
                    )
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }

            Divider()

            if changed {
                HStack {
                    Text(L10n.string("polish.card.changes", fallback: "Changes"))
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Spacer()

                    if diffText != nil {
                        PolishDiffLegend()
                    }
                }
            }

            ScrollView {
                Text(diffText ?? AttributedString(polishedText))
                    .font(.system(size: 15))
                    .lineSpacing(4)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 420)

            HStack(alignment: .bottom) {
                Text(L10n.string("polish.card.dismiss", fallback: "Click outside to dismiss"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Spacer()

                Text(L10n.string(
                    "polish.card.privacy",
                    fallback: "On-device Apple Intelligence; nothing leaves your Mac."
                ))
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.trailing)
            }
        }
        .padding(24)
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.18), radius: 12, x: 0, y: 4)
    }
}
