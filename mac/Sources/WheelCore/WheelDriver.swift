import Foundation

/// A family of wheels that speak the same protocol.
///
/// Everything above this layer works in plain torque and degrees, so adding a
/// wheel family means adding one of these and nothing else.
public protocol WheelDriver {
    /// Bytes for each output report, in order, to bring the wheel up.
    func start(rangeDegrees: Int) -> [[UInt8]]
    /// Bytes that make the motor apply `torque`, from −1 to +1.
    func torque(_ torque: Double) -> [UInt8]
    /// Bytes that set the rotation range.
    func range(degrees: Int) -> [UInt8]
    /// Bytes that release the motor at once.
    func stop() -> [UInt8]
}

/// What WheelBridge knows about a USB wheel.
public struct WheelModel: Equatable {
    public var productID: Int
    public var name: String
    /// The name games see, matching the Windows driver so presets apply.
    public var windowsName: String
    public var minimumRange: Int
    public var maximumRange: Int
    /// Tested on real hardware. Others only follow published protocol notes.
    public var verified: Bool

    public static let logitechVendorID = 0x046d

    public static let g29 = WheelModel(
        productID: 0xc24f, name: "G29", windowsName: "Logitech G29 Driving Force Racing Wheel USB",
        minimumRange: 40, maximumRange: 900, verified: false)
    public static let g923PlayStation = WheelModel(
        productID: 0xc266, name: "G923", windowsName: "G923 Racing Wheel for PlayStation and PC",
        minimumRange: 40, maximumRange: 900, verified: false)

    public static let supported = [g29, g923PlayStation]

    public static func model(productID: Int) -> WheelModel? {
        supported.first { $0.productID == productID }
    }

    /// The product ID a G29 shows while in compatibility mode.
    public static let compatibilityProductID = 0xc294
}

/// The classic Logitech protocol, used by the G29 and the PlayStation G923.
/// Every report is seven bytes. Facts follow the public `new-lg4ff` driver.
public struct LogitechClassicDriver: WheelDriver {
    public static let reportLength = 7

    public init() {}

    /// Moves a G29 out of compatibility mode. The wheel then drops off USB and
    /// comes back with its native product ID.
    public static func switchToNative() -> [[UInt8]] {
        [
            [0xf8, 0x0a, 0x00, 0x00, 0x00, 0x00, 0x00], // revert to this mode on USB reset
            [0xf8, 0x09, 0x05, 0x01, 0x01, 0x00, 0x00], // switch to G29 mode, with detach
        ]
    }

    public func start(rangeDegrees: Int) -> [[UInt8]] {
        [
            stop(),
            [0xf5, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00], // the firmware's own centring spring off
            range(degrees: rangeDegrees),
        ]
    }

    public func torque(_ torque: Double) -> [UInt8] {
        let clamped = torque.isFinite ? max(-1, min(1, torque)) : 0
        let code = UInt8(max(0, min(255, (128 + clamped * 127).rounded())))
        return [0x11, 0x00, code, 0x80, 0x80, 0x80, 0x00] // constant force in slot 1
    }

    public func range(degrees: Int) -> [UInt8] {
        let clamped = max(40, min(900, degrees))
        return [0xf8, 0x81, UInt8(clamped & 0xff), UInt8(clamped >> 8), 0x00, 0x00, 0x00]
    }

    public func stop() -> [UInt8] {
        [0xf3, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
    }
}
