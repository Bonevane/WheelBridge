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
    func glassProminentButton() -> some View {
        buttonStyle(SquircleButtonStyle(kind: .prominent))
    }

    /// A secondary button that sits on glass.
    func glassButton() -> some View {
        buttonStyle(SquircleButtonStyle(kind: .normal))
    }

    /// A button that stops something, like the motor.
    func glassDestructiveButton() -> some View {
        buttonStyle(SquircleButtonStyle(kind: .destructive))
    }
}

/// WheelBridge's buttons: a continuous-corner squircle, glass on macOS 26 and a
/// soft fill before that. Pressing shrinks the button slightly, like the system's.
struct SquircleButtonStyle: ButtonStyle {
    enum Kind { case normal, prominent, destructive }

    var kind: Kind
    @Environment(\.isEnabled) private var isEnabled

    private static let shape = RoundedRectangle(cornerRadius: 11, style: .continuous)

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: kind == .normal ? .medium : .semibold))
            .foregroundStyle(foreground)
            .lineLimit(1)
            .padding(.horizontal, 12)
            .frame(minHeight: 34)
            .contentShape(Self.shape)
            .modifier(SquircleSurface(kind: kind, pressed: configuration.isPressed))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(isEnabled ? 1 : 0.45)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }

    private var foreground: Color {
        switch kind {
        case .normal: return .primary
        case .prominent: return .white
        case .destructive: return .red
        }
    }
}

private struct SquircleSurface: ViewModifier {
    var kind: SquircleButtonStyle.Kind
    var pressed: Bool

    private let shape = RoundedRectangle(cornerRadius: 11, style: .continuous)

    private var tint: Color? {
        switch kind {
        case .normal: return nil
        case .prominent: return .accentColor
        case .destructive: return .red.opacity(0.12)
        }
    }

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            let glass = tint.map { Glass.regular.tint($0) } ?? .regular
            content
                .glassEffect(glass.interactive(), in: shape)
                .overlay(shape.strokeBorder(.white.opacity(pressed ? 0.08 : 0.16), lineWidth: 0.5))
        } else {
            content
                .background(shape.fill(fallbackFill))
                .overlay(shape.strokeBorder(Color.primary.opacity(kind == .prominent ? 0 : 0.10), lineWidth: 0.5))
                .brightness(pressed ? -0.05 : 0)
        }
    }

    private var fallbackFill: AnyShapeStyle {
        switch kind {
        case .normal: return AnyShapeStyle(.regularMaterial)
        case .prominent: return AnyShapeStyle(Color.accentColor)
        case .destructive: return AnyShapeStyle(Color.red.opacity(0.12))
        }
    }
}
