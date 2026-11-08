import CryptoKit
import Darwin
import Foundation

/// A CrossOver bottle.
public struct Bottle: Equatable, Identifiable {
    public var url: URL
    public var id: String { url.path }
    public var name: String { url.lastPathComponent }

    public init(url: URL) { self.url = url }

    public var userRegistry: URL { url.appendingPathComponent("user.reg") }
    var system32: URL { url.appendingPathComponent("drive_c/windows/system32") }
    var syswow64: URL { url.appendingPathComponent("drive_c/windows/syswow64") }
    var manifestURL: URL { url.appendingPathComponent("wheelbridge-install.json") }

    public static func all(in root: URL = Bottle.defaultRoot) -> [Bottle] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return names.sorted().map { Bottle(url: root.appendingPathComponent($0)) }.filter {
            FileManager.default.fileExists(atPath: $0.url.appendingPathComponent("cxbottle.conf").path)
        }
    }

    public static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/CrossOver/Bottles", isDirectory: true)
    }
}

/// Where one bottle stands.
public enum BottleState: Equatable {
    case notInstalled
    case installed
    /// Installed once, but something has since changed it, usually a CrossOver update.
    case needsRepair(String)
}

/// Puts the proxy into a bottle, and takes it out again exactly.
public struct BottleInstaller {
    public enum Failure: Error, Equatable, CustomStringConvertible {
        case wineRunning
        case noDriveZ
        case builtinNotFound(String)
        case proxyMissing(String)
        case notInstalled

        public var description: String {
            switch self {
            case .wineRunning: return "Quit everything running in this bottle first."
            case .noDriveZ: return "This bottle has no Z: drive mapped to /."
            case .builtinNotFound(let arch): return "Can't find CrossOver's \(arch) dinput8.dll."
            case .proxyMissing(let path): return "Proxy not found at \(path)."
            case .notInstalled: return "Not installed in this bottle."
            }
        }
    }

    /// A Wine library says what it is in its DOS stub, at this offset.
    private static let signatureOffset = 64
    private static let builtinSignature = Data("Wine builtin DLL".utf8)
    private static let overrideSection = #"[Software\\Wine\\DllOverrides]"#
    private static let overrideKey = "dinput8"
    private static let overrideValue = "native,builtin"

    static let realName = "wheelbridge_dinput8_real.dll"
    static let backupName = "dinput8.wheelbridge-original.dll"
    static let configName = "wheelbridge.ini"
    static let dllName = "dinput8.dll"

    struct Manifest: Codable, Equatable {
        var version = 1
        /// What the override was before, or nil if there was none.
        var previousOverride: String?
    }

    /// The bundled proxies.
    public var proxy64: URL
    public var proxy32: URL
    /// CrossOver installs to look in for its builtin DLLs.
    public var crossOverApps: [URL]
    public var bridgeFile: URL
    /// Whether wine is running in a bottle. Replaceable for tests.
    public var isWineRunning: (Bottle) -> Bool = BottleInstaller.wineserverHoldsLock

    public init(proxy64: URL, proxy32: URL, crossOverApps: [URL] = BottleInstaller.defaultCrossOverApps,
                bridgeFile: URL = SharedBridge.defaultURL) {
        self.proxy64 = proxy64
        self.proxy32 = proxy32
        self.crossOverApps = crossOverApps
        self.bridgeFile = bridgeFile
    }

    public static var defaultCrossOverApps: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            URL(fileURLWithPath: "/Applications/CrossOver.app"),
            home.appendingPathComponent("Applications/CrossOver.app"),
        ]
    }

    public func state(of bottle: Bottle) -> BottleState {
        let fm = FileManager.default
        guard fm.fileExists(atPath: bottle.manifestURL.path) else { return .notInstalled }
        for (folder, proxy) in architectures(of: bottle) {
            let dll = folder.appendingPathComponent(Self.dllName)
            guard fm.fileExists(atPath: dll.path) else { return .needsRepair("Proxy missing.") }
            guard Self.sameContents(dll, proxy) else { return .needsRepair("Proxy replaced or out of date.") }
            guard fm.fileExists(atPath: folder.appendingPathComponent(Self.realName).path) else {
                return .needsRepair("CrossOver's dinput8 copy missing.")
            }
        }
        let registry = (try? String(contentsOf: bottle.userRegistry, encoding: .utf8)) ?? ""
        guard RegistryText.value(in: registry, section: Self.overrideSection, key: Self.overrideKey) == Self.overrideValue else {
            return .needsRepair("dinput8 override reset.")
        }
        return .installed
    }

    /// Installs, or repairs, the proxy for every game in the bottle.
    public func install(into bottle: Bottle) throws {
        guard !isWineRunning(bottle) else { throw Failure.wineRunning }
        guard Self.driveZIsRoot(bottle) else { throw Failure.noDriveZ }

        // Everything that can fail is checked before anything is touched.
        var plan: [(folder: URL, proxy: URL, builtin: URL)] = []
        for (folder, proxy) in architectures(of: bottle) {
            guard FileManager.default.fileExists(atPath: proxy.path) else { throw Failure.proxyMissing(proxy.path) }
            let arch = proxy == proxy64 ? "x86_64-windows" : "i386-windows"
            guard let builtin = builtin(arch: arch) else { throw Failure.builtinNotFound(arch) }
            plan.append((folder, proxy, builtin))
        }

        var manifest = readManifest(bottle)
        if manifest == nil {
            let registry = (try? String(contentsOf: bottle.userRegistry, encoding: .utf8)) ?? ""
            manifest = Manifest(previousOverride: RegistryText.value(
                in: registry, section: Self.overrideSection, key: Self.overrideKey))
            // Written first, so a failure below can still be undone.
            try write(manifest!, to: bottle)
        }

        for step in plan {
            try placeProxy(in: step.folder, proxy: step.proxy, builtin: step.builtin)
        }
        try setOverride(Self.overrideValue, in: bottle)
    }

    /// Puts the bottle back as it was.
    public func uninstall(from bottle: Bottle) throws {
        guard !isWineRunning(bottle) else { throw Failure.wineRunning }
        guard let manifest = readManifest(bottle) else { throw Failure.notInstalled }
        let fm = FileManager.default
        for (folder, _) in architectures(of: bottle) {
            let dll = folder.appendingPathComponent(Self.dllName)
            let backup = folder.appendingPathComponent(Self.backupName)
            if fm.fileExists(atPath: backup.path) {
                try? fm.removeItem(at: dll)
                try fm.moveItem(at: backup, to: dll)
            }
            try? fm.removeItem(at: folder.appendingPathComponent(Self.realName))
            try? fm.removeItem(at: folder.appendingPathComponent(Self.configName))
        }
        try setOverride(manifest.previousOverride, in: bottle)
        try fm.removeItem(at: bottle.manifestURL)
    }

    private func placeProxy(in folder: URL, proxy: URL, builtin: URL) throws {
        let fm = FileManager.default
        let dll = folder.appendingPathComponent(Self.dllName)
        let backup = folder.appendingPathComponent(Self.backupName)
        // Only the first install keeps a backup: a repair must not save our own proxy.
        if !fm.fileExists(atPath: backup.path), fm.fileExists(atPath: dll.path) {
            try fm.copyItem(at: dll, to: backup)
        }
        try Self.replace(folder.appendingPathComponent(Self.realName), with: builtin)
        try Self.replace(dll, with: proxy)
        let config = Self.windowsPath(bridgeFile) + "\r\n"
        try Data(config.utf8).write(to: folder.appendingPathComponent(Self.configName), options: .atomic)
    }

    private func architectures(of bottle: Bottle) -> [(URL, URL)] {
        var result = [(bottle.system32, proxy64)]
        if FileManager.default.fileExists(atPath: bottle.syswow64.path) {
            result.append((bottle.syswow64, proxy32))
        }
        return result
    }

    private func builtin(arch: String) -> URL? {
        crossOverApps.lazy
            .map { $0.appendingPathComponent("Contents/SharedSupport/CrossOver/lib/wine/\(arch)/dinput8.dll") }
            .first(where: Self.isWineBuiltin)
    }

    private func setOverride(_ value: String?, in bottle: Bottle) throws {
        let text = try String(contentsOf: bottle.userRegistry, encoding: .utf8)
        let updated = RegistryText.setting(in: text, section: Self.overrideSection, key: Self.overrideKey, to: value)
        try Data(updated.utf8).write(to: bottle.userRegistry, options: .atomic)
    }

    private func readManifest(_ bottle: Bottle) -> Manifest? {
        guard let data = try? Data(contentsOf: bottle.manifestURL) else { return nil }
        return try? JSONDecoder().decode(Manifest.self, from: data)
    }

    private func write(_ manifest: Manifest, to bottle: Bottle) throws {
        try JSONEncoder().encode(manifest).write(to: bottle.manifestURL, options: .atomic)
    }

    /// A bottle's dinput8.dll may be a placeholder of the same name, and a copy of
    /// that would fail later and far from here, so only a true builtin passes.
    static func isWineBuiltin(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: signatureOffset + builtinSignature.count) else { return false }
        return head.count == signatureOffset + builtinSignature.count && head.suffix(builtinSignature.count) == builtinSignature
    }

    static func windowsPath(_ url: URL) -> String {
        "Z:" + url.path.replacingOccurrences(of: "/", with: "\\")
    }

    private static func driveZIsRoot(_ bottle: Bottle) -> Bool {
        let link = bottle.url.appendingPathComponent("dosdevices/z:").path
        return (try? FileManager.default.destinationOfSymbolicLink(atPath: link)) == "/"
    }

    private static func replace(_ target: URL, with source: URL) throws {
        let fm = FileManager.default
        let staged = target.appendingPathExtension("wheelbridge-new")
        try? fm.removeItem(at: staged)
        try fm.copyItem(at: source, to: staged)
        if fm.fileExists(atPath: target.path) {
            _ = try fm.replaceItemAt(target, withItemAt: staged)
        } else {
            try fm.moveItem(at: staged, to: target)
        }
    }

    private static func sameContents(_ a: URL, _ b: URL) -> Bool {
        guard let first = try? Data(contentsOf: a), let second = try? Data(contentsOf: b) else { return false }
        return SHA256.hash(data: first) == SHA256.hash(data: second)
    }

    /// wineserver keeps a lock on a file named after the bottle, and it rewrites
    /// user.reg from memory when it exits, so nothing may be edited while it runs.
    public static func wineserverHoldsLock(_ bottle: Bottle) -> Bool {
        var info = stat()
        guard stat(bottle.url.path, &info) == 0 else { return false }
        let name = String(format: "server-%llx-%llx", UInt64(info.st_dev), UInt64(info.st_ino))
        let path = "/tmp/.wine-\(getuid())/\(name)/lock"
        let descriptor = open(path, O_RDWR)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        var lock = flock()
        lock.l_type = Int16(F_WRLCK)
        lock.l_whence = Int16(SEEK_SET)
        guard fcntl(descriptor, F_GETLK, &lock) == 0 else { return false }
        return lock.l_type != Int16(F_UNLCK)
    }
}

/// Edits Wine's registry text files, changing only the one line it must.
public enum RegistryText {
    public static func value(in text: String, section: String, key: String) -> String? {
        let lines = text.components(separatedBy: "\n")
        guard let range = sectionRange(lines, section: section) else { return nil }
        for line in lines[range] {
            if let value = parse(line, key: key) { return value }
        }
        return nil
    }

    /// Sets `key`, or removes it if `value` is nil.
    public static func setting(in text: String, section: String, key: String, to value: String?) -> String {
        var lines = text.components(separatedBy: "\n")
        let entry = value.map { "\"\(key)\"=\"\($0)\"" }
        guard let range = sectionRange(lines, section: section) else {
            guard let entry else { return text }
            if lines.last == "" { lines.removeLast() }
            lines += ["", "\(section) 0", entry, ""]
            return lines.joined(separator: "\n")
        }
        if let index = lines[range].firstIndex(where: { parse($0, key: key) != nil }) {
            if let entry { lines[index] = entry } else { lines.remove(at: index) }
        } else if let entry {
            lines.insert(entry, at: range.lowerBound)
        }
        return lines.joined(separator: "\n")
    }

    /// The lines of a section's entries, after its header and any #time line.
    private static func sectionRange(_ lines: [String], section: String) -> Range<Int>? {
        guard let header = lines.firstIndex(where: { $0 == section || $0.hasPrefix(section + " ") }) else { return nil }
        var start = header + 1
        while start < lines.count, lines[start].hasPrefix("#") { start += 1 }
        var end = start
        while end < lines.count, !lines[end].isEmpty, !lines[end].hasPrefix("[") { end += 1 }
        return start..<end
    }

    private static func parse(_ line: String, key: String) -> String? {
        let prefix = "\"\(key)\"=\""
        guard line.hasPrefix(prefix), line.hasSuffix("\"") else { return nil }
        return String(line.dropFirst(prefix.count).dropLast())
    }
}
