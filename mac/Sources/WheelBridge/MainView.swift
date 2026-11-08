import CWheelBridge
import SwiftUI
import WheelCore

enum Screen: String, CaseIterable, Identifiable {
    case wheel = "Wheel", force = "Force", bottles = "Bottles", health = "Health"
    var id: String { rawValue }
}

/// The main window: the drawing fills it, with floating glass tabs and inspector.
struct MainView: View {
    @ObservedObject var model: AppModel

    private let inspectorWidth: CGFloat = 300

    private var screen: Screen { model.screen }

    var body: some View {
        ZStack(alignment: .topLeading) {
            DrawingBackdrop()
            content
                .padding(.trailing, inspectorWidth + 12)
            tabs
                .padding(.top, 14)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.trailing, inspectorWidth + 12)
            inspector
                .frame(width: inspectorWidth)
                .frame(maxHeight: .infinity)
                .glassPanel()
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .frame(minWidth: 1000, minHeight: 680)
        .ignoresSafeArea()
    }

    private var tabs: some View {
        HStack(spacing: 2) {
            ForEach(Screen.allCases) { item in
                Button {
                    model.screen = item
                } label: {
                    Text(item.rawValue)
                        .font(.system(size: 13, weight: screen == item ? .semibold : .regular))
                        .foregroundStyle(screen == item ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                        .padding(.horizontal, 18)
                        .frame(height: 36)
                        .background(Capsule().fill(screen == item ? Color.accentColor : .clear))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(screen == item ? .isSelected : [])
            }
        }
        .padding(3)
        .glassCapsule()
    }

    @ViewBuilder
    private var content: some View {
        switch screen {
        case .wheel:
            WheelDrawing(degrees: model.steeringDegrees, rangeDegrees: model.rangeDegrees, torque: model.torque)
                .padding(.trailing, -(inspectorWidth + 12))
        case .force: ForceScreen(model: model)
        case .bottles: BottlesScreen(model: model)
        case .health: HealthScreen(model: model)
        }
    }

    @ViewBuilder
    private var inspector: some View {
        if screen == .health {
            HealthInspector(model: model)
        } else {
            WheelInspector(model: model)
        }
    }
}

/// The inspector for most screens: the checklist, live input and quick settings.
struct WheelInspector: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Checklist(links: model.chain)
            Divider()
            VStack(spacing: 10) {
                PedalRow(name: "Throttle", fraction: model.pedal(model.input.throttle))
                PedalRow(name: "Brake", fraction: model.pedal(model.input.brake))
                PedalRow(name: "Clutch", fraction: model.pedal(model.input.clutch))
            }
            Divider()
            SettingSlider(label: "Force", value: $model.strength, range: 0...100, suffix: "%")
            SettingSlider(label: "Range", value: $model.rangeDegrees, range: 40...900, step: 10, suffix: "°")
            Spacer(minLength: 0)
            StopMotorButton(model: model)
        }
        .padding(18)
    }
}

/// How the forces feel, with the live output to tune against.
struct ForceScreen: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Force").font(.system(size: 28, weight: .bold))
            TorqueTrace(samples: model.torqueHistory)
                .frame(height: 170)
                .padding(16)
                .glassPanel(cornerRadius: 18)
            HStack(spacing: 28) {
                readout("Torque", String(format: "%+.0f%%", model.torque * 100))
                readout("Clipping", String(format: "%.1f%%", Double(model.status.clip_permille) / 10))
                readout("Effects", "\(model.status.active_effects)")
            }
            SettingSlider(label: "Centering spring", value: $model.centering, range: 0...100, suffix: "%")
            Toggle("Reverse force direction", isOn: $model.reversed)
                .toggleStyle(.switch)
                .font(.system(size: 13))
            Text("Use if the wheel pulls away from center when cornering.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 44)
        .padding(.top, 84)
        .padding(.bottom, 24)
    }

    private func readout(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 13)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 19, weight: .semibold)).monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }
}

/// Installs WheelBridge into bottles. One install covers every game in a bottle.
struct BottlesScreen: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Bottles").font(.system(size: 28, weight: .bold))
            Text("Installing covers every game in the bottle.")
                .font(.system(size: 15)).foregroundStyle(.secondary)
            if let error = model.bottleError {
                Text(error).font(.system(size: 13)).foregroundStyle(.red)
            }
            if model.bottles.isEmpty {
                Text("No CrossOver bottles found.").font(.system(size: 14)).foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(model.bottles) { row in
                        BottleCard(model: model, row: row)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 44)
        .padding(.top, 84)
        .padding(.bottom, 24)
    }
}

struct BottleCard: View {
    @ObservedObject var model: AppModel
    var row: BottleRow

    private var description: String {
        switch row.state {
        case .notInstalled: return "Not installed"
        case .installed: return "Installed"
        case .needsRepair(let reason): return reason
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.bottle.name).font(.system(size: 15, weight: .semibold))
                Text(description).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            if model.isBusy(row.bottle) {
                ProgressView().controlSize(.small)
            } else {
                switch row.state {
                case .notInstalled:
                    Button("Install") { model.install(row.bottle) }.glassProminentButton()
                case .installed:
                    Button("Uninstall") { model.uninstall(row.bottle) }.glassButton()
                case .needsRepair:
                    Button("Uninstall") { model.uninstall(row.bottle) }.glassButton()
                    Button("Repair") { model.install(row.bottle) }.glassProminentButton()
                }
            }
        }
        .padding(16)
        .glassPanel(cornerRadius: 16)
    }
}

/// The checklist at full size, saying exactly what is wrong.
struct HealthScreen: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(model.headline).font(.system(size: 28, weight: .bold))
                .padding(.bottom, 40)
            Checklist(links: model.chain, large: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 88)
        .padding(.top, 112)
        .padding(.bottom, 24)
    }
}

/// What to do about the first thing that is wrong.
struct HealthInspector: View {
    @ObservedObject var model: AppModel

    private var failed: ChainLink? { model.chain.first { $0.state == .failed } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let failed {
                Text(failed.name).font(.system(size: 17, weight: .semibold))
                Text(failed.fix ?? failed.detail)
                    .font(.system(size: 13))
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("No problems").font(.system(size: 17, weight: .semibold))
            }
            Divider()
            fact("Update rate", "\(model.status.loop_hz) Hz")
            fact("Write errors", "\(model.status.hid_failures)")
            ForEach(model.bottles) { row in
                fact(row.bottle.name, row.state == .installed ? "Installed" : row.state == .notInstalled ? "Not installed" : "Needs repair")
            }
            Spacer(minLength: 0)
            Button {
                model.copyDiagnostics()
            } label: {
                Text("Copy Diagnostics").frame(maxWidth: .infinity)
            }
            .glassButton()
        }
        .padding(18)
    }

    private func fact(_ name: String, _ value: String) -> some View {
        HStack {
            Text(name).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit()
        }
        .font(.system(size: 13))
    }
}
