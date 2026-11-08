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
        static let crossOver = "crossOverPath"
        static let addedPrefixes = "addedPrefixes"
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
    @Published private(set) var crossOvers: [CrossOverInstall] = []
    /// The CrossOver whose dinput8 goes into bottles. Nil when none is found.
    @Published var crossOver: CrossOverInstall? {
        didSet {
            guard preview == nil, crossOver != oldValue else { return }
            defaults.set(crossOver?.url.path, forKey: Key.crossOver)
            refreshBottles()
        }
    }

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
        refreshCrossOvers()
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

    /// The game's executable, without ".exe".
    var gameName: String {
        let name = BridgeText.read(status.game_name)
        return name.lowercased().hasSuffix(".exe") ? String(name.dropLast(4)) : name
    }

    var wheelReady: Bool { status.wheel_state == WB_WHEEL_READY.rawValue }

    // MARK: The chain

    var chain: [ChainLink] { [wheelLink, helperLink, bottleLink, gameLink] }

    var isDriving: Bool { chain.allSatisfy { $0.state == .good } }

    var headline: String {
        if motorStopped { return "Motor stopped" }
        if isDriving { return "Active" }
        return chain.contains { $0.state == .failed } ? "Not working" : "Waiting for a game"
    }

    var subheadline: String {
        if motorStopped { return "Resume to send forces again" }
        if isDriving { return "Force feedback is on" }
        if let failed = chain.first(where: { $0.state == .failed }) { return "\(failed.name): \(failed.detail)" }
        return "Start a game in \(installedBottleName ?? "an installed bottle")"
    }

    private var installedBottleName: String? {
        bottles.first { $0.state == .installed }?.bottle.name
    }

    private var wheelLink: ChainLink {
        if FileManager.default.fileExists(atPath: "/Library/Extensions/LogiWheelForceFeedback.kext") {
            return ChainLink(name: "Wheel", detail: "Blocked by Logitech driver", state: .failed,
                             fix: "Remove LogiWheelForceFeedback.kext from /Library/Extensions, then restart.")
        }
        guard helperRunning else {
            return ChainLink(name: "Wheel", detail: "Waiting for helper", state: .waiting)
        }
        switch wb_wheel_state(rawValue: status.wheel_state) {
        case WB_WHEEL_READY:
            return ChainLink(name: "Wheel", detail: "\(wheelModel?.name ?? "Wheel"), USB", state: .good)
        case WB_WHEEL_UNSUPPORTED:
            return ChainLink(name: "Wheel", detail: "\(wheelModel?.name ?? "Wheel") isn't supported yet", state: .failed,
                             fix: wheelModel?.unsupportedReason ?? "This wheel isn't supported yet.")
        case WB_WHEEL_SWITCHING:
            return ChainLink(name: "Wheel", detail: "Switching to native mode", state: .waiting)
        case WB_WHEEL_OPEN_FAILED:
            return ChainLink(name: "Wheel", detail: "Access denied", state: .failed,
                             fix: "Allow WheelBridge in System Settings › Privacy & Security › Input Monitoring.")
        default:
            return ChainLink(name: "Wheel", detail: "Not connected", state: .failed,
                             fix: "Connect the wheel and its power supply.")
        }
    }

    /// The wheel the helper found, from the USB id it publishes.
    var wheelModel: WheelModel? {
        WheelModel.model(productID: Int(input.vendor_product >> 16))
    }

    /// The range the wheel allows: fixed-range wheels show their one value.
    var rangeLimits: ClosedRange<Double> {
        guard let model = wheelModel, model.isSupported else { return 40...900 }
        return Double(model.minimumRange)...Double(max(model.maximumRange, model.minimumRange + 1))
    }

    private var helperLink: ChainLink {
        guard helperRunning else {
            return ChainLink(name: "Helper", detail: "Not running", state: .failed,
                             fix: "Reopen WheelBridge.")
        }
        return ChainLink(name: "Helper", detail: "Running, \(status.loop_hz) Hz", state: .good)
    }

    private var bottleLink: ChainLink {
        if let broken = bottles.first(where: { if case .needsRepair = $0.state { return true } else { return false } }),
           case .needsRepair(let reason) = broken.state {
            return ChainLink(name: "Bottle", detail: "\(broken.bottle.name): repair needed", state: .failed,
                             fix: "\(reason) Usually caused by a CrossOver or Wine update. Repair it in Bottles.")
        }
        if let name = installedBottleName {
            return ChainLink(name: "Bottle", detail: name, state: .good)
        }
        return ChainLink(name: "Bottle", detail: "Not installed", state: .failed,
                         fix: "Install into a bottle in Bottles.")
    }

    /// A game is driving the wheel right now.
    var gameConnected: Bool { status.game_connected != 0 }

    private var gameLink: ChainLink {
        gameConnected
            ? ChainLink(name: "Game", detail: gameName, state: .good)
            : ChainLink(name: "Game", detail: "None", state: .waiting)
    }

    // MARK: Settings

    private func saveSettings() {
        // Preview data is never saved, so a preview cannot change real settings.
        guard preview == nil else { return }
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
                               proxy32: proxies.appendingPathComponent("i686/dinput8.dll"),
                               crossOverApps: crossOver.map { [$0.url] } ?? [])
    }

    /// Finds every CrossOver, and keeps the user's choice if it still exists.
    /// With no choice yet, a CrossOver that is running wins, as it is the one in use.
    func refreshCrossOvers() {
        guard preview == nil else { return }
        let found = CrossOverInstall.detected()
        var all = found
        if let current = crossOver, !all.contains(current), current.isUsable { all.append(current) }
        crossOvers = all
        if let saved = defaults.string(forKey: Key.crossOver).map({ CrossOverInstall(url: URL(fileURLWithPath: $0)) }),
           saved.isUsable {
            if !crossOvers.contains(saved) { crossOvers.append(saved) }
            crossOver = saved
            return
        }
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: "com.codeweavers.CrossOver")
            .compactMap { $0.bundleURL.map(CrossOverInstall.init) }
        crossOver = running.first { crossOvers.contains($0) } ?? crossOvers.first
    }

    /// Lets the user point at a CrossOver that isn't found on its own, such as one
    /// on an external drive.
    func chooseCrossOver() {
        let panel = NSOpenPanel()
        panel.title = "Choose CrossOver"
        panel.prompt = "Choose"
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let install = CrossOverInstall(url: url)
        guard install.isUsable else {
            bottleError = "\(url.lastPathComponent) isn't a CrossOver that WheelBridge can use."
            return
        }
        if !crossOvers.contains(install) { crossOvers.append(install) }
        crossOver = install
    }

    func refreshBottles() {
        guard preview == nil else { return }
        let installer = installer
        var seen = Set<String>()
        let all = (Bottle.all() + PrefixFinder().all() + addedPrefixes).filter { seen.insert($0.url.standardizedFileURL.path).inserted }
        let rows = all.map { BottleRow(bottle: $0, state: installer.state(of: $0)) }
        if rows != bottles { bottles = rows }
    }

    /// Prefixes the user added by hand, each with the Wine it runs on.
    private var addedPrefixes: [Bottle] {
        let saved = defaults.array(forKey: Key.addedPrefixes) as? [[String: String]] ?? []
        return saved.compactMap { entry in
            guard let path = entry["path"] else { return nil }
            let url = URL(fileURLWithPath: path)
            guard Bottle.isPrefix(url) else { return nil }
            return Bottle(url: url, source: .wine, wineLibrary: entry["wine"].map { URL(fileURLWithPath: $0) })
        }
    }

    func isAddedByHand(_ bottle: Bottle) -> Bool {
        (defaults.array(forKey: Key.addedPrefixes) as? [[String: String]] ?? []).contains { $0["path"] == bottle.url.path }
    }

    /// Adds a prefix from any other Wine: Game Porting Toolkit, a Wine app, or
    /// one that wasn't found on its own. Asks for its Wine if none is found.
    func addPrefix() {
        let panel = NSOpenPanel()
        panel.title = "Add a Wine Prefix"
        panel.message = "Choose the folder that holds drive_c."
        panel.prompt = "Add"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.showsHiddenFiles = true
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        guard Bottle.isPrefix(folder) else {
            bottleError = "\(folder.lastPathComponent) isn't a Wine prefix. Choose the folder that holds drive_c."
            return
        }
        var library = PrefixFinder.knownWineLibraries().first
        if library == nil {
            let wine = NSOpenPanel()
            wine.title = "Choose Its Wine"
            wine.message = "Choose the Wine app or folder that runs this prefix."
            wine.prompt = "Choose"
            wine.canChooseDirectories = true
            wine.treatsFilePackagesAsDirectories = false
            guard wine.runModal() == .OK, let url = wine.url else { return }
            library = PrefixFinder.findWineLibrary(in: url)
            guard library != nil else {
                bottleError = "No Wine 6 or newer found in \(url.lastPathComponent)."
                return
            }
        }
        var saved = defaults.array(forKey: Key.addedPrefixes) as? [[String: String]] ?? []
        saved.removeAll { $0["path"] == folder.path }
        var entry = ["path": folder.path]
        entry["wine"] = library?.path
        saved.append(entry)
        defaults.set(saved, forKey: Key.addedPrefixes)
        bottleError = nil
        refreshBottles()
    }

    func removeAddedPrefix(_ bottle: Bottle) {
        var saved = defaults.array(forKey: Key.addedPrefixes) as? [[String: String]] ?? []
        saved.removeAll { $0["path"] == bottle.url.path }
        defaults.set(saved, forKey: Key.addedPrefixes)
        refreshBottles()
    }

    var hasCrossOverBottles: Bool { bottles.contains { $0.bottle.source == .crossOver } || !crossOvers.isEmpty }

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
        input.vendor_product = UInt32(WheelModel.g29.productID) << 16 | UInt32(WheelModel.logitechVendorID)
        input.steering = UInt32(32768 - 34.0 / 450 * 32768)
        input.throttle = 18350
        input.brake = 53740
        input.clutch = 65535
        if let index = CommandLine.arguments.firstIndex(of: "--range"), let value = Double(CommandLine.arguments[index + 1]) {
            rangeDegrees = value
        }
        torqueHistory = (0..<240).map { sin(Double($0) / 14) * 0.45 + sin(Double($0) / 4.1) * 0.08 }
        let games = Bottle(url: Bottle.defaultRoot.appendingPathComponent("Games"))
        crossOvers = CrossOverInstall.detected()
        crossOver = crossOvers.first
        let whisky = Bottle(url: URL(fileURLWithPath: "/tmp/Steam"), source: .whisky, label: "Steam")
        let wrapper = Bottle(url: URL(fileURLWithPath: "/tmp/AC"), source: .wrapper, label: "Assetto Corsa")
        switch preview {
        case .good:
            status.game_connected = 1
            bottles = [BottleRow(bottle: games, state: .installed), BottleRow(bottle: whisky, state: .notInstalled),
                       BottleRow(bottle: wrapper, state: .notInstalled)]
        case .failure:
            status.torque_permille = 0
            bottles = [BottleRow(bottle: games, state: .needsRepair("Proxy missing."))]
        }
    }
}
