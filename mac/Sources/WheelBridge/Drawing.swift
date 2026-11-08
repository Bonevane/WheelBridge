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

/// The wheel's solid parts, rim, spokes and hub, as one shape so it can be glass.
/// Drawn at radius 205 and scaled to fit. The pieces do not overlap, so the
/// shape fills correctly whichever way each piece winds.
struct WheelShape: Shape {
    func path(in rect: CGRect) -> Path {
        let centre = CGPoint(x: rect.midX, y: rect.midY)
        let scale = min(rect.width, rect.height) / 410
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: centre.x + x * scale, y: centre.y + y * scale)
        }
        // The rim is a circle's outline, made solid, so no hole needs cutting.
        let middle = 192.5 * scale
        var path = Path(ellipseIn: CGRect(x: centre.x - middle, y: centre.y - middle, width: middle * 2, height: middle * 2))
            .strokedPath(StrokeStyle(lineWidth: 25 * scale))
        path.addEllipse(in: CGRect(x: centre.x - 58 * scale, y: centre.y - 58 * scale, width: 116 * scale, height: 116 * scale))
        for side: CGFloat in [-1, 1] {
            path.addLines([point(side * 178.5, -20), point(side * 56.5, -13), point(side * 56.5, 13), point(side * 178.5, 20)])
            path.closeSubpath()
        }
        path.addLines([point(-23, 53.5), point(23, 53.5), point(32, 177), point(-32, 177)])
        path.closeSubpath()
        return path
    }
}

/// The wheel, drawn live, inside a gauge showing its rotation range.
struct WheelDrawing: View {
    var degrees: Double
    var rangeDegrees: Double
    var torque: Double

    /// The gauge shows the G29's whole 900° on a 270° arc.
    private static let fullRange = 900.0
    private static let gaugeSweep = 270.0
    private static let gaugeRadius: CGFloat = 262

    var body: some View {
        GeometryReader { geometry in
            let middle = CGPoint(x: geometry.size.width * 0.37, y: geometry.size.height * 0.56)
            ZStack {
                Canvas { context, _ in
                    drawGauge(in: &context, at: middle)
                }
                frostedWheel
                    .frame(width: 410, height: 410)
                    .rotationEffect(.degrees(degrees))
                    .position(middle)
                Canvas { context, _ in
                    drawWheel(in: &context, at: middle)
                    drawMarker(in: &context, at: middle)
                }
                callout("Range", "\(Int(rangeDegrees))°", at: CGPoint(x: middle.x + 240, y: middle.y - 226))
                VStack(spacing: 2) {
                    Text("Torque").font(.system(size: 13)).foregroundStyle(.secondary)
                    Text(String(format: "%+.0f%%", torque * 100)).font(.system(size: 19, weight: .semibold)).monospacedDigit()
                }
                .position(x: middle.x, y: middle.y + 250)
                Text(angleText)
                    .font(.system(size: 28, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Color.accentColor)
                    .position(x: middle.x - 240, y: middle.y - 236)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Wheel \(angleText), range \(Int(rangeDegrees)) degrees")
    }

    /// Frosted material, not Liquid Glass: glass smears across the window when
    /// given a shape with holes in it, like a wheel.
    private var frostedWheel: some View {
        WheelShape()
            .fill(.ultraThinMaterial)
            .overlay(WheelShape().fill(.white.opacity(0.06)))
    }

    private var angleText: String {
        let whole = Int(abs(degrees).rounded())
        if whole == 0 { return "0°" }
        return "\(whole)° \(degrees < 0 ? "left" : "right")"
    }

    private func callout(_ title: String, _ value: String, at point: CGPoint) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 13)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 19, weight: .semibold)).monospacedDigit()
        }
        .position(x: point.x + 40, y: point.y)
    }

    /// Where a wheel angle sits on the gauge, in degrees clockwise from the top.
    private func gaugeAngle(_ wheelDegrees: Double) -> Double {
        let limit = Self.fullRange / 2
        return max(-limit, min(limit, wheelDegrees)) * Self.gaugeSweep / Self.fullRange
    }

    private func point(_ angle: Double, _ radius: CGFloat, around middle: CGPoint) -> CGPoint {
        let radians = (angle - 90) * .pi / 180
        return CGPoint(x: middle.x + radius * cos(radians), y: middle.y + radius * sin(radians))
    }

    private func arc(_ from: Double, _ to: Double, _ radius: CGFloat, around middle: CGPoint) -> Path {
        var path = Path()
        path.addArc(center: middle, radius: radius, startAngle: .degrees(from - 90), endAngle: .degrees(to - 90), clockwise: false)
        return path
    }

    private func drawGauge(in context: inout GraphicsContext, at middle: CGPoint) {
        let radius = Self.gaugeRadius
        let half = Self.gaugeSweep / 2
        let band = StrokeStyle(lineWidth: 6, lineCap: .round)
        context.stroke(arc(-half, half, radius, around: middle), with: .style(.quaternary), style: band)

        // The range the wheel is set to, between its two end stops.
        let stop = gaugeAngle(rangeDegrees / 2)
        context.stroke(arc(-stop, stop, radius, around: middle), with: .color(.accentColor.opacity(0.4)), style: band)
        for angle in [-stop, stop] {
            context.stroke(Path { path in
                path.move(to: point(angle, radius - 14, around: middle))
                path.addLine(to: point(angle, radius + 14, around: middle))
            }, with: .color(.accentColor), style: StrokeStyle(lineWidth: 3, lineCap: .round))
        }

        // A tick every quarter turn of the wheel, longer at centre.
        for turn in stride(from: -Self.fullRange / 2, through: Self.fullRange / 2, by: 90) {
            let angle = gaugeAngle(turn)
            let length: CGFloat = turn == 0 ? 14 : 7
            context.stroke(Path { path in
                path.move(to: point(angle, radius + 10, around: middle))
                path.addLine(to: point(angle, radius + 10 + length, around: middle))
            }, with: .style(.secondary), lineWidth: 1)
        }

        let label = Text("\(Int(rangeDegrees / 2))°").font(.system(size: 12)).monospacedDigit().foregroundColor(.secondary)
        context.draw(label, at: point(-stop, radius + 34, around: middle))
        context.draw(label, at: point(stop, radius + 34, around: middle))
    }

    private func drawMarker(in context: inout GraphicsContext, at middle: CGPoint) {
        let centre = point(gaugeAngle(degrees), Self.gaugeRadius, around: middle)
        let dot = Path(ellipseIn: CGRect(x: centre.x - 7, y: centre.y - 7, width: 14, height: 14))
        context.fill(dot, with: .color(.accentColor))
        context.stroke(dot, with: .color(.white), lineWidth: 2)
    }

    private func drawWheel(in context: inout GraphicsContext, at middle: CGPoint) {
        let ink = GraphicsContext.Shading.style(.primary)
        let ring = StrokeStyle(lineWidth: 1.5)
        func circle(_ radius: CGFloat) -> Path {
            Path(ellipseIn: CGRect(x: -radius, y: -radius, width: radius * 2, height: radius * 2))
        }
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
                    path.addLine(to: CGPoint(x: side * 56.5, y: offset * 0.65))
                }
            }
            for offset: CGFloat in [-1, 1] {
                path.move(to: CGPoint(x: offset * 23, y: 53.5))
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
