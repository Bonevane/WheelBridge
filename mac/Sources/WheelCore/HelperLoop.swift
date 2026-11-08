import CWheelBridge
import Darwin
import Foundation

/// The helper's main loop: reads the wheel and the game, runs the motor rules,
/// and publishes what happened.
public final class HelperLoop: @unchecked Sendable {
    public static let targetHz = 500.0

    private let port: WheelPort
    private let bridge: SharedBridge
    private var motor = MotorController(driver: LogitechClassicDriver())
    private var tick: UInt32 = 0
    private var generation = -1
    private var lastGame: wb_game?
    private var lastSettings = wb_settings()
    private var hidFailures: UInt32 = 0
    private var clipWindow = ClipMeter()
    private var rate = RateMeter()
    private let running = Atomic(true)

    public init(port: WheelPort, bridge: SharedBridge) {
        self.port = port
        self.bridge = bridge
    }

    /// Runs until `stop()`, then releases the motor.
    public func run() {
        // Whatever a previous run left behind must not move the motor.
        bridge.resetGame()
        for report in motor.shutdownReports() { _ = port.send(report) }

        let interval = 1 / Self.targetHz
        var next = Self.now()
        while running.value {
            cycle(now: Self.now())
            next += interval
            let wait = next - Self.now()
            if wait > 0 {
                var time = timespec(tv_sec: 0, tv_nsec: Int(wait * 1_000_000_000))
                nanosleep(&time, nil)
            } else {
                next = Self.now() // running late: do not try to catch up
            }
        }
        for report in motor.shutdownReports() { _ = port.send(report) }
    }

    public func stop() { running.value = false }

    private func cycle(now: Double) {
        let wheel = port.snapshot()
        if wheel.generation != generation {
            generation = wheel.generation
            motor.wheelReconnected(driver: wheel.model.map { LogitechClassicDriver(model: $0) })
        }
        publishInput(wheel)

        var step = MotorController.Step()
        if wheel.state == WB_WHEEL_READY {
            // A busy block is not a missing game: reads lose to a writer now and
            // then, and dropping force for that would feel like random dropouts.
            // The stale tick is what detects a game that has really gone.
            lastGame = bridge.readGame() ?? lastGame
            lastSettings = bridge.readSettings() ?? lastSettings
            step = motor.step(steering: wheel.steering, game: lastGame, settings: MotorSettings(lastSettings), now: now)
            for report in step.reports where !port.send(report) {
                hidFailures &+= 1
            }
        }
        clipWindow.record(abs(step.torque) >= 0.999)
        rate.record(now: now)
        publishStatus(wheel, step)
    }

    private func publishInput(_ wheel: WheelSnapshot) {
        tick &+= 1
        var input = wb_input()
        input.tick = tick
        input.connected = wheel.state == WB_WHEEL_READY ? 1 : 0
        if let model = wheel.model {
            input.vendor_product = UInt32(model.productID) << 16 | UInt32(WheelModel.logitechVendorID)
            BridgeText.write(model.windowsName, to: &input.name)
        }
        input.steering = wheel.steering
        input.throttle = wheel.throttle
        input.brake = wheel.brake
        input.clutch = wheel.clutch
        input.buttons = wheel.buttons
        input.hat = wheel.hat
        bridge.publish(input: input)
    }

    private func publishStatus(_ wheel: WheelSnapshot, _ step: MotorController.Step) {
        var status = wb_status()
        status.tick = tick
        status.wheel_state = wheel.state.rawValue
        status.game_connected = step.gameConnected ? 1 : 0
        status.active_effects = UInt32(step.activeEffects)
        status.loop_hz = UInt32(rate.hz)
        status.torque_permille = Int32((step.torque * 1000).rounded())
        status.clip_permille = UInt32(clipWindow.permille)
        status.hid_failures = hidFailures
        if step.gameConnected, let game = lastGame {
            status.game_name = game.game_name
        }
        bridge.publish(status: status)
    }

    private static func now() -> Double {
        Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1_000_000_000
    }
}

/// The share of the last few seconds spent at full torque.
struct ClipMeter {
    private var samples = [Bool](repeating: false, count: 1500)
    private var index = 0
    private var clipped = 0

    mutating func record(_ value: Bool) {
        if samples[index] { clipped -= 1 }
        samples[index] = value
        if value { clipped += 1 }
        index = (index + 1) % samples.count
    }

    var permille: Int { clipped * 1000 / samples.count }
}

/// Measures the real loop rate, once a second.
struct RateMeter {
    private var count = 0
    private var windowStart: Double?
    private(set) var hz = 0

    mutating func record(now: Double) {
        guard let start = windowStart else {
            windowStart = now
            return
        }
        count += 1
        if now - start >= 1 {
            hz = Int((Double(count) / (now - start)).rounded())
            count = 0
            windowStart = now
        }
    }
}

/// A flag one thread sets and another reads.
final class Atomic: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Bool

    init(_ value: Bool) { stored = value }

    var value: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
        set {
            lock.lock()
            stored = newValue
            lock.unlock()
        }
    }
}
