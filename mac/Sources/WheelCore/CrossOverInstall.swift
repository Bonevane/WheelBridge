import CoreServices
import Foundation

/// One copy of CrossOver on this Mac. People keep more than one, such as a
/// release and a patched build, and the bottle must get its dinput8 from the one
/// that actually runs it.
public struct CrossOverInstall: Equatable, Identifiable, Hashable {
    public var url: URL
    public var id: String { url.path }

    public init(url: URL) { self.url = url.standardizedFileURL }

    /// "CrossOver" or "CrossOver CX", from the app's file name.
    public var name: String { url.deletingPathExtension().lastPathComponent }

    public var version: String? {
        let info = NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist"))
        return info?["CFBundleShortVersionString"] as? String
    }

    /// Where its Windows libraries are, for one architecture such as "x86_64-windows".
    public func wineLibrary(_ arch: String) -> URL {
        url.appendingPathComponent("Contents/SharedSupport/CrossOver/lib/wine/\(arch)")
    }

    /// Whether this looks like a CrossOver that WheelBridge can use.
    public var isUsable: Bool {
        BottleInstaller.isWineBuiltin(wineLibrary("x86_64-windows").appendingPathComponent("dinput8.dll"))
    }

    /// Every CrossOver that Launch Services knows about, plus the usual places,
    /// newest version first.
    public static func detected() -> [CrossOverInstall] {
        var urls: [URL] = []
        if let found = LSCopyApplicationURLsForBundleIdentifier("com.codeweavers.CrossOver" as CFString, nil)?
            .takeRetainedValue() as? [URL] {
            urls += found
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        urls += [URL(fileURLWithPath: "/Applications/CrossOver.app"), home.appendingPathComponent("Applications/CrossOver.app")]

        var seen = Set<String>()
        let installs = urls.map(CrossOverInstall.init).filter { seen.insert($0.id).inserted && $0.isUsable }
        return installs.sorted { ($0.version ?? "").compare($1.version ?? "", options: .numeric) == .orderedDescending }
    }
}
