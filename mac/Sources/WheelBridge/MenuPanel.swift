import SwiftUI

/// The menu bar panel: a status card, the checklist and the quick controls.
struct MenuPanel: View {
    @ObservedObject var model: AppModel
    var openWindow: () -> Void

    private var cardTint: Color {
        if model.motorStopped { return .red }
        if model.isDriving { return .green }
        return model.chain.contains { $0.state == .failed } ? .orange : .secondary
    }

    private var cardSymbol: String {
        if model.motorStopped { return "stop.fill" }
        if model.isDriving { return "checkmark" }
        return model.chain.contains { $0.state == .failed } ? "exclamationmark" : "ellipsis"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: cardSymbol)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(cardTint))
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.headline).font(.system(size: 15, weight: .semibold))
                    Text(model.subheadline).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous).fill(cardTint.opacity(0.12))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(cardTint.opacity(0.25), lineWidth: 0.5)
            )
            .accessibilityElement(children: .combine)

            Checklist(links: model.chain)
            Divider()
            SettingSlider(label: "Force", value: $model.strength, range: 0...100, suffix: "%")
            SettingSlider(label: "Range", value: $model.rangeDegrees, range: model.rangeLimits, step: 10, suffix: "°")
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Torque").font(.system(size: 13))
                    Spacer()
                    Text(String(format: "%+.0f%%", model.torque * 100))
                        .font(.system(size: 13)).monospacedDigit().foregroundStyle(.secondary)
                }
                LevelBar(fraction: abs(model.torque))
            }
            .accessibilityElement(children: .combine)
            HStack(spacing: 8) {
                Button(action: openWindow) {
                    Text("Open WheelBridge").frame(maxWidth: .infinity)
                }
                .glassButton()
                StopMotorButton(model: model)
            }
        }
        .padding(18)
        .frame(width: 330)
        .glassPanel(cornerRadius: 26)
    }
}
