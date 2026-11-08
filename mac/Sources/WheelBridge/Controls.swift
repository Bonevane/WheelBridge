import SwiftUI

/// The connected checklist from wheel to game. Each node shows its state by shape
/// as well as colour, so it reads without telling colours apart.
struct Checklist: View {
    var links: [ChainLink]
    var large = false

    private var node: CGFloat { large ? 18 : 14 }
    private var rowHeight: CGFloat { large ? 84 : 48 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(links.enumerated()), id: \.element.id) { index, link in
                HStack(alignment: .top, spacing: large ? 18 : 14) {
                    VStack(spacing: 0) {
                        marker(link.state)
                        if index < links.count - 1 {
                            connector(after: link.state)
                        }
                    }
                    .frame(width: node)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(link.name)
                            .font(.system(size: large ? 18 : 14, weight: .semibold))
                            .foregroundStyle(link.state == .failed ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
                        Text(link.detail)
                            .font(.system(size: large ? 14 : 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 0)
                }
                .frame(height: index < links.count - 1 ? rowHeight : nil, alignment: .top)
                .accessibilityElement(children: .combine)
            }
        }
    }

    @ViewBuilder
    private func marker(_ state: ChainLink.State) -> some View {
        switch state {
        case .good:
            Circle().strokeBorder(Color.accentColor, lineWidth: 2).frame(width: node, height: node)
        case .failed:
            ZStack {
                Circle().fill(.red)
                Text("!").font(.system(size: node * 0.72, weight: .bold)).foregroundStyle(.white)
            }
            .frame(width: node, height: node)
        case .waiting:
            Circle().strokeBorder(.secondary, style: StrokeStyle(lineWidth: 2, dash: [3, 3]))
                .frame(width: node, height: node)
        }
    }

    @ViewBuilder
    private func connector(after state: ChainLink.State) -> some View {
        if state == .good {
            Rectangle().fill(Color.accentColor).frame(width: 2)
        } else {
            Line().stroke(.secondary, style: StrokeStyle(lineWidth: 2, dash: [4, 4])).frame(width: 2)
        }
    }

    private struct Line: Shape {
        func path(in rect: CGRect) -> Path {
            Path { path in
                path.move(to: CGPoint(x: rect.midX, y: rect.minY))
                path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
            }
        }
    }
}

/// A labelled slider with its value on the right.
struct SettingSlider: View {
    var label: String
    @Binding var value: Double
    var range: ClosedRange<Double>
    var step: Double = 1
    var suffix: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).font(.system(size: 13))
                Spacer()
                Text("\(Int(value))\(suffix)")
                    .font(.system(size: 13))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            // Stepped by rounding, not Slider's own step, which draws a tick per step.
            Slider(value: Binding(get: { value }, set: { value = ($0 / step).rounded() * step }), in: range)
                .labelsHidden()
                .accessibilityLabel(label)
        }
    }
}

/// A small horizontal level, for pedals and torque.
struct LevelBar: View {
    var fraction: Double

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(Color.accentColor)
                    .frame(width: geometry.size.width * max(0, min(1, fraction)))
            }
        }
        .frame(height: 6)
    }
}

struct PedalRow: View {
    var name: String
    var fraction: Double

    var body: some View {
        HStack(spacing: 8) {
            Text(name).font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 62, alignment: .leading)
            LevelBar(fraction: fraction)
            Text("\(Int((fraction * 100).rounded()))")
                .font(.system(size: 12)).monospacedDigit().frame(width: 30, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
    }
}

struct StopMotorButton: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Button {
            model.motorStopped.toggle()
        } label: {
            // Always clearly red and readable: this is the safety control.
            Text(model.motorStopped ? "Resume Motor" : "Stop Motor")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, minHeight: 30)
        }
        .glassButton()
        .keyboardShortcut(".", modifiers: .command)
    }
}
