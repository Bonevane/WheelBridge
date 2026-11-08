import SwiftUI

/// The technical drawing behind every screen: centrelines and the range scale,
/// which run under the glass so it has real content to refract.
struct DrawingBackdrop: View {
    /// Where the drawing is centred, as a share of the view.
    var centre = CGPoint(x: 0.37, y: 0.56)

    var body: some View {
        Canvas { context, size in
            let middle = CGPoint(x: size.width * centre.x, y: size.height * centre.y)
            let line = GraphicsContext.Shading.style(.quaternary)
            let dashes = StrokeStyle(lineWidth: 1, dash: [14, 5, 3, 5])

            context.stroke(Path { path in
                path.move(to: CGPoint(x: middle.x, y: 0))
                path.addLine(to: CGPoint(x: middle.x, y: size.height))
                path.move(to: CGPoint(x: 0, y: middle.y))
                path.addLine(to: CGPoint(x: size.width, y: middle.y))
            }, with: line, style: dashes)

            context.stroke(circle(middle, 420), with: .style(.tertiary), style: StrokeStyle(lineWidth: 14, dash: [2, 12]))
            context.stroke(circle(middle, 520), with: .color(.accentColor.opacity(0.55)), lineWidth: 3)
        }
        .accessibilityHidden(true)
    }

    private func circle(_ centre: CGPoint, _ radius: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: centre.x - radius, y: centre.y - radius, width: radius * 2, height: radius * 2))
    }
}

/// The wheel, drawn live with callouts for its angle, range and torque.
struct WheelDrawing: View {
    var degrees: Double
    var rangeDegrees: Double
    var torque: Double

    var body: some View {
        GeometryReader { geometry in
            let middle = CGPoint(x: geometry.size.width * 0.37, y: geometry.size.height * 0.56)
            ZStack {
                Canvas { context, _ in
                    draw(in: &context, at: middle)
                }
                callout("Range", "\(Int(rangeDegrees))°", at: CGPoint(x: middle.x + 240, y: middle.y - 226))
                callout("Torque", String(format: "%+.0f%%", torque * 100), at: CGPoint(x: 44, y: middle.y + 216))
                    .frame(width: 120, alignment: .leading)
                Text(angleText)
                    .font(.system(size: 28, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Color.accentColor)
                    .position(x: middle.x - 200, y: middle.y - 236)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Wheel at \(angleText), range \(Int(rangeDegrees)) degrees")
    }

    private var angleText: String {
        let whole = Int(abs(degrees).rounded())
        if whole == 0 { return "Centred" }
        return "\(whole)° \(degrees < 0 ? "left" : "right")"
    }

    private func callout(_ title: String, _ value: String, at point: CGPoint) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 13)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 19, weight: .semibold)).monospacedDigit()
        }
        .position(x: point.x + 40, y: point.y)
    }

    private func draw(in context: inout GraphicsContext, at middle: CGPoint) {
        let ink = GraphicsContext.Shading.style(.primary)
        let ring = StrokeStyle(lineWidth: 1.5)
        func circle(_ radius: CGFloat) -> Path {
            Path(ellipseIn: CGRect(x: -radius, y: -radius, width: radius * 2, height: radius * 2))
        }

        context.stroke(Path(ellipseIn: CGRect(x: middle.x - 262, y: middle.y - 262, width: 524, height: 524)),
                       with: .style(.quaternary), style: StrokeStyle(lineWidth: 1, dash: [4, 5]))

        // The sweep from centre to the wheel's angle, along the dashed circle.
        var sweep = Path()
        let shown = max(-180, min(180, degrees))
        sweep.addArc(center: middle, radius: 262, startAngle: .degrees(-90), endAngle: .degrees(-90 + shown),
                     clockwise: shown < 0)
        context.stroke(sweep, with: .color(.accentColor), lineWidth: 2)

        var wheel = context
        wheel.translateBy(x: middle.x, y: middle.y)
        wheel.rotate(by: .degrees(degrees))
        wheel.stroke(circle(205), with: ink, style: ring)
        wheel.stroke(circle(180), with: ink, style: ring)
        wheel.stroke(circle(58), with: ink, style: ring)
        wheel.stroke(circle(12), with: ink, lineWidth: 1)
        wheel.stroke(Path { path in
            for side: CGFloat in [-1, 1] {
                for offset: CGFloat in [-20, 20] {
                    path.move(to: CGPoint(x: side * 178, y: offset))
                    path.addLine(to: CGPoint(x: side * 55, y: offset * 0.65))
                }
            }
            for offset: CGFloat in [-1, 1] {
                path.move(to: CGPoint(x: offset * 23, y: 55))
                path.addLine(to: CGPoint(x: offset * 32, y: 177))
            }
        }, with: ink, style: ring)
        wheel.fill(Path(CGRect(x: -8, y: -205, width: 16, height: 25)), with: .color(.accentColor))
    }
}

/// A rolling trace of the torque reaching the motor.
struct TorqueTrace: View {
    var samples: [Double]

    var body: some View {
        Canvas { context, size in
            let middle = size.height / 2
            context.stroke(Path { path in
                path.move(to: CGPoint(x: 0, y: middle))
                path.addLine(to: CGPoint(x: size.width, y: middle))
            }, with: .style(.quaternary), lineWidth: 1)
            guard samples.count > 1 else { return }
            let step = size.width / CGFloat(samples.count - 1)
            context.stroke(Path { path in
                for (index, sample) in samples.enumerated() {
                    let point = CGPoint(x: CGFloat(index) * step, y: middle - CGFloat(sample) * (middle - 4))
                    if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
                }
            }, with: .color(.accentColor), lineWidth: 2)
        }
        .accessibilityLabel("Live torque trace")
    }
}
