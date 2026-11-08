import AppKit
import CWheelBridge
import Foundation
import SwiftUI
import WheelCore

/// One link in the chain from the wheel to the game.
struct ChainLink: Identifiable, Equatable {
    enum State { case good, failed, waiting }

    var id: String { name }
    var name: String
    var detail: String
    var state: State
    /// What to do about it, shown on the Health screen when this link has failed.
    var fix: String?
}

struct BottleRow: Identifiable, Equatable {
    var bottle: Bottle
    var state: BottleState
    var id: String { bottle.id }
}

/// Everything the windows show. It reads from the shared block and writes only
/// settings, so nothing here can touch the motor directly.
@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    private enum Key {
        static let range = "rangeDegrees", strength = "strength", centering = "centering", reverse = "reverse"
    }

    @Published var rangeDegrees: Double { didSet { saveSettings() } }
    @Published var strength: Double { didSet { saveSettings() } }
    @Published var centering: Double { didSet { saveSettings() } }
    @Published var reversed: Bool { didSet { saveSettings() } }
    @Published var motorStopped = false { didSet { publishSettings() } }
    @Published var screen = Screen.wheel

    @Published private(set) var input = wb_input()
    @Published private(set) var status = wb_status()
    @Published private(set) var helperRunning = false
    @Published private(set) var bottles: [BottleRow] = []
    @Published private(set) var torqueHistory = [Double](repeating: 0, count: 240)
    @Published private(set) var busyBottle: String?
    @Published var bottleError: String?

    private let defaults = UserDefaults.standard
    private var bridge: SharedBridge?
    private var timer: Timer?
    private var revision: UInt32 = 0
    private var lastTick: UInt32 = 0
    private var lastTickAt = Date.distantPast
    private var cycle = 0
    private let preview: Preview?

    /// Sample data for looking at the screens with no wheel or helper.
    enum Preview: String { case good, failure }

    private init() {
        rangeDegrees = defaults.object(forKey: Key.range) as? Double ?? 900
        strength = defaults.object(forKey: Key.strength) as? Double ?? 80
        centering = defaults.object(forKey: Key.centering) as? Double ?? 0
        reversed = defaults.bool(forKey: Key.reverse)
        let arguments = CommandLine.arguments
        preview = arguments.firstIndex(of: "--preview").flatMap { index in
            arguments.indices.contains(index + 1) ? Preview(rawValue: arguments[index + 1]) : nil
        }
    }

    func start() {
        refreshBottles()
        if let preview {
            applyPreview(preview)
            return
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    // MARK: Reading

    private func tick() {
        cycle += 1
        if bridge == nil, cycle % 30 == 1 {
            bridge = try? SharedBridge(owner: false)
            if bridge != nil { publishSettings() }
        }
        guard let bridge else {
            helperRunning = false
            return
        }
        if let value = bridge.readInput() { input = value }
        if let value = bridge.readStatus() {
            status = value
            if value.tick != lastTick {
                lastTick = value.tick
                lastTickAt = Date()
            }
        }
        let running = Date().timeIntervalSince(lastTickAt) < 1
        if running != helperRunning {
            helperRunning = running
            // A new helper starts with whatever is in the block, so remind it.
            if running { publishSettings() }
        }
        torqueHistory.removeFirst()
        torqueHistory.append(torque)
        if cycle % 90 == 0 { refreshBottles() }
    }

    var torque: Double { Double(status.torque_permille) / 1000 }

    var steeringDegrees: Double {
        (Double(input.steering) / 32767.5 - 1) * rangeDegrees / 2
    }

    /// Pedals rest high, so pressing one moves it towards zero.
    func pedal(_ raw: UInt32) -> Double { 1 - Double(raw) / 65535 }

    var gameName: String { BridgeText.read(status.game_name) }

    var wheelReady: Bool { status.wheel_state == WB_WHEEL_READY.rawValue }

    // MARK: The chain

    var chain: [ChainLink] { [wheelLink, helperLink, bottleLink, gameLink] }

    var isDriving: Bool { chain.allSatisfy { $0.state == .good } }

    var headline: String {
        if motorStopped { return "Motor stopped" }
        if isDriving { return "Force feedback is on" }
        return chain.contains { $0.state == .failed } ? "Force feedback is off" : "Ready for a game"
    }

    var subheadline: String {
        if motorStopped { return "No force will reach the wheel" }
        if isDriving { return "G29 is driving \(gameName)" }
        if let failed = chain.first(where: { $0.state == .failed }) { return failed.detail }
        return "Start a game in \(installedBottleName ?? "your bottle")"
    }

    private var installedBottleName: String? {
        bottles.first { $0.state == .installed }?.bottle.name
    }

    private var wheelLink: ChainLink {
        if FileManager.default.fileExists(atPath: "/Library/Extensions/LogiWheelForceFeedback.kext") {
            return ChainLink(name: "Wheel", detail: "An old Logitech driver is claiming it", state: .failed,
                             fix: "Uninstall Logitech G HUB, remove LogiWheelForceFeedback.kext from /Library/Extensions, then restart your Mac.")
        }
        guard helperRunning else {
            return ChainLink(name: "Wheel", detail: "Waiting for the helper", state: .waiting)
        }
        switch wb_wheel_state(rawValue: status.wheel_state) {
        case WB_WHEEL_READY:
            return ChainLink(name: "Wheel", detail: "G29 over USB", state: .good)
        case WB_WHEEL_SWITCHING:
            return ChainLink(name: "Wheel", detail: "Switching to native mode", state: .waiting)
        case WB_WHEEL_OPEN_FAILED:
            return ChainLink(name: "Wheel", detail: "macOS refused access", state: .failed,
                             fix: "Allow WheelBridge in System Settings, under Privacy & Security, then Input Monitoring.")
        default:
            return ChainLink(name: "Wheel", detail: "Not connected", state: .failed,
                             fix: "Plug in the wheel and its power adapter, directly into your Mac if you can.")
        }
    }

    private var helperLink: ChainLink {
        guard helperRunning else {
            return ChainLink(name: "Helper", detail: "Not running", state: .failed,
                             fix: "Quit and reopen WheelBridge. The helper starts with it.")
        }
        return ChainLink(name: "Helper", detail: "Running at \(status.loop_hz) Hz", state: .good)
    }

    private var bottleLink: ChainLink {
        if let broken = bottles.first(where: { if case .needsRepair = $0.state { return true } else { return false } }),
           case .needsRepair(let reason) = broken.state {
            return ChainLink(name: "Bottle", detail: "\(broken.bottle.name) needs repair", state: .failed,
                             fix: "\(reason) A CrossOver update usually causes this. Repair it on the Games screen.")
        }
        if let name = installedBottleName {
            return ChainLink(name: "Bottle", detail: "\(name), proxy intact", state: .good)
        }
        return ChainLink(name: "Bottle", detail: "Not installed yet", state: .failed,
                         fix: "Install WheelBridge into a bottle on the Games screen.")
    }

    private var gameLink: ChainLink {
        status.game_connected != 0
            ? ChainLink(name: "Game", detail: gameName, state: .good)
            : ChainLink(name: "Game", detail: "No game has the wheel", state: .waiting)
    }

    // MARK: Settings

    private func saveSettings() {
        defaults.set(rangeDegrees, forKey: Key.range)
        defaults.set(strength, forKey: Key.strength)
        defaults.set(centering, forKey: Key.centering)
        defaults.set(reversed, forKey: Key.reverse)
        publishSettings()
    }

    private func publishSettings() {
        revision &+= 1
        var settings = wb_settings()
        settings.revision = max(1, revision)
        settings.range_degrees = UInt32(rangeDegrees)
        settings.strength = UInt32(strength)
        settings.centering = UInt32(centering)
        settings.reverse = reversed ? 1 : 0
        settings.motor_stopped = motorStopped ? 1 : 0
        bridge?.publish(settings: settings)
    }

    // MARK: Bottles

    private var installer: BottleInstaller {
        let proxies = Bundle.main.resourceURL?.appendingPathComponent("proxy")
            ?? URL(fileURLWithPath: "/nonexistent")
        return BottleInstaller(proxy64: proxies.appendingPathComponent("x86_64/dinput8.dll"),
                               proxy32: proxies.appendingPathComponent("i686/dinput8.dll"))
    }

    func refreshBottles() {
        guard preview == nil else { return }
        let installer = installer
        let rows = Bottle.all().map { BottleRow(bottle: $0, state: installer.state(of: $0)) }
        if rows != bottles { bottles = rows }
    }

    func install(_ bottle: Bottle) { run(on: bottle) { try $0.install(into: bottle) } }

    func uninstall(_ bottle: Bottle) { run(on: bottle) { try $0.uninstall(from: bottle) } }

    func isBusy(_ bottle: Bottle) -> Bool { busyBottle == bottle.id }

    private func run(on bottle: Bottle, _ work: @escaping @Sendable (BottleInstaller) throws -> Void) {
        guard busyBottle == nil else { return }
        busyBottle = bottle.id
        bottleError = nil
        let installer = installer
        Task.detached { [weak self] in
            var message: String?
            do {
                try work(installer)
            } catch {
                message = "\(error)"
            }
            let failure = message
            await MainActor.run {
                self?.busyBottle = nil
                self?.bottleError = failure
                self?.refreshBottles()
            }
        }
    }

    // MARK: Diagnostics

    func copyDiagnostics() {
        var lines = ["WheelBridge diagnostics", "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)"]
        lines += chain.map { "\($0.name): \($0.detail)" }
        lines.append("Loop \(status.loop_hz) Hz, \(status.hid_failures) failed reports")
        lines.append("Range \(Int(rangeDegrees)), strength \(Int(strength)), centering \(Int(centering)), reversed \(reversed)")
        lines += bottles.map { "Bottle \($0.bottle.name): \($0.state)" }
        let log = Paths.supportDirectory.appendingPathComponent("proxy.log")
        if let text = try? String(contentsOf: log, encoding: .utf8) {
            lines.append("Proxy log:")
            lines += text.components(separatedBy: "\n").suffix(30)
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }

    // MARK: Preview

    private func applyPreview(_ preview: Preview) {
        helperRunning = true
        status.wheel_state = WB_WHEEL_READY.rawValue
        status.loop_hz = 500
        status.torque_permille = 410
        BridgeText.write("F1_2021_dx12.exe", to: &status.game_name)
        input.steering = UInt32(32768 - 34.0 / 450 * 32768)
        input.throttle = 18350
        input.brake = 53740
        input.clutch = 65535
        torqueHistory = (0..<240).map { sin(Double($0) / 14) * 0.45 + sin(Double($0) / 4.1) * 0.08 }
        let games = Bottle(url: Bottle.defaultRoot.appendingPathComponent("Games"))
        switch preview {
        case .good:
            status.game_connected = 1
            bottles = [BottleRow(bottle: games, state: .installed)]
        case .failure:
            status.torque_permille = 0
            bottles = [BottleRow(bottle: games, state: .needsRepair("The proxy is missing."))]
        }
    }
}
