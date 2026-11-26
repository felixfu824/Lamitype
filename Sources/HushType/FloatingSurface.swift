import SwiftUI

extension View {
    /// Clips the surface and draws its outline after the caller applies its background.
    func floatingSurface(
        cornerRadius: CGFloat,
        stroke: Color = .primary.opacity(0.08),
        lineWidth: CGFloat = 0.5
    ) -> some View {
        let outline = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return clipShape(outline)
            .overlay(outline.stroke(stroke, lineWidth: lineWidth))
    }
}
