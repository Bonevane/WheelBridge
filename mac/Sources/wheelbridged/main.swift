import CWheelBridge
import Darwin
import Foundation
import WheelCore

// The helper owns the wheel and the motor. It has no UI, so the app can crash
// or quit without touching a force that is being held.

/// Stands in for a wheel, for testing the whole path without hardware. Every
/// report goes to stdout so a test can read exactly what the motor would get.
final class SimulatedWheelPort: WheelPort, @unchecked Sendable {
    func send(_ report: [UInt8]) -> Bool {
        print("report", report.map { String(format: "%02x", $0) }.joined(separator: " "))
        fflush(stdout)
        return true
    }

    func snapshot() -> WheelSnapshot {
        var snapshot = WheelSnapshot()
        snapshot.state = WB_WHEEL_READY
        snapshot.model = .g29
        snapshot.generation = 1
        return snapshot
    }
}

let arguments = CommandLine.arguments
let simulate = arguments.contains("--simulate")

func option(_ name: String) -> URL? {
    arguments.firstIndex(of: name).flatMap { index in
        arguments.indices.contains(index + 1) ? URL(fileURLWithPath: arguments[index + 1]) : nil
    }
}

let bridgeURL = option("--bridge") ?? SharedBridge.defaultURL

// Install and uninstall from the command line, for scripts and support.
if let target = option("--install") ?? option("--uninstall") {
    guard let folder = option("--proxies") else {
        FileHandle.standardError.write(Data("wheelbridged: --proxies FOLDER is required\n".utf8))
        exit(2)
    }
    let installer = BottleInstaller(
        proxy64: folder.appendingPathComponent("x86_64/dinput8.dll"),
        proxy32: folder.appendingPathComponent("i686/dinput8.dll"),
        // --crossover picks one CrossOver; without it, the newest one found.
        crossOverApps: option("--crossover").map { [$0] } ?? CrossOverInstall.detected().map(\.url),
        bridgeFile: bridgeURL)
    let bottle = Bottle(url: target)
    do {
        if option("--install") != nil {
            try installer.install(into: bottle)
        } else {
            try installer.uninstall(from: bottle)
        }
        print("\(bottle.name): \(installer.state(of: bottle))")
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("wheelbridged: \(error)\n".utf8))
        exit(1)
    }
}

do {
    let bridge = try SharedBridge(url: bridgeURL, owner: true)
    let port: WheelPort
    if simulate {
        port = SimulatedWheelPort()
    } else {
        let hid = HIDWheelPort()
        hid.start()
        port = hid
    }
    let loop = HelperLoop(port: port, bridge: bridge)

    // A clean exit must release the motor, so these stop the loop and let it finish.
    signal(SIGTERM, SIG_IGN)
    signal(SIGINT, SIG_IGN)
    let sources = [SIGTERM, SIGINT].map { number -> DispatchSourceSignal in
        let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
        source.setEventHandler { loop.stop() }
        source.resume()
        return source
    }
    withExtendedLifetime(sources) { loop.run() }
} catch {
    FileHandle.standardError.write(Data("wheelbridged: \(error)\n".utf8))
    exit(1)
}
