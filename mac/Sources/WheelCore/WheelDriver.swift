import Foundation

/// One output report: its ID, and the bytes after it. An ID of zero means the
/// device has no report IDs, so the bytes go out as they are.
public struct OutputReport: Equatable {
    public var id: UInt8
    public var bytes: [UInt8]

    public init(id: UInt8 = 0, _ bytes: [UInt8]) {
        self.id = id
        self.bytes = bytes
    }
}

/// A family of wheels that speak the same protocol.
///
/// Everything above this layer works in plain torque and degrees, so adding a
/// wheel family means adding one of these and nothing else.
public protocol WheelDriver {
    /// Bytes for each output report, in order, to bring the wheel up.
    func start(rangeDegrees: Int) -> [[UInt8]]
    /// Bytes that make the motor apply `torque`, from −1 to +1.
    func torque(_ torque: Double) -> [UInt8]
    /// Bytes that set the rotation range. Empty for wheels with a fixed range.
    func rangeReports(degrees: Int) -> [[UInt8]]
    /// Bytes that release the motor at once.
    func stop() -> [UInt8]
}

extension WheelDriver {
    /// The one report that sets the range, for wheels that need only one.
    public func range(degrees: Int) -> [UInt8] { rangeReports(degrees: degrees).first ?? [] }
}

/// What WheelBridge knows about a USB wheel.
public struct WheelModel: Equatable {
    /// How a wheel sets its rotation range.
    public enum RangeCommand: Equatable {
        /// One "f8 81" report: G25 and every wheel after it.
        case extended
        /// A coarse and a fine limit: the Driving Force Pro.
        case drivingForcePro
        /// No range control: the range is fixed in hardware.
        case fixed
    }

    public var productID: Int
    public var name: String
    /// The name games see, matching the Windows driver so presets apply.
    public var windowsName: String
    public var minimumRange: Int
    public var maximumRange: Int
    public var rangeCommand: RangeCommand
    /// Why WheelBridge can't drive it yet, or nil if it can.
    public var unsupportedReason: String?
    /// Tested on real hardware. Others only follow published protocol notes.
    public var verified: Bool

    public var isSupported: Bool { unsupportedReason == nil }

    public static let logitechVendorID = 0x046d

    // The classic Logitech protocol. IDs and ranges follow Linux's hid-lg4ff
    // and the out-of-tree new-lg4ff, which between them cover every one.
    public static let g29 = WheelModel(
        productID: 0xc24f, name: "G29", windowsName: "Logitech G29 Driving Force Racing Wheel USB",
        minimumRange: 40, maximumRange: 900, rangeCommand: .extended, verified: true)
    public static let g923PlayStation = WheelModel(
        productID: 0xc266, name: "G923", windowsName: "G923 Racing Wheel for PlayStation and PC",
        minimumRange: 40, maximumRange: 900, rangeCommand: .extended, verified: false)
    public static let g27 = WheelModel(
        productID: 0xc29b, name: "G27", windowsName: "Logitech G27 Racing Wheel USB",
        minimumRange: 40, maximumRange: 900, rangeCommand: .extended, verified: false)
    public static let g25 = WheelModel(
        productID: 0xc299, name: "G25", windowsName: "Logitech G25 Racing Wheel USB",
        minimumRange: 40, maximumRange: 900, rangeCommand: .extended, verified: false)
    public static let drivingForceGT = WheelModel(
        productID: 0xc29a, name: "Driving Force GT", windowsName: "Logitech Driving Force GT USB",
        minimumRange: 40, maximumRange: 900, rangeCommand: .extended, verified: false)
    public static let drivingForcePro = WheelModel(
        productID: 0xc298, name: "Driving Force Pro", windowsName: "Logitech Driving Force Pro USB",
        minimumRange: 40, maximumRange: 900, rangeCommand: .drivingForcePro, verified: false)
    public static let drivingForce = WheelModel(
        productID: 0xc294, name: "Driving Force", windowsName: "Logitech Driving Force USB",
        minimumRange: 270, maximumRange: 270, rangeCommand: .fixed, verified: false)
    public static let momoForce = WheelModel(
        productID: 0xc295, name: "MOMO Force", windowsName: "Logitech MOMO Force USB",
        minimumRange: 270, maximumRange: 270, rangeCommand: .fixed, verified: false)
    public static let momoRacing = WheelModel(
        productID: 0xca03, name: "MOMO Racing", windowsName: "Logitech MOMO Racing USB",
        minimumRange: 270, maximumRange: 270, rangeCommand: .fixed, verified: false)

    // Wheels that are recognised, so the app can say what they are, but use a
    // protocol WheelBridge doesn't speak yet.
    private static let hidppReason = "Uses Logitech's HID++ force feedback, which isn't supported yet."
    public static let g920 = WheelModel(
        productID: 0xc262, name: "G920", windowsName: "Logitech G920 Driving Force Racing Wheel USB",
        minimumRange: 40, maximumRange: 900, rangeCommand: .fixed, unsupportedReason: hidppReason, verified: false)
    public static let g923Xbox = WheelModel(
        productID: 0xc26e, name: "G923 (Xbox)", windowsName: "G923 Racing Wheel for Xbox One and PC",
        minimumRange: 40, maximumRange: 900, rangeCommand: .fixed, unsupportedReason: hidppReason, verified: false)
    public static let proRacing = WheelModel(
        productID: 0xc272, name: "PRO Racing Wheel", windowsName: "PRO Racing Wheel",
        minimumRange: 40, maximumRange: 1080, rangeCommand: .fixed,
        unsupportedReason: "Direct drive, with its own protocol. Not supported yet.", verified: false)

    public static let supported = [g29, g923PlayStation, g27, g25, drivingForceGT, drivingForcePro, drivingForce, momoForce, momoRacing]
    public static let recognised = supported + [g920, g923Xbox, proRacing]

    public init(productID: Int, name: String, windowsName: String, minimumRange: Int, maximumRange: Int,
                rangeCommand: RangeCommand, unsupportedReason: String? = nil, verified: Bool) {
        self.productID = productID
        self.name = name
        self.windowsName = windowsName
        self.minimumRange = minimumRange
        self.maximumRange = maximumRange
        self.rangeCommand = rangeCommand
        self.unsupportedReason = unsupportedReason
        self.verified = verified
    }

    public static func model(productID: Int) -> WheelModel? {
        recognised.first { $0.productID == productID }
    }

    /// The ID every multimode wheel shows in its Driving Force compatibility mode.
    public static let compatibilityProductID = 0xc294
    /// The ID a G923 shows in PlayStation mode.
    public static let g923CompatibilityProductID = 0xc267

    /// IDs worth opening: every wheel above, plus the compatibility modes.
    public static var matchedProductIDs: [Int] {
        recognised.map(\.productID) + [g923CompatibilityProductID]
    }
}

/// What to do with a wheel that has just been plugged in.
public enum WheelArrival: Equatable {
    /// Drive it as this model.
    case ready(WheelModel)
    /// Send these to move it to its native mode. It then drops off USB and
    /// comes back with its native ID, which arrives as a new wheel.
    case switchMode(to: WheelModel, reports: [OutputReport])
    /// Show it, but don't drive it.
    case unsupported(WheelModel)
    case unknown

    /// Multimode Logitech wheels all start in compatibility mode with the same
    /// ID. Their firmware version says which wheel each one really is.
    /// The masks and values are hid-lg4ff's, checked newest wheel first.
    public static func identify(productID: Int, version: Int) -> WheelArrival {
        if productID == WheelModel.g923CompatibilityProductID {
            // Report ID 0x30, as new-lg4ff sends it.
            return .switchMode(to: .g923PlayStation, reports: [OutputReport(id: 0x30, [0xf8, 0x09, 0x07, 0x01, 0x01, 0x00, 0x00])])
        }
        if productID == WheelModel.compatibilityProductID {
            let revert: [UInt8] = [0xf8, 0x0a, 0x00, 0x00, 0x00, 0x00, 0x00] // keep the mode on USB reset
            let checks: [(mask: Int, value: Int, model: WheelModel, switch: [[UInt8]])] = [
                (0xfff8, 0x1350, .g29, [revert, [0xf8, 0x09, 0x05, 0x01, 0x01, 0x00, 0x00]]),
                (0xff00, 0x8900, .g29, [revert, [0xf8, 0x09, 0x05, 0x01, 0x01, 0x00, 0x00]]),
                (0xfff0, 0x1230, .g27, [revert, [0xf8, 0x09, 0x04, 0x01, 0x00, 0x00, 0x00]]),
                (0xff00, 0x1300, .drivingForceGT, [revert, [0xf8, 0x09, 0x03, 0x01, 0x00, 0x00, 0x00]]),
                (0xff00, 0x1200, .g25, [[0xf8, 0x10, 0x00, 0x00, 0x00, 0x00, 0x00]]),
                (0xf000, 0x1000, .drivingForcePro, [[0xf8, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00]]),
            ]
            if let match = checks.first(where: { version & $0.mask == $0.value }) {
                return .switchMode(to: match.model, reports: match.switch.map { OutputReport($0) })
            }
            return .ready(.drivingForce) // a genuine Driving Force or Driving Force EX
        }
        guard let model = WheelModel.model(productID: productID) else { return .unknown }
        return model.isSupported ? .ready(model) : .unsupported(model)
    }
}

/// The classic Logitech protocol, used by the G29, the PlayStation G923 and
/// every Logitech force feedback wheel before them. Every report is seven bytes.
/// Facts follow the public hid-lg4ff and new-lg4ff drivers.
public struct LogitechClassicDriver: WheelDriver {
    public static let reportLength = 7

    public var model: WheelModel

    public init(model: WheelModel = .g29) {
        self.model = model
    }

    public func start(rangeDegrees: Int) -> [[UInt8]] {
        [stop(), [0xf5, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]] // the firmware's own centring spring off
            + rangeReports(degrees: rangeDegrees)
    }

    public func torque(_ torque: Double) -> [UInt8] {
        let clamped = torque.isFinite ? max(-1, min(1, torque)) : 0
        let code = UInt8(max(0, min(255, (128 + clamped * 127).rounded())))
        return [0x11, 0x00, code, 0x80, 0x80, 0x80, 0x00] // constant force in slot 1
    }

    public func rangeReports(degrees: Int) -> [[UInt8]] {
        let range = max(model.minimumRange, min(model.maximumRange, degrees))
        switch model.rangeCommand {
        case .fixed:
            return []
        case .extended:
            return [[0xf8, 0x81, UInt8(range & 0xff), UInt8(range >> 8), 0x00, 0x00, 0x00]]
        case .drivingForcePro:
            // A coarse limit of 200° or 900°, then a fine limit inside it.
            let full = range > 200 ? 900 : 200
            let coarse: [UInt8] = [0xf8, range > 200 ? 0x03 : 0x02, 0x00, 0x00, 0x00, 0x00, 0x00]
            guard range != full else { return [coarse, [0x81, 0x0b, 0x00, 0x00, 0x00, 0x00, 0x00]] }
            let left = (full - range + 1) * 2047 / full
            let right = 0xfff - left
            let fine: [UInt8] = [0x81, 0x0b, UInt8(left >> 4), UInt8((right >> 4) & 0xff), 0xff,
                                 UInt8(((right & 0xe) << 4) | (left & 0xe)), 0xff]
            return [coarse, fine]
        }
    }

    public func stop() -> [UInt8] {
        [0xf3, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
    }
}
