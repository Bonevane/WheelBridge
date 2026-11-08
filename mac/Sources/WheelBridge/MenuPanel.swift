import SwiftUI

/// The menu bar panel: a status card, the checklist and the quick controls.
struct MenuPanel: View {
    @ObservedObject var model: AppModel
    var openWindow: () -> Void

    private var cardTint: Color {
        if model.motorStopped { return .red }
        if model.isDriving { return .green }
        return model.chain.contains { $0.state == .failed } ? .red : .gray
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.headline).font(.system(size: 17, weight: .semibold))
                Text(model.subheadline).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(2)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassPanel(cornerRadius: 16, tint: cardTint)

            Checklist(links: model.chain)
            Divider()
            SettingSlider(label: "Force", value: $model.strength, range: 0...100, suffix: "%")
            SettingSlider(label: "Range", value: $model.rangeDegrees, range: 40...900, step: 10, suffix: "°")
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
                    Text("Open Window").font(.system(size: 13)).foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, minHeight: 30)
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
