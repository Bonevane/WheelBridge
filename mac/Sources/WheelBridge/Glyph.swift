import AppKit
import SwiftUI

/// The WheelBridge mark: a wheel with a solid hub bar and three openings.
/// Drawn in unit coordinates, outer radius 1, and filled even-odd so the
/// openings are holes.
struct WheelGlyph: Shape {
    /// The rim's inner edge, which the openings follow.
    private static let inner: CGFloat = 0.76

    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / 2
        // The flat bottom makes the mark shorter than it is wide, so centre what is drawn.
        let centre = CGPoint(x: rect.midX, y: rect.midY + 0.07 * scale)
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: centre.x + x * scale, y: centre.y + y * scale) }
        func angle(_ x: CGFloat, _ y: CGFloat) -> Angle { .radians(atan2(Double(y), Double(x))) }
        let r = Self.inner * scale

        // The outline: a circle with its bottom cut flat, the corners rounded.
        var path = Path()
        path.move(to: p(0.588, 0.809))
        path.addArc(center: centre, radius: scale, startAngle: angle(0.588, 0.809), endAngle: angle(-0.588, 0.809), clockwise: true)
        path.addQuadCurve(to: p(-0.400, 0.860), control: p(-0.510, 0.860))
        path.addLine(to: p(0.400, 0.860))
        path.addQuadCurve(to: p(0.588, 0.809), control: p(0.510, 0.860))
        path.closeSubpath()

        // The top opening: the rim's arc above a straight bar.
        path.move(to: p(-0.700, -0.170))
        path.addQuadCurve(to: p(-0.730, -0.210), control: p(-0.745, -0.170))
        path.addArc(center: centre, radius: r, startAngle: angle(-0.730, -0.210), endAngle: angle(0.730, -0.210), clockwise: false)
        path.addQuadCurve(to: p(0.700, -0.170), control: p(0.745, -0.170))
        path.closeSubpath()

        // The two lower openings, mirrored.
        for side: CGFloat in [-1, 1] {
            path.move(to: p(side * 0.745, 0.152))
            path.addQuadCurve(to: p(side * 0.700, 0.110), control: p(side * 0.745, 0.100))
            path.addQuadCurve(to: p(side * 0.150, 0.590), control: p(side * 0.330, 0.170))
            path.addQuadCurve(to: p(side * 0.190, 0.640), control: p(side * 0.135, 0.640))
            path.addLine(to: p(side * 0.360, 0.640))
            path.addQuadCurve(to: p(side * 0.456, 0.608), control: p(side * 0.420, 0.640))
            path.addArc(center: centre, radius: r, startAngle: angle(side * 0.456, 0.608), endAngle: angle(side * 0.745, 0.152),
                        clockwise: side > 0)
            path.closeSubpath()
        }
        return path
    }

    /// The mark as a menu bar template image, so macOS colours it.
    static func templateImage(size: CGFloat = 18) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: true) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            // A point of margin, like the system's own menu bar symbols.
            context.addPath(WheelGlyph().path(in: rect.insetBy(dx: 1, dy: 1)).cgPath)
            context.setFillColor(NSColor.black.cgColor)
            context.fillPath(using: .evenOdd)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "WheelBridge"
        return image
    }
}
