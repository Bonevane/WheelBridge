import CWheelBridge
import Foundation

/// Where the wheel is and how it is moving. Position runs −1 (full left) to +1
/// (full right) and the rates are per second.
public struct WheelMotion: Equatable {
    public var position = 0.0
    public var velocity = 0.0
    public var acceleration = 0.0

    public init(position: Double = 0, velocity: Double = 0, acceleration: Double = 0) {
        self.position = position
        self.velocity = velocity
        self.acceleration = acceleration
    }
}

/// Plays DirectInput effects as a single torque.
///
/// Doing this on the Mac, rather than in each wheel's firmware, is what keeps
/// wheel drivers small: a driver only has to send one number.
public struct EffectEngine {
    /// Full DirectInput scale.
    public static let fullScale = 10_000.0
    private static let infinite = UInt32.max

    /// When each slot's current run began, and which Start that run belongs to.
    private var runs = [Run?](repeating: nil, count: Int(WB_MAX_EFFECTS))

    private struct Run {
        var startCount: UInt32
        var startedAt: Double
    }

    public init() {}

    /// The torque for this instant, from −1 (full left) to +1 (full right).
    /// `effects` are the game's slots as published, and `now` is in seconds.
    public mutating func torque(effects: [wb_effect], motion: WheelMotion, now: Double) -> Double {
        var total = 0.0
        for (slot, effect) in effects.enumerated().prefix(runs.count) {
            guard effect.kind != WB_EFFECT_NONE.rawValue, effect.playing != 0 else {
                runs[slot] = nil
                continue
            }
            if runs[slot]?.startCount != effect.start_count {
                runs[slot] = Run(startCount: effect.start_count, startedAt: now)
            }
            guard let run = runs[slot] else { continue }
            let elapsed = now - run.startedAt - Double(effect.start_delay_us) / 1_000_000
            total += Self.force(effect, elapsed: elapsed, motion: motion)
        }
        return total / Self.fullScale
    }

    /// One effect's force in DirectInput units, positive towards the right.
    static func force(_ effect: wb_effect, elapsed: Double, motion: WheelMotion) -> Double {
        guard let local = localTime(effect, elapsed: elapsed) else { return 0 }
        let gain = Double(effect.gain) / fullScale
        let kind = wb_effect_kind(rawValue: effect.kind)
        switch kind {
        case WB_EFFECT_SPRING, WB_EFFECT_DAMPER, WB_EFFECT_INERTIA, WB_EFFECT_FRICTION:
            // A condition pushes back against whatever it measures.
            return -condition(effect, kind: kind, motion: motion) * gain
        default:
            let value = shaped(effect, local: local)
            // DirectInput directions name where a force comes from, so a force
            // from the right pushes the wheel left.
            return -value * directionX(effect) * gain
        }
    }

    /// Time within the current iteration, or nil if the effect is not running.
    private static func localTime(_ effect: wb_effect, elapsed: Double) -> Double? {
        guard elapsed >= 0 else { return nil }
        guard effect.duration_us != infinite else { return elapsed }
        let duration = Double(effect.duration_us) / 1_000_000
        guard duration > 0 else { return elapsed }
        let iterations = effect.iterations == infinite ? Double.infinity : Double(max(1, effect.iterations))
        guard elapsed < duration * iterations else { return nil }
        return elapsed.truncatingRemainder(dividingBy: duration)
    }

    /// Constant, ramp and periodic effects before direction and gain.
    private static func shaped(_ effect: wb_effect, local: Double) -> Double {
        let p = params(effect)
        let duration = effect.duration_us == infinite ? nil : Double(effect.duration_us) / 1_000_000
        switch wb_effect_kind(rawValue: effect.kind) {
        case WB_EFFECT_CONSTANT:
            return enveloped(p[0], effect, local: local, duration: duration)
        case WB_EFFECT_RAMP:
            guard let duration, duration > 0 else { return p[0] }
            return p[0] + (p[1] - p[0]) * min(1, local / duration)
        default:
            let magnitude = enveloped(p[0], effect, local: local, duration: duration)
            return p[1] + magnitude * wave(effect, local: local, phase: p[2], period: p[3])
        }
    }

    /// The periodic waveform, from −1 to +1.
    private static func wave(_ effect: wb_effect, local: Double, phase: Double, period: Double) -> Double {
        let seconds = period / 1_000_000
        guard seconds > 0 else { return 0 }
        // DirectInput phase runs 0...35999, in hundredths of a degree.
        var cycle = (local / seconds + phase / 36_000).truncatingRemainder(dividingBy: 1)
        if cycle < 0 { cycle += 1 }
        switch wb_effect_kind(rawValue: effect.kind) {
        case WB_EFFECT_SQUARE: return cycle < 0.5 ? 1 : -1
        case WB_EFFECT_SINE: return sin(cycle * 2 * .pi)
        case WB_EFFECT_TRIANGLE:
            return cycle < 0.25 ? cycle * 4 : cycle < 0.75 ? 2 - cycle * 4 : cycle * 4 - 4
        case WB_EFFECT_SAW_UP: return cycle * 2 - 1
        case WB_EFFECT_SAW_DOWN: return 1 - cycle * 2
        default: return 0
        }
    }

    /// Applies an attack and fade to a magnitude, keeping its sign.
    private static func enveloped(_ magnitude: Double, _ effect: wb_effect, local: Double, duration: Double?) -> Double {
        guard effect.has_envelope != 0 else { return magnitude }
        let sign = magnitude < 0 ? -1.0 : 1.0
        let sustain = abs(magnitude)
        var level = sustain
        let attack = Double(effect.attack_time_us) / 1_000_000
        if attack > 0, local < attack {
            let from = Double(effect.attack_level)
            level = from + (sustain - from) * local / attack
        }
        if let duration {
            let fade = Double(effect.fade_time_us) / 1_000_000
            let fadeStart = duration - fade
            if fade > 0, local > fadeStart {
                let to = Double(effect.fade_level)
                level = sustain + (to - sustain) * (local - fadeStart) / fade
            }
        }
        return sign * level
    }

    /// The wheel's share of where the force comes from, from −1 to +1.
    static func directionX(_ effect: wb_effect) -> Double {
        let d0 = Double(effect.direction.0), d1 = Double(effect.direction.1)
        switch effect.coords {
        case WB_COORD_POLAR:
            // Clockwise from north in hundredths of a degree, so 9000 is east.
            return sin(d0 / 100 * .pi / 180)
        case WB_COORD_SPHERICAL:
            // Measured from the first axis, so 0 is along the wheel.
            let angle = cos(d0 / 100 * .pi / 180)
            return effect.x_axis_index == 0 ? angle : sin(d0 / 100 * .pi / 180)
        default:
            if effect.axis_count < 2 { return d0 == 0 ? 1 : (d0 < 0 ? -1 : 1) }
            let x = effect.x_axis_index == 0 ? d0 : d1
            let length = (d0 * d0 + d1 * d1).squareRoot()
            return length > 0 ? x / length : 0
        }
    }

    /// A condition's response, in the same direction as what it measures.
    private static func condition(_ effect: wb_effect, kind: wb_effect_kind, motion: WheelMotion) -> Double {
        let metric: Double
        switch kind {
        case WB_EFFECT_SPRING: metric = motion.position * fullScale
        // Full scale is lock to lock in about a second.
        case WB_EFFECT_DAMPER: metric = motion.velocity / 2 * fullScale
        case WB_EFFECT_INERTIA: metric = motion.acceleration / 40 * fullScale
        // Friction wants the direction of travel, not its speed.
        default: metric = tanh(motion.velocity / 0.05) * fullScale
        }
        let p = params(effect)
        let offset = p[0], deadBand = max(0, p[5])
        let x = max(-fullScale, min(fullScale, metric)) - offset
        if x > deadBand {
            let limit = saturation(effect.params.3)
            return min(limit, p[1] * (x - deadBand) / fullScale)
        }
        if x < -deadBand {
            let limit = saturation(effect.params.4)
            return max(-limit, p[2] * (x + deadBand) / fullScale)
        }
        return 0
    }

    /// DirectInput treats a saturation of zero as no limit.
    private static func saturation(_ raw: Int32) -> Double {
        let value = UInt32(bitPattern: raw)
        return value == 0 ? fullScale : Double(value)
    }

    private static func params(_ effect: wb_effect) -> [Double] {
        let p = effect.params
        return [Double(p.0), Double(p.1), Double(p.2), Double(p.3), Double(p.4), Double(p.5)]
    }
}

/// Lets the checks reach one effect's force on its own.
public enum EffectEngineProbe {
    public static func force(_ effect: wb_effect, _ elapsed: Double, _ motion: WheelMotion) -> Double {
        EffectEngine.force(effect, elapsed: elapsed, motion: motion)
    }
}

/// Turns the engine's torque into what actually reaches the motor.
public struct TorqueLimiter {
    public init() {}

    /// Applies strength and direction settings and clamps to the motor's range.
    /// `strength` runs 0...1.
    public func output(torque: Double, strength: Double, reversed: Bool) -> Double {
        guard torque.isFinite else { return 0 }
        let scaled = torque * max(0, min(1, strength)) * (reversed ? -1 : 1)
        return max(-1, min(1, scaled))
    }
}
