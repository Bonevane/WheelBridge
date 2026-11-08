import CWheelBridge
import Foundation

/// The settings the motor obeys, as read from the shared block.
public struct MotorSettings: Equatable {
    public var rangeDegrees = 900
    public var strength = 0.8
    public var centering = 0.0
    public var reversed = false
    public var motorStopped = false

    public init() {}

    public init(_ raw: wb_settings) {
        // An all-zero block means the app has never written, so keep the defaults.
        guard raw.revision != 0 else { return }
        rangeDegrees = Int(raw.range_degrees)
        strength = Double(raw.strength) / 100
        centering = Double(raw.centering) / 100
        reversed = raw.reverse != 0
        motorStopped = raw.motor_stopped != 0
    }
}

/// Decides, on every cycle, what the motor may do.
///
/// This holds every safety rule, and it touches no hardware: it returns the
/// reports to send, so the rules can be checked without a wheel. The default in
/// any doubt is no force.
public struct MotorController {
    public struct Step {
        public var reports: [[UInt8]] = []
        public var torque = 0.0
        public var gameConnected = false
        public var activeEffects = 0
    }

    private let driver: WheelDriver
    private var engine = EffectEngine()
    private let limiter = TorqueLimiter()
    private var motion = WheelMotion()

    private var started = false
    private var appliedRange: Int?
    private var lastTorqueReport: [UInt8]?
    private var motorHeld = false

    private var lastGameTick: UInt32?
    private var lastGameTickChange = -Double.infinity
    private var lastPosition: Double?
    private var lastTime: Double?

    public init(driver: WheelDriver) {
        self.driver = driver
    }

    /// Runs one cycle. `steering` is the raw 0...65535 axis, `game` is nil if the
    /// block could not be read, and `now` is in seconds.
    public mutating func step(steering: UInt32, game: wb_game?, settings: MotorSettings, now: Double) -> Step {
        var step = Step()
        if !started {
            started = true
            appliedRange = settings.rangeDegrees
            step.reports += driver.start(rangeDegrees: settings.rangeDegrees)
        }
        if appliedRange != settings.rangeDegrees {
            appliedRange = settings.rangeDegrees
            step.reports.append(driver.range(degrees: settings.rangeDegrees))
        }

        updateMotion(steering: steering, now: now)
        let live = isLive(game, now: now)
        step.gameConnected = live

        guard live, let game, !settings.motorStopped,
              game.flags & WB_GAME_PAUSED == 0, game.flags & WB_GAME_ACTUATORS_OFF == 0
        else {
            release(into: &step)
            return step
        }

        let effects = Self.effects(of: game)
        step.activeEffects = effects.filter { $0.playing != 0 && $0.kind != WB_EFFECT_NONE.rawValue }.count
        var torque = engine.torque(effects: effects, motion: motion, now: now)
        torque *= Double(game.gain) / EffectEngine.fullScale
        if game.flags & WB_GAME_AUTOCENTER != 0 {
            torque -= motion.position * settings.centering
        }
        step.torque = limiter.output(torque: torque, strength: settings.strength, reversed: settings.reversed)

        let report = driver.torque(step.torque)
        if report != lastTorqueReport {
            lastTorqueReport = report
            motorHeld = true
            step.reports.append(report)
        }
        return step
    }

    /// What to send when the helper is about to exit, or has just lost the wheel.
    public func shutdownReports() -> [[UInt8]] { [driver.stop()] }

    /// Forgets the wheel's state, so the next step brings a replugged wheel up again.
    public mutating func wheelReconnected() {
        started = false
        appliedRange = nil
        lastTorqueReport = nil
        motorHeld = false
        lastPosition = nil
        lastTime = nil
    }

    private mutating func release(into step: inout Step) {
        engine = EffectEngine()
        step.torque = 0
        guard motorHeld else { return }
        motorHeld = false
        lastTorqueReport = nil
        step.reports.append(driver.stop())
    }

    /// A game is live only while it owns the wheel and its tick keeps moving.
    private mutating func isLive(_ game: wb_game?, now: Double) -> Bool {
        guard let game, game.owner_pid != 0 else {
            lastGameTick = nil
            return false
        }
        if game.tick != lastGameTick {
            lastGameTick = game.tick
            lastGameTickChange = now
        }
        return now - lastGameTickChange < Double(WB_STALE_MS) / 1000
    }

    private mutating func updateMotion(steering: UInt32, now: Double) {
        let position = Double(steering) / 32767.5 - 1
        defer {
            lastPosition = position
            lastTime = now
        }
        guard let lastPosition, let lastTime, now > lastTime else {
            motion.position = position
            return
        }
        let dt = now - lastTime
        let velocity = motion.velocity + 0.2 * ((position - lastPosition) / dt - motion.velocity)
        motion.acceleration += 0.1 * ((velocity - motion.velocity) / dt - motion.acceleration)
        motion.velocity = velocity
        motion.position = position
    }

    private static func effects(of game: wb_game) -> [wb_effect] {
        withUnsafeBytes(of: game.effects) { Array($0.bindMemory(to: wb_effect.self)) }
    }
}
