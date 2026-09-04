import SwiftUI

struct PolishDiffLegend: View {
    var body: some View {
        HStack(spacing: 4) {
            Text(L10n.string("polish.card.legend.removed", fallback: "removed"))
                .strikethrough()
                .foregroundStyle(Color(nsColor: .systemRed))
            Text("·")
                .foregroundStyle(.secondary)
            Text(L10n.string("polish.card.legend.added", fallback: "added"))
                .underline()
                .foregroundStyle(Color(nsColor: .systemGreen))
        }
        .font(.caption)
    }
}
