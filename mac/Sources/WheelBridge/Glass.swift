import SwiftUI

/// Liquid Glass helpers, following the same approach as Bridge.
///
/// The glass APIs arrived in macOS 26, and WheelBridge still runs on macOS 13, so
/// every use goes through these wrappers: real glass on 26 and later, and a
/// material-backed shape before that.
extension View {
    /// A floating surface: glass in a rounded rectangle.
    @ViewBuilder
    func glassPanel(cornerRadius: CGFloat = 22, tint: Color? = nil) -> some View {
        if #available(macOS 26.0, *) {
            // Glass is a hint of colour, so a tint is heavily diluted.
            let glass = tint.map { Glass.regular.tint($0.opacity(0.22)) } ?? .regular
            self.glassEffect(glass, in: .rect(cornerRadius: cornerRadius, style: .continuous))
        } else {
            self.background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(tint.map { AnyShapeStyle($0.opacity(0.18)) } ?? AnyShapeStyle(.ultraThinMaterial))
            )
        }
    }

    /// A glass capsule, for floating controls.
    @ViewBuilder
    func glassCapsule() -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: .capsule)
        } else {
            self.background(Capsule().fill(.ultraThinMaterial))
        }
    }

    /// The main call to action.
    @ViewBuilder
    func glassProminentButton() -> some View {
        if #available(macOS 26.0, *) {
            self.buttonStyle(.glassProminent)
        } else {
            self.buttonStyle(.borderedProminent)
        }
    }

    /// A secondary button that sits on glass.
    @ViewBuilder
    func glassButton() -> some View {
        if #available(macOS 26.0, *) {
            self.buttonStyle(.glass)
        } else {
            self.buttonStyle(.bordered)
        }
    }
}
