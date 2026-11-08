import CWheelBridge
import Foundation
import WheelCore

// Command Line Tools ship no XCTest, so these checks are a plain program.
// It exits non-zero if anything fails.

var passed = 0
var failed = 0

func check(_ condition: Bool, _ name: String, line: Int = #line) {
    if condition {
        passed += 1
    } else {
        failed += 1
        print("FAIL line \(line): \(name)")
    }
}

func near(_ a: Double, _ b: Double, _ tolerance: Double = 0.0001) -> Bool { abs(a - b) <= tolerance }

func effect(_ kind: wb_effect_kind, _ params: [Int32] = [], from direction: Int32 = 1) -> wb_effect {
    var e = wb_effect()
    e.kind = kind.rawValue
    e.playing = 1
    e.start_count = 1
    e.iterations = 1
    e.duration_us = .max
    e.gain = 10_000
    e.coords = WB_COORD_CARTESIAN
    e.axis_count = 1
    e.direction.0 = direction
    let p = params + Array(repeating: 0, count: 6 - params.count)
    e.params = (p[0], p[1], p[2], p[3], p[4], p[5])
    return e
}

func game(_ effects: [wb_effect] = [], tick: UInt32 = 1, owner: UInt32 = 42, gain: UInt32 = 10_000, flags: UInt32 = 0) -> wb_game {
    var g = wb_game()
    g.tick = tick
    g.owner_pid = owner
    g.gain = gain
    g.flags = flags
    withUnsafeMutableBytes(of: &g.effects) { bytes in
        let slots = bytes.bindMemory(to: wb_effect.self)
        for (index, e) in effects.enumerated() { slots[index] = e }
    }
    return g
}

let centre: UInt32 = 32768
let stopReport: [UInt8] = [0xf3, 0, 0, 0, 0, 0, 0]

// MARK: Protocol bytes

do {
    let driver = LogitechClassicDriver()
    check(driver.torque(0) == [0x11, 0, 0x80, 0x80, 0x80, 0x80, 0], "zero torque is the neutral code")
    check(driver.torque(1)[2] == 0xff, "full right")
    check(driver.torque(-1)[2] == 0x01, "full left")
    check(driver.torque(5)[2] == 0xff, "torque clamps high")
    check(driver.torque(.nan)[2] == 0x80, "NaN torque is neutral")
    check(driver.range(degrees: 900) == [0xf8, 0x81, 0x84, 0x03, 0, 0, 0], "900 degrees")
    check(driver.range(degrees: 5)[2] == 40, "range clamps to the minimum")
    check(driver.stop() == stopReport, "stop")
    check(driver.start(rangeDegrees: 540).first == stopReport, "start releases the motor first")
    for report in driver.start(rangeDegrees: 900) + [driver.torque(0.3)] {
        check(report.count == LogitechClassicDriver.reportLength, "reports are seven bytes")
    }

    // Which wheel arrived, from its USB id and firmware version.
    func switchTarget(_ product: Int, _ version: Int) -> (WheelModel, [OutputReport])? {
        if case .switchMode(let model, let reports) = WheelArrival.identify(productID: product, version: version) { return (model, reports) }
        return nil
    }
    check(WheelArrival.identify(productID: 0xc24f, version: 0) == .ready(.g29), "a native G29 is ready")
    check(switchTarget(0xc294, 0x1350)?.0 == .g29, "a G29 in compatibility mode")
    check(switchTarget(0xc294, 0x1350)?.1.last == OutputReport([0xf8, 0x09, 0x05, 0x01, 0x01, 0, 0]), "the G29 switch")
    check(switchTarget(0xc294, 0x8901)?.0 == .g29, "a later G29 firmware")
    check(switchTarget(0xc294, 0x1234)?.0 == .g27, "a G27 in compatibility mode")
    check(switchTarget(0xc294, 0x1300)?.0 == .drivingForceGT, "a Driving Force GT")
    check(switchTarget(0xc294, 0x1200)?.1 == [OutputReport([0xf8, 0x10, 0, 0, 0, 0, 0])], "a G25 uses its own switch")
    check(switchTarget(0xc294, 0x1000)?.1 == [OutputReport([0xf8, 0x01, 0, 0, 0, 0, 0])], "a Driving Force Pro uses its own switch")
    check(WheelArrival.identify(productID: 0xc294, version: 0x0300) == .ready(.drivingForce), "a genuine Driving Force stays")
    check(switchTarget(0xc267, 0)?.0 == .g923PlayStation, "a G923 in PlayStation mode")
    check(switchTarget(0xc267, 0)?.1.first?.id == 0x30, "the G923 switch uses report 0x30")
    check(WheelArrival.identify(productID: 0xc262, version: 0) == .unsupported(.g920), "a G920 is named but not driven")
    check(WheelArrival.identify(productID: 0x1234, version: 0) == .unknown, "other devices are ignored")

    // Range commands differ by wheel.
    let dfp = LogitechClassicDriver(model: .drivingForcePro)
    check(dfp.rangeReports(degrees: 900) == [[0xf8, 0x03, 0, 0, 0, 0, 0], [0x81, 0x0b, 0, 0, 0, 0, 0]], "DFP at 900 has no fine limit")
    check(dfp.rangeReports(degrees: 200).first == [0xf8, 0x02, 0, 0, 0, 0, 0], "DFP at 200 uses the small coarse limit")
    let fine = dfp.rangeReports(degrees: 540)
    check(fine.count == 2 && fine[1][0] == 0x81 && fine[1][4] == 0xff, "DFP at 540 adds a fine limit")
    check(LogitechClassicDriver(model: .momoRacing).rangeReports(degrees: 540).isEmpty, "a MOMO's range is fixed")
    check(LogitechClassicDriver(model: .g27).range(degrees: 1080) == [0xf8, 0x81, 0x84, 0x03, 0, 0, 0], "a G27 clamps at 900")
}

// MARK: Effects

do {
    let still = WheelMotion()
    // A force from the right pushes the wheel left.
    check(near(EffectEngineProbe.force(effect(WB_EFFECT_CONSTANT, [5000], from: 1), 0, still), -5000), "constant from the right")
    check(near(EffectEngineProbe.force(effect(WB_EFFECT_CONSTANT, [5000], from: -1), 0, still), 5000), "constant from the left")

    var polar = effect(WB_EFFECT_CONSTANT, [10_000])
    polar.coords = WB_COORD_POLAR
    polar.axis_count = 2
    polar.direction.0 = 9000 // east
    check(near(EffectEngineProbe.force(polar, 0, still), -10_000), "polar from the east")
    polar.direction.0 = 0 // north: nothing along the wheel
    check(near(EffectEngineProbe.force(polar, 0, still), 0, 0.01), "polar from the north")

    var ramp = effect(WB_EFFECT_RAMP, [0, 10_000])
    ramp.duration_us = 1_000_000
    check(near(EffectEngineProbe.force(ramp, 0.5, still), -5000), "ramp halfway")
    check(EffectEngineProbe.force(ramp, 1.5, still) == 0, "an effect ends after its duration")

    let sine = effect(WB_EFFECT_SINE, [10_000, 0, 0, 1_000_000])
    check(near(EffectEngineProbe.force(sine, 0.25, still), -10_000), "sine at a quarter cycle")
    let square = effect(WB_EFFECT_SQUARE, [4000, 0, 0, 1_000_000])
    check(near(EffectEngineProbe.force(square, 0.75, still), 4000), "square in its second half")

    var enveloped = effect(WB_EFFECT_CONSTANT, [10_000])
    enveloped.has_envelope = 1
    enveloped.attack_level = 0
    enveloped.attack_time_us = 1_000_000
    check(near(EffectEngineProbe.force(enveloped, 0.5, still), -5000), "attack envelope")

    var delayed = effect(WB_EFFECT_CONSTANT, [10_000])
    delayed.start_delay_us = 1_000_000
    var engine = EffectEngine()
    check(engine.torque(effects: [delayed], motion: still, now: 10) == 0, "a start delay holds the effect back")
    check(near(engine.torque(effects: [delayed], motion: still, now: 11.1), -1), "the effect plays after its delay")

    let spring = effect(WB_EFFECT_SPRING, [0, 10_000, 10_000])
    check(near(EffectEngineProbe.force(spring, 0, WheelMotion(position: 0.5)), -5000), "a spring pulls back from the right")
    check(near(EffectEngineProbe.force(spring, 0, WheelMotion(position: -0.5)), 5000), "a spring pulls back from the left")

    let limited = effect(WB_EFFECT_SPRING, [0, 10_000, 10_000, 2000, 2000])
    check(near(EffectEngineProbe.force(limited, 0, WheelMotion(position: 0.9)), -2000), "saturation limits a spring")

    let dead = effect(WB_EFFECT_SPRING, [0, 10_000, 10_000, 0, 0, 2000])
    check(EffectEngineProbe.force(dead, 0, WheelMotion(position: 0.1)) == 0, "dead band")

    let damper = effect(WB_EFFECT_DAMPER, [0, 10_000, 10_000])
    check(EffectEngineProbe.force(damper, 0, WheelMotion(velocity: 1)) < 0, "a damper resists motion")
    let friction = effect(WB_EFFECT_FRICTION, [0, 5000, 5000])
    check(EffectEngineProbe.force(friction, 0, WheelMotion(velocity: -1)) > 0, "friction resists motion")

    var halfGain = effect(WB_EFFECT_CONSTANT, [10_000])
    halfGain.gain = 5000
    check(near(EffectEngineProbe.force(halfGain, 0, still), -5000), "effect gain")

    var restart = EffectEngine()
    var timed = effect(WB_EFFECT_CONSTANT, [10_000])
    timed.duration_us = 1_000_000
    _ = restart.torque(effects: [timed], motion: still, now: 0)
    check(restart.torque(effects: [timed], motion: still, now: 2) == 0, "it ends")
    timed.start_count = 2
    check(near(restart.torque(effects: [timed], motion: still, now: 2), -1), "a new Start plays it again")

    let limiter = TorqueLimiter()
    check(limiter.output(torque: 9, strength: 1, reversed: false) == 1, "torque clamps")
    check(near(limiter.output(torque: 1, strength: 0.5, reversed: true), -0.5), "strength and reverse")
    check(limiter.output(torque: .infinity, strength: 1, reversed: false) == 0, "non-finite torque is zero")
}

// MARK: Motor safety

do {
    let settings = MotorSettings()
    var motor = MotorController(driver: LogitechClassicDriver())
    let force = effect(WB_EFFECT_CONSTANT, [10_000])

    var step = motor.step(steering: centre, game: nil, settings: settings, now: 0)
    check(step.reports.first == stopReport, "bring-up starts by releasing the motor")
    check(step.torque == 0, "no game means no force")

    step = motor.step(steering: centre, game: game([force], tick: 1), settings: settings, now: 1)
    check(step.gameConnected, "a ticking game is live")
    check(near(step.torque, -0.8), "default strength applies")
    check(step.reports.count == 1 && step.reports[0][0] == 0x11, "force is sent")

    step = motor.step(steering: centre, game: game([force], tick: 2), settings: settings, now: 1.002)
    check(step.reports.isEmpty, "an unchanged force is not resent")

    // The game stops polling, with the force still marked as playing.
    step = motor.step(steering: centre, game: game([force], tick: 2), settings: settings, now: 1.4)
    check(step.gameConnected, "a short gap is tolerated")
    step = motor.step(steering: centre, game: game([force], tick: 2), settings: settings, now: 1.6)
    check(!step.gameConnected, "a stalled game is dropped")
    check(step.reports == [stopReport], "a stalled game releases the motor")
    step = motor.step(steering: centre, game: game([force], tick: 2), settings: settings, now: 1.7)
    check(step.reports.isEmpty, "the release is sent once")

    step = motor.step(steering: centre, game: game([force], tick: 3), settings: settings, now: 2)
    check(step.gameConnected && !step.reports.isEmpty, "force returns when the game does")

    var stopped = settings
    stopped.motorStopped = true
    step = motor.step(steering: centre, game: game([force], tick: 4), settings: stopped, now: 2.01)
    check(step.torque == 0 && step.reports == [stopReport], "Stop Motor wins over a running game")

    step = motor.step(steering: centre, game: game([force], tick: 5), settings: settings, now: 2.02)
    step = motor.step(steering: centre, game: game([force], tick: 6, flags: WB_GAME_PAUSED), settings: settings, now: 2.03)
    check(step.torque == 0, "a paused game has no force")
    step = motor.step(steering: centre, game: game([force], tick: 7, flags: WB_GAME_ACTUATORS_OFF), settings: settings, now: 2.04)
    check(step.torque == 0, "actuators off has no force")

    step = motor.step(steering: centre, game: game([force], tick: 8, owner: 0), settings: settings, now: 2.05)
    check(!step.gameConnected && step.torque == 0, "a released wheel has no force")

    step = motor.step(steering: centre, game: game([force], tick: 9, gain: 5000), settings: settings, now: 2.06)
    check(near(step.torque, -0.4), "device gain applies")

    var narrow = settings
    narrow.rangeDegrees = 360
    step = motor.step(steering: centre, game: nil, settings: narrow, now: 2.07)
    check(step.reports.contains(LogitechClassicDriver().range(degrees: 360)), "a range change is sent")

    motor.wheelReconnected()
    step = motor.step(steering: centre, game: nil, settings: narrow, now: 3)
    check(step.reports.count == 3, "a replugged wheel is brought up again")

    var centring = settings
    centring.centering = 0.5
    centring.strength = 1
    var spring = MotorController(driver: LogitechClassicDriver())
    step = spring.step(steering: 65535, game: game(tick: 1, flags: WB_GAME_AUTOCENTER), settings: centring, now: 1)
    check(near(step.torque, -0.5, 0.001), "the centring spring pulls back")

    var fresh = wb_settings()
    check(MotorSettings(fresh) == MotorSettings(), "unwritten settings keep the defaults")
    fresh.revision = 1
    fresh.range_degrees = 540
    fresh.strength = 25
    fresh.reverse = 1
    let parsed = MotorSettings(fresh)
    check(parsed.rangeDegrees == 540 && near(parsed.strength, 0.25) && parsed.reversed, "settings parse")
}

// MARK: Input mapping

do {
    var snapshot = WheelSnapshot()
    WheelInputMap.apply(page: 1, usage: 0x30, raw: 65535, minimum: 0, maximum: 65535, to: &snapshot)
    check(snapshot.steering == 65535, "steering")
    WheelInputMap.apply(page: 1, usage: 0x32, raw: 0, minimum: 0, maximum: 255, to: &snapshot)
    check(snapshot.throttle == 0, "throttle is Z")
    WheelInputMap.apply(page: 1, usage: 0x35, raw: 128, minimum: 0, maximum: 255, to: &snapshot)
    check(snapshot.brake == 32896, "brake is Rz")
    WheelInputMap.apply(page: 1, usage: 0x31, raw: 255, minimum: 0, maximum: 255, to: &snapshot)
    check(snapshot.clutch == 65535, "clutch is Y")
    WheelInputMap.apply(page: 9, usage: 3, raw: 1, minimum: 0, maximum: 1, to: &snapshot)
    check(snapshot.buttons == 4, "button three")
    WheelInputMap.apply(page: 9, usage: 3, raw: 0, minimum: 0, maximum: 1, to: &snapshot)
    check(snapshot.buttons == 0, "button released")
    WheelInputMap.apply(page: 1, usage: 0x39, raw: 2, minimum: 0, maximum: 7, to: &snapshot)
    check(snapshot.hat == 2, "hat east")
    WheelInputMap.apply(page: 1, usage: 0x39, raw: 8, minimum: 0, maximum: 7, to: &snapshot)
    check(snapshot.hat == WB_HAT_CENTRED, "a hat out of range is centred")
}

// MARK: Shared memory

do {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("wb-check-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("bridge.bin")
    let helper = try SharedBridge(url: url, owner: true)
    let app = try SharedBridge(url: url, owner: false)

    var input = wb_input()
    input.steering = 123
    BridgeText.write("Logitech G29", to: &input.name)
    helper.publish(input: input)
    let read = app.readInput()
    check(read?.steering == 123, "input crosses the mapping")
    check(read.map { BridgeText.read($0.name) } == "Logitech G29", "names cross the mapping")
    check((read?.seq ?? 1) % 2 == 0, "a finished write leaves the sequence even")

    var settings = wb_settings()
    settings.revision = 1
    settings.range_degrees = 720
    app.publish(settings: settings)
    check(helper.readSettings()?.range_degrees == 720, "settings cross the mapping")

    try Data(repeating: 0, count: Int(WB_FILE_SIZE)).write(to: url)
    do {
        _ = try SharedBridge(url: url, owner: false)
        check(false, "a blank file is refused")
    } catch {
        check(true, "a blank file is refused")
    }
} catch {
    check(false, "shared memory threw \(error)")
}

// MARK: Registry

do {
    let section = #"[Software\\Wine\\DllOverrides]"#
    let text = "WINE REGISTRY Version 2\n\n\(section) 1790706331\n#time=1dd\n\"amstream\"=\"native, builtin\"\n\"dinput8\"=\"builtin,native\"\n\"dnet\"=\"native\"\n\n[Other] 1\n\"dinput8\"=\"keep\"\n"
    check(RegistryText.value(in: text, section: section, key: "dinput8") == "builtin,native", "reads the override")
    let changed = RegistryText.setting(in: text, section: section, key: "dinput8", to: "native,builtin")
    check(RegistryText.value(in: changed, section: section, key: "dinput8") == "native,builtin", "writes the override")
    check(changed.contains("\"dinput8\"=\"keep\""), "other sections are untouched")
    let restored = RegistryText.setting(in: changed, section: section, key: "dinput8", to: "builtin,native")
    check(restored == text, "restoring gives back the same bytes")
    let added = RegistryText.setting(in: "x\n\n\(section) 1\n#time=1\n\n", section: section, key: "dinput8", to: "n")
    check(RegistryText.value(in: added, section: section, key: "dinput8") == "n", "adds to an empty section")
    let removed = RegistryText.setting(in: added, section: section, key: "dinput8", to: nil)
    check(removed == "x\n\n\(section) 1\n#time=1\n\n", "removing gives back the same bytes")
    let created = RegistryText.setting(in: "x\n", section: section, key: "dinput8", to: "n")
    check(RegistryText.value(in: created, section: section, key: "dinput8") == "n", "creates a missing section")
}

// MARK: Installer

/// A synthetic bottle and CrossOver, shaped like the real ones.
func makeFixture(_ root: URL) throws -> (BottleInstaller, Bottle) {
    let fm = FileManager.default
    let bottle = Bottle(url: root.appendingPathComponent("Bottles/Test"))
    for folder in ["drive_c/windows/system32", "drive_c/windows/syswow64", "dosdevices"] {
        try fm.createDirectory(at: bottle.url.appendingPathComponent(folder), withIntermediateDirectories: true)
    }
    try fm.createSymbolicLink(atPath: bottle.url.appendingPathComponent("dosdevices/z:").path, withDestinationPath: "/")
    try Data("cx".utf8).write(to: bottle.url.appendingPathComponent("cxbottle.conf"))
    try Data("x\n\n[Software\\\\Wine\\\\DllOverrides] 1\n\"dinput8\"=\"builtin,native\"\n\n".utf8).write(to: bottle.userRegistry)

    func builtin(_ tag: String) -> Data {
        var data = Data(repeating: 0, count: 64)
        data.append(Data("Wine builtin DLL".utf8))
        data.append(Data(tag.utf8))
        return data
    }
    let app = root.appendingPathComponent("CrossOver.app")
    for arch in ["x86_64-windows", "i386-windows"] {
        let folder = app.appendingPathComponent("Contents/SharedSupport/CrossOver/lib/wine/\(arch)")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try builtin(arch).write(to: folder.appendingPathComponent("dinput8.dll"))
    }
    try Data("placeholder64".utf8).write(to: bottle.url.appendingPathComponent("drive_c/windows/system32/dinput8.dll"))
    try Data("placeholder32".utf8).write(to: bottle.url.appendingPathComponent("drive_c/windows/syswow64/dinput8.dll"))

    let proxy64 = root.appendingPathComponent("proxy64.dll"), proxy32 = root.appendingPathComponent("proxy32.dll")
    try Data("proxy64".utf8).write(to: proxy64)
    try Data("proxy32".utf8).write(to: proxy32)
    var installer = BottleInstaller(proxy64: proxy64, proxy32: proxy32, crossOverApps: [app],
                                    bridgeFile: URL(fileURLWithPath: "/Users/me/Library/Application Support/WheelBridge/bridge.bin"))
    installer.isWineRunning = { _ in false }
    return (installer, bottle)
}

func tree(_ root: URL) -> [String: Data] {
    var result: [String: Data] = [:]
    guard let items = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return result }
    for case let item as URL in items {
        if let data = try? Data(contentsOf: item), !item.hasDirectoryPath {
            result[item.path] = data
        }
    }
    return result
}

do {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("wb-install-\(UUID().uuidString)").resolvingSymlinksInPath()
    defer { try? FileManager.default.removeItem(at: root) }
    let (installer, bottle) = try makeFixture(root)
    let sys32 = bottle.url.appendingPathComponent("drive_c/windows/system32")
    let wow = bottle.url.appendingPathComponent("drive_c/windows/syswow64")

    let before = tree(bottle.url)
    check(installer.state(of: bottle) == .notInstalled, "starts uninstalled")

    try installer.install(into: bottle)
    check(installer.state(of: bottle) == .installed, "installs")
    check(try Data(contentsOf: sys32.appendingPathComponent("dinput8.dll")) == Data("proxy64".utf8), "64-bit proxy placed")
    check(try Data(contentsOf: wow.appendingPathComponent("dinput8.dll")) == Data("proxy32".utf8), "32-bit proxy placed")
    let real = try Data(contentsOf: sys32.appendingPathComponent("wheelbridge_dinput8_real.dll"))
    check(String(decoding: real, as: UTF8.self).contains("x86_64-windows"), "the real DLL matches the architecture")
    let realWow = try Data(contentsOf: wow.appendingPathComponent("wheelbridge_dinput8_real.dll"))
    check(String(decoding: realWow, as: UTF8.self).contains("i386-windows"), "the 32-bit real DLL matches too")
    let ini = try String(contentsOf: sys32.appendingPathComponent("wheelbridge.ini"), encoding: .utf8)
    check(ini == "Z:\\Users\\me\\Library\\Application Support\\WheelBridge\\bridge.bin\r\n", "config has the Windows path")
    let registry = try String(contentsOf: bottle.userRegistry, encoding: .utf8)
    check(registry.contains("\"dinput8\"=\"native,builtin\""), "the whole bottle loads the proxy")

    // A CrossOver update puts its placeholder back.
    try Data("placeholder64-new".utf8).write(to: sys32.appendingPathComponent("dinput8.dll"))
    if case .needsRepair = installer.state(of: bottle) { check(true, "damage is noticed") } else { check(false, "damage is noticed") }
    try installer.install(into: bottle)
    check(installer.state(of: bottle) == .installed, "repair works")
    check(try Data(contentsOf: sys32.appendingPathComponent("dinput8.wheelbridge-original.dll")) == Data("placeholder64".utf8),
          "repair keeps the original backup")

    try installer.install(into: bottle)
    check(try Data(contentsOf: sys32.appendingPathComponent("dinput8.wheelbridge-original.dll")) == Data("placeholder64".utf8),
          "a reinstall never backs up our own proxy")

    // Switching to another CrossOver, or updating it, changes the builtin.
    let other = root.appendingPathComponent("CrossOver CX.app")
    for arch in ["x86_64-windows", "i386-windows"] {
        let folder = other.appendingPathComponent("Contents/SharedSupport/CrossOver/lib/wine/\(arch)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var data = Data(repeating: 0, count: 64)
        data.append(Data("Wine builtin DLL newer \(arch)".utf8))
        try data.write(to: folder.appendingPathComponent("dinput8.dll"))
    }
    var switched = installer
    switched.crossOverApps = [other]
    check(switched.state(of: bottle) == .needsRepair("Made for a different CrossOver version."), "a different CrossOver is noticed")
    try switched.install(into: bottle)
    check(switched.state(of: bottle) == .installed, "repair takes the chosen CrossOver's dinput8")
    let manifest = try String(contentsOf: bottle.url.appendingPathComponent("wheelbridge-install.json"), encoding: .utf8)
    check(manifest.contains("CrossOver CX.app"), "the manifest records which CrossOver")
    check(manifest.contains("builtin,native"), "the manifest keeps the original override")
    try installer.install(into: bottle)
    check(installer.state(of: bottle) == .installed, "switching back works")

    try installer.uninstall(from: bottle)
    check(tree(bottle.url) == before, "uninstall restores every byte")
    check(installer.state(of: bottle) == .notInstalled, "uninstalled")

    var running = installer
    running.isWineRunning = { _ in true }
    do {
        try running.install(into: bottle)
        check(false, "refuses while Wine runs")
    } catch {
        check(error as? BottleInstaller.Failure == .wineRunning, "refuses while Wine runs")
    }
    check(tree(bottle.url) == before, "a refused install changes nothing")

    var noBuiltin = installer
    noBuiltin.crossOverApps = []
    do {
        try noBuiltin.install(into: bottle)
        check(false, "refuses with no builtin")
    } catch {
        check(tree(bottle.url) == before, "a failed check changes nothing")
    }

    // The only DLL on offer is a placeholder of the same name.
    let fake = root.appendingPathComponent("Fake.app")
    for arch in ["x86_64-windows", "i386-windows"] {
        let folder = fake.appendingPathComponent("Contents/SharedSupport/CrossOver/lib/wine/\(arch)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("not a builtin".utf8).write(to: folder.appendingPathComponent("dinput8.dll"))
    }
    var placeholder = installer
    placeholder.crossOverApps = [fake]
    do {
        try placeholder.install(into: bottle)
        check(false, "a placeholder is not a builtin")
    } catch {
        check(true, "a placeholder is not a builtin")
    }
} catch {
    check(false, "installer threw \(error)")
}

// MARK: Other Wine tools

do {
    let fm = FileManager.default
    let unresolved = fm.temporaryDirectory.appendingPathComponent("wb-home-\(UUID().uuidString)")
    try fm.createDirectory(at: unresolved, withIntermediateDirectories: true)
    let home = unresolved.resolvingSymlinksInPath()
    defer { try? fm.removeItem(at: home) }

    func makePrefix(_ url: URL) throws {
        for folder in ["drive_c/windows/system32", "dosdevices"] {
            try fm.createDirectory(at: url.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        try fm.createSymbolicLink(atPath: url.appendingPathComponent("dosdevices/z:").path, withDestinationPath: "/")
        try Data("x\n".utf8).write(to: url.appendingPathComponent("system.reg"))
        try Data("x\n\n".utf8).write(to: url.appendingPathComponent("user.reg"))
        try Data("placeholder".utf8).write(to: url.appendingPathComponent("drive_c/windows/system32/dinput8.dll"))
    }
    func makeWine(_ library: URL, tag: String) throws {
        let folder = library.appendingPathComponent("x86_64-windows")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        var data = Data(repeating: 0, count: 64)
        data.append(Data("Wine builtin DLL \(tag)".utf8))
        try data.write(to: folder.appendingPathComponent("dinput8.dll"))
    }

    // Whisky: a bottle in its container, with its Wine in Application Support.
    let whiskyBottle = home.appendingPathComponent("Library/Containers/com.isaacmarovitz.Whisky/Bottles/1234-ABCD")
    try makePrefix(whiskyBottle)
    try (["info": ["name": "Steam"]] as NSDictionary).write(to: whiskyBottle.appendingPathComponent("Metadata.plist"))
    let whiskyWine = home.appendingPathComponent("Library/Application Support/com.isaacmarovitz.Whisky/Libraries/Wine/lib/wine")
    try makeWine(whiskyWine, tag: "whisky")

    // Sikarugir: one app per game, prefix and Wine inside.
    let wrapper = home.appendingPathComponent("Applications/Sikarugir/Assetto Corsa.app/Contents")
    try makePrefix(wrapper.appendingPathComponent("SharedSupport/prefix"))
    try makeWine(wrapper.appendingPathComponent("SharedSupport/wine/lib/wine"), tag: "sikarugir")

    // Heroic: a settings file naming the prefix and the Wine binary.
    let heroicPrefix = home.appendingPathComponent("Games/Heroic/Prefixes/default/BeamNG")
    try makePrefix(heroicPrefix)
    let heroicWine = home.appendingPathComponent("Library/Application Support/heroic/tools/wine/Wine-10")
    try makeWine(heroicWine.appendingPathComponent("lib/wine"), tag: "heroic")
    let configs = home.appendingPathComponent("Library/Application Support/heroic/GamesConfig")
    try fm.createDirectory(at: configs, withIntermediateDirectories: true)
    let settings: [String: Any] = ["beamng": ["winePrefix": heroicPrefix.path,
                                              "wineVersion": ["bin": heroicWine.appendingPathComponent("bin/wine").path, "type": "wine"]]]
    try JSONSerialization.data(withJSONObject: settings).write(to: configs.appendingPathComponent("beamng.json"))
    // A game Heroic runs in a CrossOver bottle belongs to the CrossOver list.
    let crossOverGame: [String: Any] = ["acc": ["winePrefix": whiskyBottle.path, "wineVersion": ["type": "crossover"]]]
    try JSONSerialization.data(withJSONObject: crossOverGame).write(to: configs.appendingPathComponent("acc.json"))

    // ~/.wine with no Wine app installed.
    try makePrefix(home.appendingPathComponent(".wine"))

    let found = PrefixFinder(home: home).all()
    let whisky = found.first { $0.source == .whisky }
    check(whisky?.name == "Steam", "finds a Whisky bottle by its name")
    func same(_ a: URL?, _ b: URL) -> Bool { a?.resolvingSymlinksInPath().path == b.resolvingSymlinksInPath().path }
    check(same(whisky?.wineLibrary, whiskyWine), "finds Whisky's Wine")
    let sikarugir = found.first { $0.source == .wrapper }
    check(sikarugir?.name == "Assetto Corsa", "finds a Sikarugir wrapper")
    check(sikarugir?.wineLibrary?.path.hasSuffix("SharedSupport/wine/lib/wine") == true, "uses the wrapper's own Wine")
    let heroic = found.first { $0.source == .heroic }
    check(heroic?.name == "BeamNG", "finds a Heroic prefix")
    check(same(heroic?.wineLibrary, heroicWine.appendingPathComponent("lib/wine")), "uses the Wine Heroic names")
    check(found.filter { $0.source == .heroic }.count == 1, "leaves Heroic's CrossOver games to CrossOver")
    check(found.contains { $0.source == .wine && $0.name == ".wine" }, "finds ~/.wine")
    check(found.count == 4, "finds each prefix once")

    // Installing uses the prefix's own Wine, not CrossOver.
    if let sikarugir {
        let proxy = home.appendingPathComponent("proxy64.dll")
        try Data("proxy64".utf8).write(to: proxy)
        var installer = BottleInstaller(proxy64: proxy, proxy32: proxy, crossOverApps: [], bridgeFile: home.appendingPathComponent("bridge.bin"))
        installer.isWineRunning = { _ in false }
        try installer.install(into: sikarugir)
        check(installer.state(of: sikarugir) == .installed, "installs into a wrapper")
        let real = try Data(contentsOf: sikarugir.url.appendingPathComponent("drive_c/windows/system32/wheelbridge_dinput8_real.dll"))
        check(String(decoding: real, as: UTF8.self).contains("sikarugir"), "forwards to the wrapper's Wine")
        try installer.uninstall(from: sikarugir)
        check(installer.state(of: sikarugir) == .notInstalled, "uninstalls from a wrapper")
    }
} catch {
    check(false, "prefix finder threw \(error)")
}

print("\(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
