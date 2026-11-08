import Darwin
import Foundation

/// Keeps the helper running with launchd, so it survives the app quitting and is
/// restarted if it ever dies. On every start the helper releases the motor first.
enum HelperAgent {
    static let label = "com.bonevane.wheelbridge.helper"

    private static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    /// Registers the helper inside this app bundle, replacing any older copy.
    static func start() {
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/wheelbridged")
        guard FileManager.default.isExecutableFile(atPath: helper.path) else { return }
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [helper.path],
            "KeepAlive": true,
            "RunAtLoad": true,
            "ProcessType": "Interactive",
        ]
        guard let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) else { return }
        let changed = (try? Data(contentsOf: plistURL)) != data
        if changed {
            try? FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: plistURL, options: .atomic)
            launchctl(["bootout", "gui/\(getuid())/\(label)"])
        }
        launchctl(["bootstrap", "gui/\(getuid())", plistURL.path])
    }

    private static func launchctl(_ arguments: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }
}
