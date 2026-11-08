import CWheelBridge
import Foundation
import IOKit.hid

/// The wheel as the helper sees it.
public protocol WheelPort: AnyObject {
    /// Sends one output report. False means the wheel refused it.
    func send(_ report: [UInt8]) -> Bool
    /// The latest input, already mapped to the bridge's layout.
    func snapshot() -> WheelSnapshot
}

public struct WheelSnapshot {
    public var state = WB_WHEEL_MISSING
    /// Changes each time a wheel is opened, so a replug is never missed.
    public var generation = 0
    public var model: WheelModel?
    public var steering: UInt32 = 32768
    public var throttle: UInt32 = 65535
    public var brake: UInt32 = 65535
    public var clutch: UInt32 = 65535
    public var buttons: UInt32 = 0
    public var hat: UInt32 = WB_HAT_CENTRED

    public init() {}
}

/// The real wheel, over IOHIDManager.
///
/// It never seizes the device. A seize would take input from everything else,
/// and with one in place any other client's writes are refused too.
public final class HIDWheelPort: WheelPort, @unchecked Sendable {
    private let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    private let lock = NSLock()
    private var device: IOHIDDevice?
    private var current = WheelSnapshot()
    private var thread: Thread?

    public init() {}

    /// Starts watching for wheels on a dedicated thread.
    public func start() {
        let thread = Thread { [weak self] in self?.run() }
        thread.name = "WheelBridge HID"
        thread.qualityOfService = .userInteractive
        self.thread = thread
        thread.start()
    }

    public func snapshot() -> WheelSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    public func send(_ report: [UInt8]) -> Bool {
        lock.lock()
        let target = device
        lock.unlock()
        guard let target else { return false }
        let result = report.withUnsafeBufferPointer { bytes -> IOReturn in
            guard let base = bytes.baseAddress else { return kIOReturnBadArgument }
            return IOHIDDeviceSetReport(target, kIOHIDReportTypeOutput, 0, base, bytes.count)
        }
        return result == kIOReturnSuccess
    }

    private func run() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        let products = WheelModel.supported.map(\.productID) + [WheelModel.compatibilityProductID]
        let matching = products.map { product -> [String: Int] in
            [
                kIOHIDVendorIDKey: WheelModel.logitechVendorID,
                kIOHIDProductIDKey: product,
                kIOHIDPrimaryUsagePageKey: 1,
                kIOHIDPrimaryUsageKey: 4, // joystick: the G29 also has a vendor node to avoid
            ]
        }
        IOHIDManagerSetDeviceMatchingMultiple(manager, matching as CFArray)
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, device in
            guard let context else { return }
            Unmanaged<HIDWheelPort>.fromOpaque(context).takeUnretainedValue().attach(device)
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, device in
            guard let context else { return }
            Unmanaged<HIDWheelPort>.fromOpaque(context).takeUnretainedValue().detach(device)
        }, context)
        IOHIDManagerRegisterInputValueCallback(manager, { context, _, _, value in
            guard let context else { return }
            Unmanaged<HIDWheelPort>.fromOpaque(context).takeUnretainedValue().receive(value)
        }, context)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        let opened = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        if opened != kIOReturnSuccess {
            update { $0.state = WB_WHEEL_OPEN_FAILED }
        }
        CFRunLoopRun()
    }

    private func attach(_ candidate: IOHIDDevice) {
        let product = IOHIDDeviceGetProperty(candidate, kIOHIDProductIDKey as CFString) as? Int ?? 0
        lock.lock()
        device = candidate
        lock.unlock()

        if product == WheelModel.compatibilityProductID {
            update { $0.state = WB_WHEEL_SWITCHING }
            for report in LogitechClassicDriver.switchToNative() {
                _ = send(report)
            }
            return // the wheel detaches and comes back with its native ID
        }

        update {
            let generation = $0.generation + 1
            $0 = WheelSnapshot()
            $0.generation = generation
            $0.model = WheelModel.model(productID: product)
            $0.state = $0.model == nil ? WB_WHEEL_MISSING : WB_WHEEL_READY
        }
    }

    private func detach(_ gone: IOHIDDevice) {
        lock.lock()
        let same = device.map { CFEqual($0, gone) } ?? false
        if same { device = nil }
        lock.unlock()
        guard same else { return }
        update {
            let generation = $0.generation
            $0 = WheelSnapshot()
            $0.generation = generation
        }
    }

    private func receive(_ value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        // Long values are whole vendor reports, not controls.
        guard IOHIDValueGetLength(value) <= 8 else { return }
        let page = IOHIDElementGetUsagePage(element), usage = IOHIDElementGetUsage(element)
        let raw = IOHIDValueGetIntegerValue(value)
        let minimum = IOHIDElementGetLogicalMin(element), maximum = IOHIDElementGetLogicalMax(element)
        update { snapshot in
            WheelInputMap.apply(page: page, usage: usage, raw: raw, minimum: minimum, maximum: maximum, to: &snapshot)
        }
    }

    private func update(_ change: (inout WheelSnapshot) -> Void) {
        lock.lock()
        change(&current)
        lock.unlock()
    }
}

/// How the G29's HID controls map onto the bridge. Kept apart from IOKit so it
/// can be checked. The report has X wheel, Y clutch, Z accelerator and Rz brake.
public enum WheelInputMap {
    public static func apply(page: UInt32, usage: UInt32, raw: Int, minimum: Int, maximum: Int, to snapshot: inout WheelSnapshot) {
        switch (page, usage) {
        case (1, 0x39):
            snapshot.hat = hat(raw: raw, minimum: minimum, maximum: maximum)
        case (1, 0x30): snapshot.steering = scaled(raw, minimum, maximum)
        case (1, 0x31): snapshot.clutch = scaled(raw, minimum, maximum)
        case (1, 0x32): snapshot.throttle = scaled(raw, minimum, maximum)
        case (1, 0x35): snapshot.brake = scaled(raw, minimum, maximum)
        case (9, 1...32):
            let bit: UInt32 = 1 << (usage - 1)
            if raw != 0 { snapshot.buttons |= bit } else { snapshot.buttons &= ~bit }
        default:
            break
        }
    }

    private static func scaled(_ raw: Int, _ minimum: Int, _ maximum: Int) -> UInt32 {
        guard maximum > minimum else { return 0 }
        let clamped = max(minimum, min(maximum, raw))
        return UInt32((Double(clamped - minimum) / Double(maximum - minimum) * 65535).rounded())
    }

    /// A hat reports its eight directions in order, and anything outside its
    /// logical range means it is centred.
    private static func hat(raw: Int, minimum: Int, maximum: Int) -> UInt32 {
        guard raw >= minimum, raw <= maximum else { return WB_HAT_CENTRED }
        return UInt32(raw - minimum)
    }
}
